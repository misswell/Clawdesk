#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$PROJECT_DIR/dist/Clawdesk.app"
ARCH_LIST="${CLAWDESK_ARCHS:-$(uname -m)}"
ARCHS=(${=ARCH_LIST})

cd "$PROJECT_DIR"

DEVELOPER_ID="${CLAWDESK_DEVELOPER_ID:-}"
ALLOW_ADHOC="${CLAWDESK_ALLOW_ADHOC:-0}"
if [[ -z "$DEVELOPER_ID" && "$ALLOW_ADHOC" != "1" ]]; then
    echo "CLAWDESK_DEVELOPER_ID is required for distributable builds." >&2
    echo "Set CLAWDESK_ALLOW_ADHOC=1 only for local development builds." >&2
    exit 1
fi

MAIN_BINARIES=()
STATUSLINE_BINARIES=()
UPDATER_BINARIES=()
SCRATCH_DIRS=()

for arch in "${ARCHS[@]}"; do
    case "$arch" in
        arm64|x86_64) ;;
        *)
            echo "Unsupported architecture: $arch (use arm64 and/or x86_64)" >&2
            exit 1
            ;;
    esac

    scratch_path="$PROJECT_DIR/.build-clawdesk-$arch"
    SCRATCH_DIRS+=("$scratch_path")
    triple="${arch}-apple-macosx13.0"
    swift build -c release --triple "$triple" --scratch-path "$scratch_path" --product Clawdesk
    swift build -c release --triple "$triple" --scratch-path "$scratch_path" --product ClawdeskStatusline
    swift build -c release --triple "$triple" --scratch-path "$scratch_path" --product ClawdeskUpdater
    bin_path="$(swift build -c release --triple "$triple" --scratch-path "$scratch_path" --show-bin-path)"
    MAIN_BINARIES+=("$bin_path/Clawdesk")
    STATUSLINE_BINARIES+=("$bin_path/ClawdeskStatusline")
    UPDATER_BINARIES+=("$bin_path/ClawdeskUpdater")
done

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

if [[ "${#MAIN_BINARIES[@]}" == 1 ]]; then
    cp "${MAIN_BINARIES[1]}" "$APP_PATH/Contents/MacOS/Clawdesk"
    cp "${STATUSLINE_BINARIES[1]}" "$APP_PATH/Contents/MacOS/ClawdeskStatusline"
    cp "${UPDATER_BINARIES[1]}" "$APP_PATH/Contents/MacOS/ClawdeskUpdater"
else
    lipo -create "${MAIN_BINARIES[@]}" -output "$APP_PATH/Contents/MacOS/Clawdesk"
    lipo -create "${STATUSLINE_BINARIES[@]}" -output "$APP_PATH/Contents/MacOS/ClawdeskStatusline"
    lipo -create "${UPDATER_BINARIES[@]}" -output "$APP_PATH/Contents/MacOS/ClawdeskUpdater"
fi

cp "$PROJECT_DIR/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
chmod +x "$APP_PATH/Contents/MacOS/Clawdesk" \
    "$APP_PATH/Contents/MacOS/ClawdeskStatusline" \
    "$APP_PATH/Contents/MacOS/ClawdeskUpdater"

if [[ -n "$DEVELOPER_ID" ]]; then
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" \
        "$APP_PATH/Contents/MacOS/ClawdeskUpdater"
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" \
        "$APP_PATH/Contents/MacOS/ClawdeskStatusline"
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP_PATH"
else
    codesign --force --sign - "$APP_PATH/Contents/MacOS/ClawdeskUpdater"
    codesign --force --sign - "$APP_PATH/Contents/MacOS/ClawdeskStatusline"
    codesign --force --sign - "$APP_PATH"
fi

codesign --verify --deep --strict "$APP_PATH"

if [[ -n "$DEVELOPER_ID" ]]; then
    EXPECTED_TEAM_ID="${CLAWDESK_DEVELOPER_TEAM_ID:-U8U443D7ZL}"
    for signed_path in \
        "$APP_PATH/Contents/MacOS/ClawdeskUpdater" \
        "$APP_PATH"; do
        signature_details="$(codesign --display --verbose=4 "$signed_path" 2>&1)"
        if ! grep -q '^Authority=Developer ID Application:' <<<"$signature_details"; then
            echo "Expected a Developer ID Application signature: $signed_path" >&2
            exit 1
        fi
        if ! grep -q "^TeamIdentifier=$EXPECTED_TEAM_ID$" <<<"$signature_details"; then
            echo "Unexpected signing team for $signed_path (expected $EXPECTED_TEAM_ID)" >&2
            exit 1
        fi
    done
fi

for scratch_path in "${SCRATCH_DIRS[@]}"; do
    rm -rf "$scratch_path"
done

echo "Built: $APP_PATH"
echo "Architectures: ${ARCHS[*]}"
echo "Updater: $APP_PATH/Contents/MacOS/ClawdeskUpdater"
