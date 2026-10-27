#!/usr/bin/env python3
"""
PhotoSync ("The Kingpins"): Two-way bridge between a Google Photos Shared Album
and an Apple iCloud Shared Album on macOS using PhotoKit (icloud-bridge).

- Pixel / Google Photos -> iCloud Shared Album:
  Polls the Google Photos shared album link, downloads full-resolution originals (=d / =dv)
  with EXIF/GPS metadata intact, and publishes them headlessly into the macOS Photos
  iCloud Shared Album ("The Kingpins").
- iPhone / iCloud Shared Album -> Google Photos:
  Polls the macOS Photos iCloud Shared Album ("The Kingpins") via icloud-bridge, exports new
  photos/videos added from iCloud, and uploads them into the Google Photos shared album using
  a persistent local Chrome profile (~/.local/share/photosync/google-profile).
"""

import argparse
import fcntl
import hashlib
import json
import logging
import os
import re
import signal
import subprocess
import tempfile
import time
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

logger = logging.getLogger("photosync")

REPO_DIR = Path(__file__).resolve().parent
ICLOUD_BRIDGE_BIN = REPO_DIR / "bin" / "icloud-bridge"
CONFIG_FILE = Path(
    os.environ.get("PHOTOSYNC_CONFIG", str(Path.home() / ".config" / "photosync" / "config.json"))
)
STATE_DIR = Path.home() / ".local" / "share" / "photosync"
STATE_FILE = STATE_DIR / "state.json"
CHROME_PROFILE_DIR = STATE_DIR / "google-profile"
STATUS_FILE = Path("/tmp/photosync-status.json")

DEFAULT_ICLOUD_ALBUM = "Shared Album"
DEFAULT_GOOGLE_ALBUM_URL = "https://photos.app.goo.gl/YOUR_SHARED_ALBUM_LINK"


@dataclass
class GoogleAlbumItem:
    media_key: str
    base_url: str
    width: int
    height: int
    creation_ts: float
    is_video: bool


def load_config() -> dict[str, Any]:
    if CONFIG_FILE.exists():
        try:
            return json.loads(CONFIG_FILE.read_text())
        except Exception as e:
            logger.warning("Failed to parse %s: %s", CONFIG_FILE, e)
    return {
        "icloud_album": DEFAULT_ICLOUD_ALBUM,
        "google_album_url": DEFAULT_GOOGLE_ALBUM_URL,
        "poll_interval_seconds": 30,
    }


def load_state() -> dict[str, Any]:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    if STATE_FILE.exists():
        try:
            data = json.loads(STATE_FILE.read_text())
            data.setdefault("synced_google_keys", [])
            data.setdefault("synced_icloud_ids", [])
            data.setdefault("synced_timestamps", [])
            data.setdefault("synced_sha256", [])
            return data
        except Exception as e:
            logger.warning("Failed to read state file %s: %s", STATE_FILE, e)
    return {
        "synced_google_keys": [],
        "synced_icloud_ids": [],
        "synced_timestamps": [],
        "synced_sha256": [],
    }


def save_state(state: dict[str, Any]) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2))
    tmp.replace(STATE_FILE)


def write_status(payload: dict[str, Any]) -> None:
    try:
        payload["pid"] = os.getpid()
        payload["updated_ts"] = datetime.now(timezone.utc).timestamp()
        tmp = STATUS_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, indent=2))
        tmp.replace(STATUS_FILE)
    except Exception:
        pass


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def is_timestamp_already_synced(ts: Optional[float], synced_timestamps: list[float]) -> bool:
    if ts is None or ts <= 0:
        return False
    for existing in synced_timestamps:
        if abs(existing - ts) <= 2.0:
            return True
    return False


def fetch_google_shared_album_items(share_url: str) -> list[GoogleAlbumItem]:
    """
    Fetch the public/unlisted Google Photos shared album page and parse its embedded
    AF_initDataCallback(key: 'ds:1') JSON payload for all media items.
    """
    req = urllib.request.Request(
        share_url,
        headers={
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
            "Accept-Language": "en-US,en;q=0.9",
        },
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        html = resp.read().decode("utf-8", errors="ignore")

    # Extract the AF_initDataCallback block for ds:1, then grab its data array
    raw_json = None
    for m in re.finditer(r"AF_initDataCallback\(\{(.*?)\}\);</script>", html, re.S):
        block = m.group(1)
        if "'ds:1'" in block or '"ds:1"' in block:
            m_data = re.search(r"data:(\[.*\]),\s*sideChannel:", block, re.S)
            if m_data:
                raw_json = m_data.group(1)
                break
    if not raw_json:
        return []

    raw_data = json.loads(raw_json)
    if not isinstance(raw_data, list) or len(raw_data) < 2 or not isinstance(raw_data[1], list):
        return []

    items: list[GoogleAlbumItem] = []
    for entry in raw_data[1]:
        if not isinstance(entry, list) or len(entry) < 3:
            continue
        media_key = entry[0]
        info = entry[1]
        ts_ms = entry[2]
        if not isinstance(media_key, str) or not isinstance(info, list) or not info:
            continue
        base_url = info[0]
        width = int(info[1]) if len(info) > 1 and isinstance(info[1], int) else 0
        height = int(info[2]) if len(info) > 2 and isinstance(info[2], int) else 0
        # Video items carry duration metadata at info[3] or entry[9]["76647426"]
        is_video = bool(
            (len(info) > 3 and info[3] is not None)
            or (len(entry) > 9 and isinstance(entry[9], dict) and "76647426" in entry[9])
        )
        creation_ts = float(ts_ms) / 1000.0 if isinstance(ts_ms, (int, float)) else 0.0
        items.append(
            GoogleAlbumItem(
                media_key=media_key,
                base_url=base_url,
                width=width,
                height=height,
                creation_ts=creation_ts,
                is_video=is_video,
            )
        )
    return items


def download_google_item(item: GoogleAlbumItem, dest_dir: Path) -> Path:
    suffix = "=dv" if item.is_video else "=d"
    dl_url = f"{item.base_url}{suffix}"
    req = urllib.request.Request(
        dl_url,
        headers={"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"},
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        ctype = (resp.headers.get("Content-Type") or "").lower()
        if "video" in ctype or "mp4" in ctype:
            ext = ".mp4"
        elif "png" in ctype:
            ext = ".png"
        elif "heic" in ctype:
            ext = ".heic"
        else:
            ext = ".jpg"
        out_path = dest_dir / f"{item.media_key}{ext}"
        out_path.write_bytes(resp.read())
    return out_path


def icloud_list_assets(album_title: str) -> list[dict[str, Any]]:
    res = subprocess.run(
        [str(ICLOUD_BRIDGE_BIN), "list", "--album", album_title],
        capture_output=True,
        text=True,
        timeout=30,
        check=True,
    )
    return json.loads(res.stdout.strip() or "[]")


def icloud_import_asset(album_title: str, file_path: Path) -> dict[str, Any]:
    res = subprocess.run(
        [str(ICLOUD_BRIDGE_BIN), "import", "--album", album_title, "--file", str(file_path)],
        capture_output=True,
        text=True,
        timeout=60,
        check=True,
    )
    return json.loads(res.stdout.strip())


def icloud_export_asset(local_id: str, out_path: Path) -> None:
    subprocess.run(
        [str(ICLOUD_BRIDGE_BIN), "export", "--id", local_id, "--out", str(out_path)],
        capture_output=True,
        text=True,
        timeout=120,
        check=True,
    )


def upload_to_google_shared_album(share_url: str, file_path: Path) -> bool:
    """
    Upload a photo/video exported from iCloud into the Google Photos shared album
    using the persistent Chrome profile at ~/.local/share/photosync/google-profile.
    """
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        logger.warning("Playwright not installed in venv; skipping iCloud -> Google Photos upload.")
        return False

    CHROME_PROFILE_DIR.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(
            user_data_dir=str(CHROME_PROFILE_DIR),
            executable_path="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            headless=True,
            args=["--disable-blink-features=AutomationControlled"],
        )
        try:
            page = ctx.pages[0] if ctx.pages else ctx.new_page()
            page.goto(share_url, wait_until="domcontentloaded", timeout=30000)
            page.wait_for_timeout(3000)

            # Check if signed in (if 'Sign in' button is visible or redirected to accounts.google.com)
            sign_in_btn = page.locator('a[href*="ServiceLogin"], a[aria-label*="Sign in"]')
            add_btn = page.locator(
                'button[aria-label*="Add photos"], button[aria-label*="Add to album"], [role="button"][aria-label*="Add photos"]'
            ).first
            if sign_in_btn.count() > 0 or "accounts.google.com" in page.url or add_btn.count() == 0:
                logger.warning(
                    "Google Photos profile is not signed in yet. "
                    "Run '~/.local/share/photosync/venv/bin/python3 ~/projects/PhotoSync/photosync.py --login-google' once to sign in."
                )
                return False

            add_btn.click()
            page.wait_for_timeout(1500)

            with page.expect_file_chooser(timeout=15000) as fc_info:
                select_btn = page.locator('text="Select from computer"').first
                if select_btn.count() > 0:
                    select_btn.click()
                else:
                    page.keyboard.press("Enter")
            file_chooser = fc_info.value
            file_chooser.set_files(str(file_path))

            # Wait for upload completion toast
            page.wait_for_timeout(8000)
            return True
        except Exception as e:
            logger.warning("Failed to upload %s to Google Photos shared album: %s", file_path.name, e)
            return False
        finally:
            ctx.close()


def interactive_google_login(share_url: str) -> None:
    from playwright.sync_api import sync_playwright

    CHROME_PROFILE_DIR.mkdir(parents=True, exist_ok=True)
    logger.info("Opening Google Chrome for one-time Google Photos sign-in...")
    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(
            user_data_dir=str(CHROME_PROFILE_DIR),
            executable_path="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            headless=False,
            args=["--disable-blink-features=AutomationControlled"],
        )
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        page.goto(share_url)
        print("\n=== Sign into your Google Account in the opened Chrome window ===")
        print("Once you see the 'Add photos' icon on 'The Kingpins' album page, close the Chrome window.\n")
        try:
            page.wait_for_event("close", timeout=600000)
        except Exception:
            pass
        ctx.close()


def run_sync_cycle(cfg: dict[str, Any], state: dict[str, Any]) -> None:
    icloud_album = cfg.get("icloud_album", DEFAULT_ICLOUD_ALBUM)
    google_url = cfg.get("google_album_url", DEFAULT_GOOGLE_ALBUM_URL)

    # 1. Fetch current items on both sides
    google_items = fetch_google_shared_album_items(google_url)
    icloud_items = icloud_list_assets(icloud_album)

    # 2. Direction A: Google Photos ("The Kingpins") -> iCloud Shared Album ("The Kingpins")
    for g_item in google_items:
        if g_item.media_key in state["synced_google_keys"]:
            continue

        logger.info(
            "New photo in Google Photos '%s': %s (%dx%d) -> syncing to iCloud...",
            icloud_album,
            g_item.media_key,
            g_item.width,
            g_item.height,
        )
        with tempfile.TemporaryDirectory(prefix="photosync-g2i-") as tmpdir:
            dl_path = download_google_item(g_item, Path(tmpdir))
            fhash = sha256_file(dl_path)
            if fhash in state["synced_sha256"]:
                state["synced_google_keys"].append(g_item.media_key)
                save_state(state)
                continue

            imp = icloud_import_asset(icloud_album, dl_path)
            state["synced_google_keys"].append(g_item.media_key)
            state["synced_sha256"].append(fhash)
            if g_item.creation_ts > 0:
                state["synced_timestamps"].append(round(g_item.creation_ts, 3))
            for new_ic_id in imp.get("sharedAlbumAssetIds") or []:
                if new_ic_id not in state["synced_icloud_ids"]:
                    state["synced_icloud_ids"].append(new_ic_id)
            kind = "Video" if g_item.is_video else "Photo"
            state["last_transfer"] = f"{kind} ({g_item.width}×{g_item.height}) → iCloud"
            state["last_transfer_ts"] = datetime.now(timezone.utc).timestamp()
            save_state(state)
            logger.info(
                "Published Google Photos item %s -> iCloud '%s' (%s)",
                g_item.media_key,
                icloud_album,
                imp.get("sharedAlbumAssetIds"),
            )

    # Refresh iCloud list after any imports
    icloud_items = icloud_list_assets(icloud_album)

    # 3. Direction B: iCloud Shared Album ("The Kingpins") -> Google Photos ("The Kingpins")
    for ic_item in icloud_items:
        local_id = ic_item["localIdentifier"]
        ic_ts = ic_item.get("creationTimestamp")
        if local_id in state["synced_icloud_ids"]:
            continue

        logger.info(
            "New photo in iCloud '%s': %s (%s) -> syncing to Google Photos...",
            icloud_album,
            local_id,
            ic_item.get("filename"),
        )
        with tempfile.TemporaryDirectory(prefix="photosync-i2g-") as tmpdir:
            fname = ic_item.get("filename") or "icloud-photo.jpg"
            export_path = Path(tmpdir) / fname
            icloud_export_asset(local_id, export_path)
            fhash = sha256_file(export_path)
            if fhash in state["synced_sha256"]:
                state["synced_icloud_ids"].append(local_id)
                save_state(state)
                continue

            before_keys = {g.media_key for g in fetch_google_shared_album_items(google_url)}
            if upload_to_google_shared_album(google_url, export_path):
                state["synced_icloud_ids"].append(local_id)
                state["synced_sha256"].append(fhash)
                if ic_ts and ic_ts > 0:
                    state["synced_timestamps"].append(round(float(ic_ts), 3))
                # Re-fetch Google album to mark the newly created Google media_key as synced
                for g_after in fetch_google_shared_album_items(google_url):
                    if g_after.media_key not in before_keys and g_after.media_key not in state["synced_google_keys"]:
                        if not ic_ts or not g_after.creation_ts or abs(g_after.creation_ts - float(ic_ts)) <= 2.0:
                            state["synced_google_keys"].append(g_after.media_key)
                state["last_transfer"] = f"{fname} → Google Photos"
                state["last_transfer_ts"] = datetime.now(timezone.utc).timestamp()
                save_state(state)
                logger.info("Uploaded iCloud item %s -> Google Photos '%s'", local_id, icloud_album)

    # Refresh final counts
    google_items = fetch_google_shared_album_items(google_url)
    icloud_items = icloud_list_assets(icloud_album)

    now_ts = datetime.now(timezone.utc).timestamp()
    write_status(
        {
            "state": "running",
            "icloud_album": icloud_album,
            "google_album_url": google_url,
            "google_items_count": len(google_items),
            "icloud_items_count": len(icloud_items),
            "synced_google_count": len(state["synced_google_keys"]),
            "synced_icloud_count": len(state["synced_icloud_ids"]),
            "last_sync_ts": now_ts,
            "last_transfer": state.get("last_transfer"),
            "last_transfer_ts": state.get("last_transfer_ts"),
            "poll_interval_seconds": int(cfg.get("poll_interval_seconds", 30)),
        }
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Two-way Google Photos <-> iCloud Shared Album sync")
    parser.add_argument("--once", action="store_true", help="Run a single sync cycle and exit")
    parser.add_argument(
        "--login-google",
        action="store_true",
        help="Open Google Chrome once to sign into Google Photos for iCloud -> Google uploads",
    )
    parser.add_argument("-v", "--verbose", action="store_true", help="Enable debug logging")
    args = parser.parse_args()

    log_file = Path.home() / "Library" / "Logs" / "photosync.log"
    log_file.parent.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
        handlers=[
            logging.StreamHandler(),
            logging.FileHandler(log_file, encoding="utf-8"),
        ],
    )

    cfg = load_config()
    if args.login_google:
        interactive_google_login(cfg.get("google_album_url", DEFAULT_GOOGLE_ALBUM_URL))
        return

    lock_fd = open("/tmp/photosync.lock", "w")
    if not args.once:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            lock_fd.write(str(os.getpid()))
            lock_fd.flush()
        except BlockingIOError:
            return

    state = load_state()
    stop = False

    def handle_sig(*_: Any) -> None:
        nonlocal stop
        stop = True

    signal.signal(signal.SIGINT, handle_sig)
    signal.signal(signal.SIGTERM, handle_sig)

    interval = float(cfg.get("poll_interval_seconds", 30))
    logger.info(
        "Started PhotoSync watching iCloud '%s' <-> Google Photos (%s)",
        cfg.get("icloud_album"),
        cfg.get("google_album_url"),
    )

    while not stop:
        try:
            run_sync_cycle(cfg, state)
        except subprocess.CalledProcessError as e:
            logger.warning("Sync cycle command error (%s): %s", e.cmd, (e.stderr or e.stdout or str(e)).strip())
        except Exception as e:
            logger.warning("Sync cycle error: %s", e)
        if args.once:
            break
        for _ in range(int(interval)):
            if stop:
                break
            time.sleep(1.0)

    if not args.once:
        write_status(
            {
                "state": "stopped",
                "icloud_album": cfg.get("icloud_album", DEFAULT_ICLOUD_ALBUM),
                "google_album_url": cfg.get("google_album_url", DEFAULT_GOOGLE_ALBUM_URL),
                "synced_google_count": len(state.get("synced_google_keys", [])),
                "synced_icloud_count": len(state.get("synced_icloud_ids", [])),
                "last_transfer": state.get("last_transfer"),
                "last_transfer_ts": state.get("last_transfer_ts"),
            }
        )


if __name__ == "__main__":
    main()
