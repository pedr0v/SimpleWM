#!/usr/bin/env bash
# Builds SimpleWM in release mode and wraps it into dist/SimpleWM.app.
#
# Usage: scripts/make-app.sh
# Env:
#   SIMPLEWM_VERSION        Bundle version. Default 0.1.0.
#   SIMPLEWM_SIGN_IDENTITY  codesign identity. Default: the first
#                           "Developer ID Application" identity in the
#                           keychain, else "-" (ad-hoc).
#   SIMPLEWM_NOTARIZE=1     Notarize and staple. Needs APPLE_ID,
#                           APPLE_TEAM_ID, APPLE_APP_PASSWORD, and a
#                           Developer ID identity.
#
# Ad-hoc signing changes the cdhash on each build, so macOS drops the
# Accessibility grant. A Developer ID identity keeps the grant.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/SimpleWM.app"
BUNDLE_ID="com.simplewm.app"
VERSION="${SIMPLEWM_VERSION:-0.1.0}"
ZIP="$DIST/SimpleWM-$VERSION.zip"

detect_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true
}
IDENTITY="${SIMPLEWM_SIGN_IDENTITY:-$(detect_identity)}"
IDENTITY="${IDENTITY:--}"

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

if [ "$IDENTITY" = "-" ]; then
  echo "==> codesign (ad-hoc)"
  codesign --force --deep --sign "-" "$APP"
else
  echo "==> codesign ($IDENTITY, hardened runtime, timestamp)"
  codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
codesign --verify --verbose=2 "$APP"

if [ "${SIMPLEWM_NOTARIZE:-0}" = "1" ]; then
  [ "$IDENTITY" != "-" ] || { echo "Notarization needs a Developer ID identity." >&2; exit 1; }
  : "${APPLE_ID:?set APPLE_ID}" "${APPLE_TEAM_ID:?set APPLE_TEAM_ID}" "${APPLE_APP_PASSWORD:?set APPLE_APP_PASSWORD}"
  echo "==> notarize"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" --wait
  echo "==> staple"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

echo "==> zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

cat <<MSG

Built $APP (version $VERSION, identity: $IDENTITY)
Archive: $ZIP
MSG
if [ "$IDENTITY" = "-" ]; then
  cat <<MSG
The ad-hoc signature changes on each build. If macOS drops the
Accessibility grant, run:
  tccutil reset Accessibility $BUNDLE_ID
then re-add the app.
MSG
fi
