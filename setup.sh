#!/bin/bash
# PhotoSync ("The Kingpins") — Interactive Setup & macOS Menu Bar Installer
set -euo pipefail

BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RED="\033[31m"
RESET="\033[0m"

info()  { echo -e "${CYAN}${BOLD}==>${RESET} $*"; }
ok()    { echo -e "${GREEN}${BOLD} ✓${RESET} $*"; }
warn()  { echo -e "${YELLOW}${BOLD} !${RESET} $*"; }
err()   { echo -e "${RED}${BOLD} ✗${RESET} $*" >&2; }

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$HOME/.local/share/photosync/venv"
CONFIG_DIR="$HOME/.config/photosync"
CONFIG_FILE="$CONFIG_DIR/config.json"
CHROME_PROFILE_DIR="$HOME/.local/share/photosync/google-profile"
APP_BUNDLE="$HOME/Applications/PhotoSync.app"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LOG_FILE="$HOME/Library/Logs/photosync.log"

RECONFIGURE=0
for arg in "$@"; do
    case "$arg" in
        --reconfigure|-r) RECONFIGURE=1 ;;
    esac
done

echo -e "${BOLD}============================================================${RESET}"
echo -e "${BOLD}   PhotoSync — Google Photos ↔ iCloud Shared Album Setup    ${RESET}"
echo -e "${BOLD}============================================================${RESET}"
echo ""

# ------------------------------------------------------------------------------
# Step 1: Check Xcode Command Line Tools (swiftc)
# ------------------------------------------------------------------------------
info "[1/6] Checking Xcode Command Line Tools (swiftc)..."
if ! command -v swiftc >/dev/null 2>&1; then
    warn "Xcode Command Line Tools not found. Triggering macOS installer..."
    xcode-select --install || true
    err "Please complete the Xcode Command Line Tools installation, then re-run ./setup.sh"
    exit 1
fi
ok "swiftc available ($(swiftc --version | head -n 1))"

# ------------------------------------------------------------------------------
# Step 2: Compile native Swift PhotoKit bridge (bin/icloud-bridge)
# ------------------------------------------------------------------------------
info "[2/6] Compiling native PhotoKit bridge (bin/icloud-bridge)..."
mkdir -p "$REPO_DIR/bin"
swiftc -O "$REPO_DIR/icloud-bridge.swift" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$REPO_DIR/Info.plist" \
    -o "$REPO_DIR/bin/icloud-bridge"
codesign --force --sign - "$REPO_DIR/bin/icloud-bridge" >/dev/null 2>&1
chmod +x "$REPO_DIR/bin/icloud-bridge" "$REPO_DIR/photosync.py"
ok "Compiled $REPO_DIR/bin/icloud-bridge"

# ------------------------------------------------------------------------------
# Step 3: Isolated Python 3.10+ Virtualenv + Playwright
# ------------------------------------------------------------------------------
info "[3/6] Setting up isolated Python virtualenv ($VENV_DIR)..."
SYS_PYTHON=""
for cand in /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3.11 /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    if [ -x "$cand" ]; then
        if "$cand" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
            SYS_PYTHON="$cand"
            break
        fi
    fi
done
if [ -z "$SYS_PYTHON" ]; then
    err "Python 3.10+ is required."
    exit 1
fi

mkdir -p "$(dirname "$VENV_DIR")"
if [ ! -x "$VENV_DIR/bin/python3" ]; then
    "$SYS_PYTHON" -m venv "$VENV_DIR"
fi
VENV_PY="$VENV_DIR/bin/python3"
if ! "$VENV_PY" -c "import playwright" >/dev/null 2>&1; then
    "$VENV_PY" -m pip install --upgrade pip wheel >/dev/null
    "$VENV_PY" -m pip install --upgrade playwright
fi
ok "Virtualenv ready ($VENV_PY)"

# ------------------------------------------------------------------------------
# Step 4: Configure iCloud Shared Album & Google Photos Shared Album URL
# ------------------------------------------------------------------------------
info "[4/6] Configuring PhotoSync ($CONFIG_FILE)..."
mkdir -p "$CONFIG_DIR"

CUR_ALBUM="The Kingpins"
CUR_URL="https://photos.app.goo.gl/YOUR_SHARED_ALBUM_LINK"
CUR_INTERVAL="30"

if [ -f "$CONFIG_FILE" ]; then
    eval "$("$VENV_PY" - "$CONFIG_FILE" <<'PY'
import json, shlex, sys
try:
    d = json.load(open(sys.argv[1]))
    print("CUR_ALBUM=" + shlex.quote(str(d.get("icloud_album", "The Kingpins"))))
    print("CUR_URL=" + shlex.quote(str(d.get("google_album_url", ""))))
    print("CUR_INTERVAL=" + shlex.quote(str(d.get("poll_interval_seconds", 30))))
except Exception:
    pass
PY
)"
fi

if [ ! -f "$CONFIG_FILE" ] || [ "$RECONFIGURE" -eq 1 ]; then
    if [ -t 0 ]; then
        echo ""
        read -r -p "  iCloud Shared Album name [$CUR_ALBUM]: " IN_ALBUM
        CUR_ALBUM="${IN_ALBUM:-$CUR_ALBUM}"

        read -r -p "  Google Photos Shared Album URL [$CUR_URL]: " IN_URL
        CUR_URL="${IN_URL:-$CUR_URL}"

        read -r -p "  Poll interval in seconds [$CUR_INTERVAL]: " IN_INTERVAL
        CUR_INTERVAL="${IN_INTERVAL:-$CUR_INTERVAL}"
        echo ""
    fi

    "$VENV_PY" - "$CONFIG_FILE" "$CUR_ALBUM" "$CUR_URL" "$CUR_INTERVAL" <<'PY'
import json, sys
path, album, url, interval = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
with open(path, "w") as f:
    json.dump(
        {
            "icloud_album": album,
            "google_album_url": url,
            "poll_interval_seconds": interval,
        },
        f,
        indent=2,
    )
PY
    chmod 600 "$CONFIG_FILE"
fi
ok "Configuration saved: iCloud '$CUR_ALBUM' <-> $CUR_URL (every ${CUR_INTERVAL}s)"

if "$REPO_DIR/bin/icloud-bridge" list --album "$CUR_ALBUM" >/dev/null 2>&1; then
    COUNT="$("$REPO_DIR/bin/icloud-bridge" list --album "$CUR_ALBUM" | "$VENV_PY" -c 'import json,sys; print(len(json.load(sys.stdin)))')"
    ok "Verified iCloud Shared Album '$CUR_ALBUM' in macOS Photos ($COUNT items currently in album)"
else
    warn "Could not verify iCloud Shared Album '$CUR_ALBUM' yet — ensure Photos -> Settings -> iCloud -> Shared Albums is enabled."
fi

# ------------------------------------------------------------------------------
# Step 5: One-time Google Photos Sign-In Check (for iCloud -> Google uploads)
# ------------------------------------------------------------------------------
info "[5/6] Checking Google Photos Chrome profile ($CHROME_PROFILE_DIR)..."
if [ ! -d "$CHROME_PROFILE_DIR/Default" ] && [ -t 0 ]; then
    echo ""
    read -r -p "  Would you like to open Chrome now to sign into Google Photos for iCloud -> Google uploads? [y/N]: " DO_LOGIN
    if [[ "${DO_LOGIN:-}" =~ ^[Yy]$ ]]; then
        "$VENV_PY" "$REPO_DIR/photosync.py" --login-google
    fi
else
    ok "Google Photos Chrome profile present at $CHROME_PROFILE_DIR"
fi

# ------------------------------------------------------------------------------
# Step 6: Build & Launch ~/Applications/PhotoSync.app (Menu Bar Monitor)
# ------------------------------------------------------------------------------
info "[6/6] Building macOS menu bar app ($APP_BUNDLE)..."
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

swiftc -O "$REPO_DIR/menubar.swift" -o "$APP_BUNDLE/Contents/MacOS/PhotoSync"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>PhotoSync</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.kuscher.photosync.app</string>
    <key>CFBundleName</key>
    <string>PhotoSync</string>
    <key>CFBundleDisplayName</key>
    <string>PhotoSync</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>PhotoSync syncs photos between your iCloud Shared Album and Google Photos Shared Album.</string>
</dict>
</plist>
EOF

cp "$REPO_DIR/onboarding.html" "$APP_BUNDLE/Contents/Resources/onboarding.html"
cp "$REPO_DIR/setup.sh" "$APP_BUNDLE/Contents/Resources/setup.sh"
chmod +x "$APP_BUNDLE/Contents/Resources/setup.sh"
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1
ok "Built $APP_BUNDLE"

# Install LaunchAgent for the Menu Bar app so it starts automatically on login
mkdir -p "$LAUNCH_AGENTS_DIR" "$(dirname "$LOG_FILE")"
cat > "$LAUNCH_AGENTS_DIR/io.github.kuscher.photosync-menubar.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.github.kuscher.photosync-menubar</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_BUNDLE/Contents/MacOS/PhotoSync</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF

# Restart daemon & launch Menu Bar app
pkill -f "PhotoSync.app/Contents/MacOS/PhotoSync" 2>/dev/null || true
pkill -f "photosync.py" 2>/dev/null || true
sleep 0.5

"$VENV_PY" -c '
import subprocess, pathlib
repo = pathlib.Path("'"$REPO_DIR"'")
venv_py = "'"$VENV_PY"'"
log_path = pathlib.Path.home() / "Library/Logs/photosync.log"
log_path.parent.mkdir(parents=True, exist_ok=True)
fh = open(log_path, "a")
subprocess.Popen(
    [venv_py, str(repo / "photosync.py")],
    stdout=fh,
    stderr=fh,
    stdin=subprocess.DEVNULL,
    start_new_session=True,
)
'

open "$APP_BUNDLE"
ok "PhotoSync daemon & Menu Bar Monitor started!"
echo ""
echo -e "  • Menu Bar App:  ${BOLD}$APP_BUNDLE${RESET}"
echo -e "  • How-To Guide:  ${BOLD}$REPO_DIR/onboarding.html${RESET}"
echo -e "  • Sync Log:      ${BOLD}$LOG_FILE${RESET}"
