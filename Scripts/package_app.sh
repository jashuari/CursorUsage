#!/bin/bash
# Build a release binary and wrap it in a minimal .app bundle (menu-bar only, no Dock icon).
# Usage: bash Scripts/package_app.sh   → ./CursorUsage.app
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="CursorUsage"
VERSION="${APP_VERSION:-0.1.0}"
ARCH="$(uname -m)"
TRIPLE="${ARCH}-apple-macosx14.0"

echo "→ swift build -c release ($ARCH)"
swift build -c release --triple "$TRIPLE"
BIN_DIR="$(swift build -c release --triple "$TRIPLE" --show-bin-path)"

APP="${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>com.rubiv.cursorusage</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>Cursor Usage</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

ENT="$(mktemp)"; trap 'rm -f "$ENT"' EXIT
cat > "$ENT" <<'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.network.client</key><true/>
</dict>
</plist>
ENTITLEMENTS

echo "→ codesign (ad-hoc)"
codesign -s - --force --deep --entitlements "$ENT" "$APP"
codesign --verify --deep --strict "$APP"

echo "✓ $APP v$VERSION"
echo "  install:  cp -r $APP /Applications/ && open /Applications/$APP"
