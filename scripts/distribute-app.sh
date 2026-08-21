#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEVELOPER_ID="${CLAWDESK_DEVELOPER_ID:-Developer ID Application: Guofeng Liu (U8U443D7ZL)}"
TEAM_ID="${CLAWDESK_DEVELOPER_TEAM_ID:-U8U443D7ZL}"
NOTARY_PROFILE="${CLAWDESK_NOTARY_PROFILE:-octoshrink-notary}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
OUTPUT_DIR="${CLAWDESK_OUTPUT_DIR:-$ROOT/dist/release}"
APP="$ROOT/dist/Clawdesk.app"
ZIP="$OUTPUT_DIR/Clawdesk-$VERSION-macos.zip"

mkdir -p "$OUTPUT_DIR"
CLAWDESK_ARCHS="${CLAWDESK_ARCHS:-arm64 x86_64}" \
CLAWDESK_DEVELOPER_ID="$DEVELOPER_ID" \
    "$ROOT/scripts/build-app.sh"

echo "==> Archiving signed app"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple notarization service ($NOTARY_PROFILE)"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Re-archiving stapled app"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Verifying final artifact"
codesign --verify --deep --strict "$APP"
spctl --assess --type execute --verbose "$APP"
shasum -a 256 "$ZIP"

echo "Done."
echo "  App: $APP"
echo "  ZIP: $ZIP"
