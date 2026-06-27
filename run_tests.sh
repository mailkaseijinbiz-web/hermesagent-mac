#!/bin/bash
# Run the SPM unit tests locally.
#
# Why this wrapper: `swift test` fails locally for two repo-specific reasons —
#   1. The CommandLineTools toolchain has no XCTest module ("no such module 'XCTest'"),
#      so a FULL Xcode toolchain must be selected via DEVELOPER_DIR.
#   2. This repo lives under an iCloud-synced ~/Documents folder, whose file provider keeps
#      stamping com.apple.FinderInfo / fileprovider xattrs onto build artifacts. Those break
#      the ad-hoc codesign of the .xctest bundle ("resource fork ... not allowed"), and they
#      reappear even after `xattr -cr`. So we build into a scratch dir OUTSIDE iCloud (/tmp).
# CI (.github/workflows/ci.yml, macos-latest) needs neither — the runner has Xcode and the
# checkout isn't in iCloud — so it just runs `swift test`. Override Xcode with XCODE_APP=...
set -e
cd "$(dirname "$0")"

XCODE_APP="${XCODE_APP:-/Applications/Xcode-beta.app}"
DEV="$XCODE_APP/Contents/Developer"
if [ ! -d "$DEV" ]; then
  DEV="$(xcode-select -p 2>/dev/null || true)"
fi
if [ ! -d "$DEV/Platforms" ]; then
  echo "⚠️  フルXcodeのツールチェーンが見つかりません ($DEV)。" >&2
  echo "   XCODE_APP=/Applications/Xcode.app ./run_tests.sh のように指定してください。" >&2
  exit 1
fi

SCRATCH="${TMPDIR:-/tmp}/hermescustom-spm-build"   # build OUTSIDE the iCloud-synced repo
echo "Toolchain: $DEV"
echo "Scratch:   $SCRATCH"
DEVELOPER_DIR="$DEV" swift test --scratch-path "$SCRATCH" "$@"
