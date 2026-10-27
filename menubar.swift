import AppKit
import Foundation

struct PhotoSyncStatus: Codable {
    var state: String?
    var icloud_album: String?
    var google_album_url: String?
    var google_items_count: Int?
    var icloud_items_count: Int?
    var synced_google_count: Int?
    var synced_icloud_count: Int?
    var last_sync_ts: Double?
    var last_transfer: String?
    var last_transfer_ts: Double?
    var poll_interval_seconds: Int?
    var pid: Int32?
    var updated_ts: Double?
}

@MainActor
final class PhotoSyncMenuBarController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?

    private let statusHeaderItem = NSMenuItem(title: "Status: Checking…", action: #selector(manualRefresh), keyEquivalent: "")
    private let albumItem = NSMenuItem(title: "Album: —", action: nil, keyEquivalent: "")
    private let countsItem = NSMenuItem(title: "Library: —", action: nil, keyEquivalent: "")
    private let heartbeatItem = NSMenuItem(title: "Last Check: —", action: nil, keyEquivalent: "")

    private let syncNowItem = NSMenuItem(title: "Sync Now", action: #selector(syncNow), keyEquivalent: "s")
    private let openGoogleAlbumItem = NSMenuItem(title: "Open Google Photos Shared Album", action: #selector(openGoogleAlbum), keyEquivalent: "g")
    private let openApplePhotosItem = NSMenuItem(title: "Open Apple Photos", action: #selector(openApplePhotos), keyEquivalent: "p")

    private let toggleDaemonItem = NSMenuItem(title: "Stop PhotoSync", action: #selector(toggleDaemon), keyEquivalent: "")
    private let restartDaemonItem = NSMenuItem(title: "Restart PhotoSync Now", action: #selector(restartDaemon), keyEquivalent: "r")
    private let googleLoginItem = NSMenuItem(title: "Sign in to Google Photos (Chrome)…", action: #selector(openGoogleLogin), keyEquivalent: "")

    private var latestStatus: PhotoSyncStatus?
    private var isServiceRunning: Bool = false
    private var isManualSyncing: Bool = false

    private let statusFilePath = "/tmp/photosync-status.json"
    private let lockFilePath = "/tmp/photosync.lock"
    private let logPath = ("~/Library/Logs/photosync.log" as NSString).expandingTildeInPath
    private let defaultRepoDir = ("~/projects/PhotoSync" as NSString).expandingTildeInPath
    private let venvPython = ("~/.local/share/photosync/venv/bin/python3" as NSString).expandingTildeInPath

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setupMenu()
        refreshState()

        if !isServiceRunning {
            startDaemonProcess()
        }

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshState()
            }
        }
    }

    private func setupMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        // Keep statusHeaderItem enabled so macOS renders the status dot at full vibrancy
        statusHeaderItem.target = self
        statusHeaderItem.isEnabled = true
        menu.addItem(statusHeaderItem)

        for item in [albumItem, countsItem, heartbeatItem] {
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        for item in [syncNowItem, openGoogleAlbumItem, openApplePhotosItem] {
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())

        for item in [toggleDaemonItem, restartDaemonItem, googleLoginItem] {
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let onboardingItem = NSMenuItem(title: "How-To & Setup Guide…", action: #selector(openOnboardingGuide), keyEquivalent: "i")
        onboardingItem.target = self
        menu.addItem(onboardingItem)

        let setupWizardItem = NSMenuItem(title: "Run Setup Wizard in Terminal…", action: #selector(runSetupWizardInTerminal), keyEquivalent: "")
        setupWizardItem.target = self
        menu.addItem(setupWizardItem)

        let viewLogItem = NSMenuItem(title: "View Sync Log…", action: #selector(openLogFile), keyEquivalent: "l")
        viewLogItem.target = self
        menu.addItem(viewLogItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Menu Bar Monitor", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshState()
    }

    @objc private func manualRefresh() {
        refreshState()
    }

    private func makeStatusDot(color: NSColor) -> NSImage {
        let size = NSSize(width: 10, height: 10)
        let img = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            path.fill()
            return true
        }
        img.isTemplate = false
        return img
    }

    private func loadStatus() -> PhotoSyncStatus? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statusFilePath)),
              let decoded = try? JSONDecoder().decode(PhotoSyncStatus.self, from: data) else {
            return nil
        }
        return decoded
    }

    private func readLockPid() -> Int32? {
        guard let text = try? String(contentsOfFile: lockFilePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(text), pid > 0 else {
            return nil
        }
        return pid
    }

    private func isPidAlive(_ pid: Int32?) -> Bool {
        guard let pid = pid, pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    private func activeDaemonPid(status: PhotoSyncStatus?) -> Int32? {
        if let pid = status?.pid, isPidAlive(pid) {
            return pid
        }
        if let lpid = readLockPid(), isPidAlive(lpid) {
            return lpid
        }
        return nil
    }

    private func refreshState() {
        let status = loadStatus()
        latestStatus = status
        let daemonPid = activeDaemonPid(status: status)
        let alive = (daemonPid != nil) && (status?.state != "stopped")
        isServiceRunning = alive

        guard let button = statusItem.button else { return }

        let albumName = status?.icloud_album ?? "The Kingpins"
        let gCount = status?.google_items_count ?? status?.synced_google_count ?? 0
        let iCount = status?.icloud_items_count ?? status?.synced_icloud_count ?? 0
        let syncedCount = max(status?.synced_google_count ?? 0, status?.synced_icloud_count ?? 0)

        albumItem.title = "Album: \"\(albumName)\" (iCloud ↔ Google Photos)"
        countsItem.title = "Library: \(iCount) in iCloud · \(gCount) in Google Photos (\(syncedCount) synced)"

        if !alive {
            setSymbol(button: button, name: "photo.on.rectangle.angled", badge: nil)
            statusHeaderItem.image = makeStatusDot(color: .systemRed)
            statusHeaderItem.title = "Status: Stopped"
            heartbeatItem.title = "Last Check: Daemon Stopped"
            toggleDaemonItem.title = "Start PhotoSync"
            restartDaemonItem.isEnabled = true
            syncNowItem.isEnabled = !isManualSyncing
            return
        }

        toggleDaemonItem.title = "Stop PhotoSync"
        restartDaemonItem.isEnabled = true
        syncNowItem.isEnabled = !isManualSyncing

        if isManualSyncing {
            setSymbol(button: button, name: "photo.on.rectangle.angled.fill", badge: " SYNC")
            statusHeaderItem.image = makeStatusDot(color: .systemOrange)
            statusHeaderItem.title = "Status: Syncing Now…"
        } else {
            setSymbol(button: button, name: "photo.on.rectangle.angled.fill", badge: nil)
            statusHeaderItem.image = makeStatusDot(color: .systemGreen)
            let interval = status?.poll_interval_seconds ?? 30
            statusHeaderItem.title = "Status: Syncing Active (Every \(interval)s)"
        }

        let checkTs = status?.last_sync_ts ?? status?.updated_ts
        var checkPart = "Last Check: Just now"
        if let ts = checkTs {
            let age = max(0, Int(Date().timeIntervalSince1970 - ts))
            checkPart = "Last Check: \(age)s ago"
        }
        if let lastXfer = status?.last_transfer, !lastXfer.isEmpty {
            heartbeatItem.title = "\(checkPart) · Last: \(lastXfer)"
        } else {
            heartbeatItem.title = "\(checkPart) · In Sync"
        }
    }

    private func setSymbol(button: NSStatusBarButton, name: String, badge: String?) {
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: "PhotoSync") {
            img.isTemplate = true
            button.image = img
        }
        button.title = badge ?? ""
        button.imagePosition = badge == nil ? .imageOnly : .imageLeft
    }

    private func startDaemonProcess() {
        let scriptPath = (defaultRepoDir as NSString).appendingPathComponent("photosync.py")
        guard FileManager.default.fileExists(atPath: scriptPath) else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: venvPython)
        proc.arguments = [scriptPath]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env

        FileManager.default.createFile(atPath: logPath, contents: nil)
        if let fh = FileHandle(forWritingAtPath: logPath) {
            fh.seekToEndOfFile()
            proc.standardOutput = fh
            proc.standardError = fh
        }
        try? proc.run()
    }

    private func stopDaemonProcess() {
        if let pid = activeDaemonPid(status: latestStatus) {
            kill(pid, SIGTERM)
        }
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "photosync.py"]
        try? pkill.run()
        pkill.waitUntilExit()
    }

    @objc private func toggleDaemon() {
        if isServiceRunning {
            stopDaemonProcess()
        } else {
            startDaemonProcess()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.refreshState()
        }
    }

    @objc private func restartDaemon() {
        stopDaemonProcess()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.startDaemonProcess()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self?.refreshState()
            }
        }
    }

    @objc private func syncNow() {
        guard !isManualSyncing else { return }
        isManualSyncing = true
        refreshState()

        let scriptPath = (defaultRepoDir as NSString).appendingPathComponent("photosync.py")
        let py = venvPython
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: py)
            proc.arguments = [scriptPath, "--once"]
            try? proc.run()
            proc.waitUntilExit()
            DispatchQueue.main.async {
                self?.isManualSyncing = false
                self?.refreshState()
            }
        }
    }

    @objc private func openGoogleAlbum() {
        var urlStr = latestStatus?.google_album_url
        if urlStr == nil || urlStr?.isEmpty == true {
            let cfgPath = ("~/.config/photosync/config.json" as NSString).expandingTildeInPath
            if let data = try? Data(contentsOf: URL(fileURLWithPath: cfgPath)),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let cfgUrl = obj["google_album_url"] as? String {
                urlStr = cfgUrl
            }
        }
        if let s = urlStr, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openApplePhotos() {
        let photosURL = URL(fileURLWithPath: "/System/Applications/Photos.app")
        NSWorkspace.shared.openApplication(at: photosURL, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openGoogleLogin() {
        let scriptPath = (defaultRepoDir as NSString).appendingPathComponent("photosync.py")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: venvPython)
        proc.arguments = [scriptPath, "--login-google"]
        try? proc.run()
    }

    @objc private func openOnboardingGuide() {
        if let bundledURL = Bundle.main.url(forResource: "onboarding", withExtension: "html"),
           FileManager.default.fileExists(atPath: bundledURL.path) {
            NSWorkspace.shared.open(bundledURL)
            return
        }
        let repoHTML = (defaultRepoDir as NSString).appendingPathComponent("onboarding.html")
        if FileManager.default.fileExists(atPath: repoHTML) {
            NSWorkspace.shared.open(URL(fileURLWithPath: repoHTML))
        }
    }

    @objc private func runSetupWizardInTerminal() {
        let scriptPath = (defaultRepoDir as NSString).appendingPathComponent("setup.sh")
        if FileManager.default.fileExists(atPath: scriptPath) {
            let cmd = "'\(scriptPath)' --reconfigure"
            let osa = Process()
            osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            osa.arguments = [
                "-e", "tell application \"Terminal\" to activate",
                "-e", "tell application \"Terminal\" to do script \"\(cmd)\""
            ]
            try? osa.run()
        }
    }

    @objc private func openLogFile() {
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = PhotoSyncMenuBarController()
    app.delegate = delegate
    app.run()
}
