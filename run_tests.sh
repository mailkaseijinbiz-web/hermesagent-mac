#!/bin/bash
# Run the SPM unit tests locally.
#
# Why this wrapper: `swift test` fails out of the box on two counts —
#   1. The CommandLineTools toolchain has no XCTest module ("no such module 'XCTest'"),
#      so a FULL Xcode toolchain must be selected via DEVELOPER_DIR.
#   2. Stray extended attributes on the tree break the test-bundle codesign step.
# CI (.github/workflows/ci.yml on macos-latest) already handles both; this script makes
# the same thing work locally. Override the Xcode location with XCODE_APP=/path/to/Xcode.app.
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

echo "Toolchain: $DEV"
xattr -cr . 2>/dev/null || true   # extended attrs break the .xctest codesign
DEVELOPER_DIR="$DEV" swift test "$@"
