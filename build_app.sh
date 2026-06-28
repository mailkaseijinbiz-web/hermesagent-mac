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

# Record the repo root inside the bundle so the in-app updater can find the source tree even
# when the app runs from outside the repo (see below / UpdateManager.repoPath).
echo "$(pwd)" > "${RESOURCES_DIR}/repo-root.txt"

# Stable signature + install OUTSIDE iCloud so macOS remembers granted permissions (TCC:
# folder access, mic, etc.) across rebuilds.
#  - Ad-hoc signatures change identity every build → re-prompt. Signing with the Apple Development
#    cert gives a fixed Team-ID identity TCC keys on.
#  - BUT release/ lives under ~/Documents (iCloud-synced): the iCloud file provider keeps stamping
#    com.apple.fileprovider / FinderInfo xattrs onto the bundle, which intermittently invalidate
#    the signature, so macOS sees a "changed" app and re-prompts every launch. Fix: install a
#    clean, signed copy to ~/Applications (NOT iCloud-synced) and launch THAT.
LAUNCH_APP="${APP_DIR}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development: KEITA YASUI"; then
    SIGN_ID=$(security find-identity -v -p codesigning | grep "Apple Development: KEITA YASUI" | head -1 | sed -E 's/.*"(.*)"/\1/')
    # Sign the build output too (used by the updater via release/.build-commit).
    xattr -cr "${APP_DIR}" 2>/dev/null || true
    codesign --force --sign "$SIGN_ID" --identifier com.custom.hermesmac --timestamp=none "${APP_DIR}" 2>/dev/null || true
    # Clean install to ~/Applications (non-iCloud) and sign there → stable identity, no xattr churn.
    INSTALL_APP="${HOME}/Applications/HermesCustom.app"
    mkdir -p "${HOME}/Applications"
    rm -rf "${INSTALL_APP}"
    ditto "${APP_DIR}" "${INSTALL_APP}"
    xattr -cr "${INSTALL_APP}" 2>/dev/null || true
    if codesign --force --sign "$SIGN_ID" --identifier com.custom.hermesmac --timestamp=none "${INSTALL_APP}" 2>/dev/null; then
        LAUNCH_APP="${INSTALL_APP}"
        echo "Installed signed app to ${INSTALL_APP} (non-iCloud) → folder/TCC permissions persist."
    else
        echo "⚠️  codesign of ~/Applications copy failed — launching the release/ copy."
    fi
else
    echo "⚠️  Apple Development identity not found — ad-hoc build; macOS may re-prompt for permissions."
fi

echo "LAUNCH_APP=${LAUNCH_APP}"
echo "Done! Built at ${APP_DIR}; launch:  open \"${LAUNCH_APP}\""
