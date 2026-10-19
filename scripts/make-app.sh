#!/usr/bin/env bash
# Builds SimpleWM in release mode and wraps it into dist/SimpleWM.app.
# Usage: scripts/make-app.sh
# Env: SIMPLEWM_SIGN_IDENTITY  codesign identity (default "-", ad-hoc).
#      Ad-hoc signing changes the cdhash on every build, so macOS drops the
#      Accessibility grant. Use a stable self-signed identity to keep it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/SimpleWM.app"
BUNDLE_ID="com.simplewm.app"
VERSION="${SIMPLEWM_VERSION:-0.1.0}"
IDENTITY="${SIMPLEWM_SIGN_IDENTITY:--}"

echo "==> swift build -c release"
swift build -c release --package-path "$ROOT"
BIN="$(swift build -c release --package-path "$ROOT" --show-bin-path)/SimpleWM"
test -x "$BIN"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SimpleWM"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>SimpleWM</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>SimpleWM</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>SimpleWM</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> codesign --sign $IDENTITY"
codesign --force --deep --sign "$IDENTITY" "$APP"
codesign --verify --verbose=2 "$APP"

cat <<MSG

Built: $APP
Run:   open "$APP"

Grant Accessibility in System Settings > Privacy & Security > Accessibility.
If the grant stops working after a rebuild (ad-hoc signature changed), run:
  tccutil reset Accessibility $BUNDLE_ID
then re-add the app.
MSG
