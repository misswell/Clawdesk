#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="$PROJECT_DIR/dist/Clawdesk.app"

cd "$PROJECT_DIR"
swift build -c release --product Clawdesk
swift build -c release --product ClawdeskStatusline
BIN_DIR=$(swift build -c release --show-bin-path)
BIN_PATH="$BIN_DIR/Clawdesk"
STATUSLINE_BIN="$BIN_DIR/ClawdeskStatusline"
if [ ! -x "$BIN_PATH" ] || [ ! -x "$STATUSLINE_BIN" ]; then
  echo "release binary not found: $BIN_PATH or $STATUSLINE_BIN" >&2
  exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/Contents/MacOS" "$BUILD_DIR/Contents/Resources"
cp "$BIN_PATH" "$BUILD_DIR/Contents/MacOS/Clawdesk"
cp "$STATUSLINE_BIN" "$BUILD_DIR/Contents/MacOS/ClawdeskStatusline"
cp "$PROJECT_DIR/Resources/Info.plist" "$BUILD_DIR/Contents/Info.plist"
printf 'APPL????' > "$BUILD_DIR/Contents/PkgInfo"

# Swift's linker signs the executable, but that signature does not seal the
# enclosing .app resources. An ad-hoc bundle signature keeps local builds
# launchable and makes `codesign --verify --deep` useful without requiring a
# Developer ID identity.
codesign --force --deep --sign - "$BUILD_DIR" >/dev/null

echo "$BUILD_DIR"
