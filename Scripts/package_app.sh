#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== Packaging JARVIS as macOS Application Bundle ==="
cd "${ROOT_DIR}"

CONFIG="${1:-release}"
echo "-> Building Jarvis target ($CONFIG)..."
swift build -c "$CONFIG"

BUILD_BIN="$(swift build -c "$CONFIG" --show-bin-path)/Jarvis"
if [ ! -f "${BUILD_BIN}" ]; then
    BUILD_BIN=$(find "${ROOT_DIR}/.build" -name "Jarvis" -type f -perm +111 | head -n 1)
fi

if [ ! -f "${BUILD_BIN}" ]; then
    echo "ERROR: Could not find compiled Jarvis binary!"
    exit 1
fi

APP_DIR="${ROOT_DIR}/Jarvis.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "-> Assembling bundle at ${APP_DIR}..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

# 2. Copy Executable
cp "${BUILD_BIN}" "${MACOS_DIR}/Jarvis"
chmod +x "${MACOS_DIR}/Jarvis"

# 3. Copy any resource bundles
find "${ROOT_DIR}/.build" -name "*.bundle" -maxdepth 4 -type d 2>/dev/null | while read -r bundle_path; do
    if [ -d "${bundle_path}" ]; then
        echo "   Copying bundle $(basename "${bundle_path}")..."
        cp -R "${bundle_path}" "${RESOURCES_DIR}/"
    fi
done

# 4. Generate Info.plist with TCC permissions
cat > "${CONTENTS_DIR}/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Jarvis</string>
    <key>CFBundleIdentifier</key>
    <string>com.jarvis.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Jarvis</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>JARVIS requires microphone access for real-time voice interaction and speech commands.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>JARVIS requires speech recognition to transcribe voice commands on-device using Apple Speech.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>JARVIS requires automation permissions to control system applications like Safari.</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
EOF

# 5. Ad-hoc codesign
echo "-> Signing bundle with ad-hoc signature..."
codesign --force --deep --sign - "${APP_DIR}"

echo "-> Verifying signature..."
codesign -dvvv "${APP_DIR}" 2>&1 | grep -E "(Identifier|Authority|Signature)"

mkdir -p "${ROOT_DIR}/build"
rm -rf "${ROOT_DIR}/build/Jarvis.app"
cp -R "${APP_DIR}" "${ROOT_DIR}/build/Jarvis.app"

echo "=== Jarvis.app packaging complete! ==="
echo "Path: ${APP_DIR} and ${ROOT_DIR}/build/Jarvis.app"
