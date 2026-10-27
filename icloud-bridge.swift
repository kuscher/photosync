import Foundation
import Photos
import ObjectiveC

struct AssetItem: Codable {
    let localIdentifier: String
    let filename: String
    let mediaType: String
    let pixelWidth: Int
    let pixelHeight: Int
    let creationTimestamp: Double?
}

struct ImportResult: Codable {
    let importedLocalIdentifier: String
    let sharedAlbumAssetIds: [String]
}

func ensurePhotosAccess() {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    if status == .authorized || status == .limited {
        return
    }
    let sem = DispatchSemaphore(value: 0)
    PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
        sem.signal()
    }
    sem.wait()
}

func findSharedAlbum(named title: String) -> PHAssetCollection? {
    ensurePhotosAccess()
    let shared = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumCloudShared, options: nil)
    var found: PHAssetCollection?
    shared.enumerateObjects { col, _, stop in
        if col.localizedTitle == title {
            found = col
            stop.pointee = true
        }
    }
    return found
}

func triggerCloudRefresh(for album: PHAssetCollection) {
    // Load CoreMediaStream to ask mstreamd to poll iCloud for new shared album items
    _ = dlopen("/System/Library/PrivateFrameworks/CoreMediaStream.framework/CoreMediaStream", RTLD_NOW)
    guard let connClass = NSClassFromString("MSASConnection") as? NSObject.Type,
          let conn = connClass.perform(NSSelectorFromString("sharedConnection"))?.takeUnretainedValue() as? NSObject else {
        return
    }
    let scopeId = (album.value(forKey: "scopeIdentifier") as? String) ?? ""
    let personId = (album.value(forKey: "cloudPersonID") as? String) ?? ""
    guard !scopeId.isEmpty, !personId.isEmpty else { return }

    let sel = NSSelectorFromString("refreshContentOfAlbumWithGUID:resetSync:personID:")
    if conn.responds(to: sel) {
        typealias RefreshFn = @convention(c) (AnyObject, Selector, NSString, Bool, NSString) -> Void
        let imp = conn.method(for: sel)
        let fn = unsafeBitCast(imp, to: RefreshFn.self)
        fn(conn, sel, scopeId as NSString, false, personId as NSString)
    }
}

func listAssets(albumTitle: String) throws {
    guard let album = findSharedAlbum(named: albumTitle) else {
        fputs("Error: iCloud Shared Album '\(albumTitle)' not found.\n", stderr)
        exit(1)
    }
    triggerCloudRefresh(for: album)

    let assets = PHAsset.fetchAssets(in: album, options: nil)
    var out: [AssetItem] = []
    assets.enumerateObjects { asset, _, _ in
        let resources = PHAssetResource.assetResources(for: asset)
        let fname = resources.first?.originalFilename ?? "asset.jpg"
        let mtype = asset.mediaType == .video ? "video" : "image"
        out.append(
            AssetItem(
                localIdentifier: asset.localIdentifier,
                filename: fname,
                mediaType: mtype,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                creationTimestamp: asset.creationDate?.timeIntervalSince1970
            )
        )
    }
    let data = try JSONEncoder().encode(out)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func importAsset(albumTitle: String, filePath: String) throws {
    guard let album = findSharedAlbum(named: albumTitle) else {
        fputs("Error: iCloud Shared Album '\(albumTitle)' not found.\n", stderr)
        exit(1)
    }
    let fileURL = URL(fileURLWithPath: filePath)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        fputs("Error: File not found at \(filePath)\n", stderr)
        exit(1)
    }

    let beforeAssets = PHAsset.fetchAssets(in: album, options: nil)
    var beforeIds = Set<String>()
    beforeAssets.enumerateObjects { a, _, _ in beforeIds.insert(a.localIdentifier) }

    let ext = fileURL.pathExtension.lowercased()
    let isVideo = ["mp4", "mov", "m4v"].contains(ext)

    var placeholderId: String?
    try PHPhotoLibrary.shared().performChangesAndWait {
        let req = isVideo
            ? PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            : PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
        placeholderId = req?.placeholderForCreatedAsset?.localIdentifier
    }

    guard let newId = placeholderId,
          let asset = PHAsset.fetchAssets(withLocalIdentifiers: [newId], options: nil).firstObject else {
        fputs("Error: Failed to import \(filePath) into Photos library.\n", stderr)
        exit(1)
    }

    try PHPhotoLibrary.shared().performChangesAndWait {
        guard let reqClass = NSClassFromString("PHCollectionShareChangeRequest") as? NSObject.Type else {
            return
        }
        let changeSel = NSSelectorFromString("changeRequestForCollectionShare:")
        guard let reqObj = reqClass.perform(changeSel, with: album)?.takeUnretainedValue() as? NSObject,
              let assetsHelper = reqObj.perform(NSSelectorFromString("assetsHelper"))?.takeUnretainedValue() as? NSObject else {
            return
        }

        typealias AddFn = @convention(c) (AnyObject, Selector, NSArray, NSDictionary?, NSString?) -> Void
        let helperSel = NSSelectorFromString("addAssetsToSharedStreamShare:creationOptionsPerAsset:withBatchCommentText:")
        let hImp = assetsHelper.method(for: helperSel)
        let hFn = unsafeBitCast(hImp, to: AddFn.self)
        hFn(assetsHelper, helperSel, [asset] as NSArray, nil, nil)

        let outerSel = NSSelectorFromString("addAssetsToCollectionShareByCopyingSourceAssets:creationOptionsMappedToSourceAssets:withBatchCommentText:")
        let oImp = reqObj.method(for: outerSel)
        let oFn = unsafeBitCast(oImp, to: AddFn.self)
        oFn(reqObj, outerSel, [asset] as NSArray, nil, nil)
    }

    // Wait up to 6 seconds for photolibraryd to materialize the shared album asset record
    var newSharedIds: [String] = []
    for _ in 0..<12 {
        usleep(500_000)
        let afterAssets = PHAsset.fetchAssets(in: album, options: nil)
        afterAssets.enumerateObjects { a, _, _ in
            if !beforeIds.contains(a.localIdentifier) && !newSharedIds.contains(a.localIdentifier) {
                newSharedIds.append(a.localIdentifier)
            }
        }
        if !newSharedIds.isEmpty {
            break
        }
    }

    let result = ImportResult(importedLocalIdentifier: newId, sharedAlbumAssetIds: newSharedIds)
    let data = try JSONEncoder().encode(result)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func exportAsset(localId: String, outPath: String) throws {
    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil).firstObject else {
        fputs("Error: Asset \(localId) not found.\n", stderr)
        exit(1)
    }
    let resources = PHAssetResource.assetResources(for: asset)
    let preferred = resources.first(where: {
        $0.type == .fullSizePhoto || $0.type == .fullSizeVideo || $0.type == .photo || $0.type == .video
    }) ?? resources.first

    guard let resource = preferred else {
        fputs("Error: No exportable resource for asset \(localId).\n", stderr)
        exit(1)
    }

    let outURL = URL(fileURLWithPath: outPath)
    try? FileManager.default.removeItem(at: outURL)

    let sem = DispatchSemaphore(value: 0)
    var exportError: Error?
    let opts = PHAssetResourceRequestOptions()
    opts.isNetworkAccessAllowed = true

    PHAssetResourceManager.default().writeData(for: resource, toFile: outURL, options: opts) { err in
        exportError = err
        sem.signal()
    }
    sem.wait()

    if let err = exportError {
        fputs("Error exporting asset \(localId): \(err)\n", stderr)
        exit(1)
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: icloud-bridge <list|import|export> [--album <title>] [--file <path>] [--id <localId>] [--out <path>]\n", stderr)
    exit(1)
}

let cmd = args[1]
var albumTitle = "The Kingpins"
var filePath = ""
var assetId = ""
var outPath = ""

var idx = 2
while idx < args.count {
    switch args[idx] {
    case "--album":
        if idx + 1 < args.count { albumTitle = args[idx + 1]; idx += 2 } else { idx += 1 }
    case "--file":
        if idx + 1 < args.count { filePath = args[idx + 1]; idx += 2 } else { idx += 1 }
    case "--id":
        if idx + 1 < args.count { assetId = args[idx + 1]; idx += 2 } else { idx += 1 }
    case "--out":
        if idx + 1 < args.count { outPath = args[idx + 1]; idx += 2 } else { idx += 1 }
    default:
        idx += 1
    }
}

switch cmd {
case "list":
    try listAssets(albumTitle: albumTitle)
case "import":
    try importAsset(albumTitle: albumTitle, filePath: filePath)
case "export":
    try exportAsset(localId: assetId, outPath: outPath)
default:
    fputs("Unknown command: \(cmd)\n", stderr)
    exit(1)
}
