#!/bin/bash
# Build a launchable Jarvis.app bundle from the SwiftPM executable.
#
# Usage:
#   ./Scripts/build-app.sh            # release build (default)
#   ./Scripts/build-app.sh debug      # debug build
#
# Output: build/Jarvis.app
#
# Notes:
# - No code changes required: Info.plist is embedded at bundle time and
#   ad-hoc signed so TCC presents normal permission dialogs for microphone
#   and speech recognition.
# - Logs are redirected to build/jarvis.log so voice pipeline activity is
#   inspectable after launching from Finder.

set -euo pipefail

CONFIG="${1:-release}"
case "$CONFIG" in
  release|debug) ;;
  *) echo "usage: $0 [release|debug]" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Jarvis"
BUNDLE_ID="com.jarvis.app"
VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo 0.1.0)"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
APP_DIR="$ROOT/build/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

# Executable
cp "$BIN_PATH/$APP_NAME" "$CONTENTS/MacOS/$APP_NAME"

# Info.plist with privacy usage descriptions (mic + speech recognition)
sed -e "s|\${BUNDLE_ID}|$BUNDLE_ID|g" \
    -e "s|\${VERSION}|$VERSION|g" \
    Scripts/Info.plist > "$CONTENTS/Info.plist"

# Ad-hoc signing so TCC attributes permissions to the bundle identity
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1

echo "==> done: $APP_DIR"
echo "    launch with: open \"$APP_DIR\""
echo "    logs:        tail -f $ROOT/build/jarvis.log"
