#!/bin/bash
set -e

# Build the project using SPM in release mode
echo "Building HermesCustom..."
swift build -c release

# Define paths
APP_DIR="release/HermesCustom.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "Creating bundle structure..."
rm -rf "release"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# Copy binary
echo "Copying binary..."
if [ -f ".build/release/HermesCustom" ]; then
    cp ".build/release/HermesCustom" "${MACOS_DIR}/HermesCustom"
else
    # Check if universal build location exists
    BIN_PATH=$(find .build -name "HermesCustom" -type f | grep -v "checkouts" | head -n 1)
    if [ -n "$BIN_PATH" ]; then
        cp "$BIN_PATH" "${MACOS_DIR}/HermesCustom"
    else
        echo "Error: Binary not found!"
        exit 1
    fi
fi

# Create Info.plist
echo "Creating Info.plist..."
cat << 'EOF' > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>HermesCustom</string>
    <key>CFBundleIdentifier</key>
    <string>com.custom.hermesmac</string>
    <key>CFBundleName</key>
    <string>HermesCustom</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>音声入力（音声をテキストに変換）に使用します。</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>話した内容をテキストに変換するために音声認識を使用します。</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
EOF

# App icon: copy the .icns into Resources (referenced by CFBundleIconFile above).
if [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

# Record the built commit/branch so the in-app updater can compare against the remote.
git rev-parse HEAD > release/.build-commit 2>/dev/null || true
git rev-parse --abbrev-ref HEAD > release/.build-branch 2>/dev/null || true

echo "Done! App packaged successfully at: ${APP_DIR}"
