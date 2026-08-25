#!/usr/bin/env bash
set -euo pipefail

# Runs the test suite in its own DerivedData tree.
#
# Never point this at the runnable app's `.build/XcodeDerivedData`. `xcodebuild test`
# embeds Context-DockTests.xctest into the already-signed Debug app after its normal
# signing phase. Reusing the run tree therefore leaves the app signature invalid and
# macOS revokes privacy grants such as Full Disk Access. Test products must remain
# physically isolated from the app launched by dev-run.sh.
#
# This project believed for a long time that it could not have automated tests: the runner
# always died with "the test runner exited with code 0 before establishing connection". The
# cause was the app's own single-instance guard — the test bundle is loaded into a second copy
# of Context-Dock, the developer's copy is nearly always running, and the guard terminated the
# host before XCTest could attach. The guard now stands down under XCTest, and the suite that
# had been sitting in Context-DockTests/ all along runs.
#
# Everything here is offline: no API key, no provider, no network. Tests that need a model
# belong in a separate, opt-in runner — a suite that costs money and fails on a plane is a
# suite nobody runs.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/.build/XcodeTestDerivedData"
mkdir -p "$DERIVED_DATA_DIR"

# Same Finder-detritus self-heal as build-debug.sh; see that script for why.
find "$ROOT_DIR/Context-Dock" "$ROOT_DIR/Context-DockExtension" "$ROOT_DIR/Base.lproj" \
  -name $'Icon\r' -type f -delete 2>/dev/null || true
xattr -rc "$ROOT_DIR/Context-Dock" "$ROOT_DIR/Context-DockExtension" "$ROOT_DIR/Base.lproj" 2>/dev/null || true
# …including the already-built product, which build-debug.sh cleans and this script did
# not. Cleaning only the source is not enough: the detritus that fails codesign is the
# copy sitting in Contents/Resources from an earlier build, and an incremental build has
# no reason to touch it. The suite failed to build with "resource fork, Finder
# information, or similar detritus not allowed" while ./scripts/build-debug.sh on the very
# same tree succeeded, purely because of this missing block.
if [ -d "$DERIVED_DATA_DIR/Build/Products" ]; then
  find "$DERIVED_DATA_DIR/Build/Products" \( -name 'Icon' -o -name $'Icon\r' \) -type f -delete 2>/dev/null || true
  xattr -rc "$DERIVED_DATA_DIR/Build/Products" 2>/dev/null || true
fi

xcodebuild test \
  -project "$ROOT_DIR/Context-Dock.xcodeproj" \
  -scheme Context-Dock \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  ENABLE_DEBUG_DYLIB=NO \
  "$@" 2>&1 | tee "$DERIVED_DATA_DIR/last-test-run.log" | grep -E \
  "Test Suite|Test Case|error:|warning: .*test|✔|✘|TEST (SUCCEEDED|FAILED)" || true

# xcodebuild's exit code is what CI should read; the grep above is for humans.
RESULT_BUNDLE="$(ls -td "$DERIVED_DATA_DIR"/Logs/Test/*.xcresult 2>/dev/null | head -1 || true)"
if [ -n "$RESULT_BUNDLE" ]; then
  echo
  xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" 2>/dev/null \
    | grep -E '"passedTests"|"failedTests"|"skippedTests"|"result"' | head -4
fi
