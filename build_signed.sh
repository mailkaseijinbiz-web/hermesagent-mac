#!/bin/bash
# Signed CloudKit-capable build of HermesCustom.
#
# Run this from YOUR interactive Terminal (Terminal.app / iTerm) — automatic
# provisioning (-allowProvisioningUpdates) talks to Apple and needs your logged-in
# Apple ID, which is only reachable from a GUI login-session shell.
#
# First run will: register App ID com.custom.hermesmac, enable iCloud + create the
# CloudKit container iCloud.com.custom.hermes, register this Mac, and issue a Mac
# App Development provisioning profile. May prompt for keychain access / 2FA once.
set -e

export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
DD=/tmp/hermesmac-dd
SPM=/tmp/hermesmac-spm

echo "▸ Regenerating Xcode project from project.yml…"
xcodegen generate

echo "▸ Building (Debug, signed, team 576D2UUHH5)…"
xcodebuild \
  -project HermesCustom.xcodeproj -scheme HermesCustom \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$DD" -clonedSourcePackagesDirPath "$SPM" \
  -allowProvisioningUpdates build

APP="$DD/Build/Products/Debug/HermesCustom.app"
if [ ! -d "$APP" ]; then
  echo "✗ Build product not found at $APP"; exit 1
fi

echo "▸ Copying to release/HermesCustom.app…"
rm -rf release && mkdir -p release
cp -R "$APP" release/HermesCustom.app

# Record the built commit/branch so the in-app updater can compare against the remote.
git rev-parse HEAD > release/.build-commit 2>/dev/null || true
git rev-parse --abbrev-ref HEAD > release/.build-branch 2>/dev/null || true

echo ""
echo "▸ Embedded entitlements (expect the two iCloud keys below):"
codesign -d --entitlements :- release/HermesCustom.app 2>/dev/null | grep -iE "icloud" || \
  echo "  ⚠️  no iCloud entitlements found — capability not provisioned"

echo ""
echo "✓ Done. Launch with:  open release/HermesCustom.app"
echo "  Then: 設定 → クラウド同期 → iCloud接続テスト"
