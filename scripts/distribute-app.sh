#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEVELOPER_ID="${CLAWDESK_DEVELOPER_ID:-Developer ID Application: Guofeng Liu (U8U443D7ZL)}"
TEAM_ID="${CLAWDESK_DEVELOPER_TEAM_ID:-U8U443D7ZL}"
NOTARY_PROFILE="${CLAWDESK_NOTARY_PROFILE:-octoshrink-notary}"
NOTARY_APPLE_ID="${CLAWDESK_NOTARY_APPLE_ID:-}"
NOTARY_PASSWORD="${CLAWDESK_NOTARY_PASSWORD:-}"

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
if [[ -n "$NOTARY_APPLE_ID" || -n "$NOTARY_PASSWORD" ]]; then
    if [[ -z "$NOTARY_APPLE_ID" || -z "$NOTARY_PASSWORD" ]]; then
        echo "Both CLAWDESK_NOTARY_APPLE_ID and CLAWDESK_NOTARY_PASSWORD are required for password-based notarization." >&2
        exit 1
    fi
    xcrun notarytool submit "$ZIP" \
        --apple-id "$NOTARY_APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$NOTARY_PASSWORD" \
        --wait
else
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
fi

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
