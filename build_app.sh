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

# Stable code signature → macOS remembers granted permissions (TCC: folder access, mic, etc.)
# across rebuilds. An ad-hoc signature changes the app's identity every build, so macOS treats
# each build as a new app and re-prompts on launch. Signing with the Apple Development cert gives
# a fixed Team-ID identity that TCC keys on, so a permission granted once persists.
#  ⚠️ Strip iCloud file-provider xattrs first — release/ lives under ~/Documents (iCloud-synced)
#     and those xattrs make codesign fail with "resource fork ... not allowed".
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development: KEITA YASUI"; then
    SIGN_ID=$(security find-identity -v -p codesigning | grep "Apple Development: KEITA YASUI" | head -1 | sed -E 's/.*"(.*)"/\1/')
    xattr -cr "${APP_DIR}" 2>/dev/null || true
    if codesign --force --sign "$SIGN_ID" --identifier com.custom.hermesmac --timestamp=none "${APP_DIR}" 2>/dev/null; then
        echo "Signed with stable identity → permissions persist across rebuilds."
    else
        echo "⚠️  codesign failed — ad-hoc build; macOS may re-prompt for permissions each launch."
    fi
else
    echo "⚠️  Apple Development identity not found — ad-hoc build; macOS may re-prompt for permissions."
fi

echo "Done! App packaged successfully at: ${APP_DIR}"
