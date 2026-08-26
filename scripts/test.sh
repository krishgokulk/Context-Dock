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

# A running dev build breaks the suite in a way that looks like an ordinary failure.
#
# The test host is a second copy of the app. The single-instance guard stands down under
# XCTest, so it launches — but the port listener and the LMDB store are still contended, and
# the run dies partway through:
#
#     [MCP] failed: ... (Network.NWError error 48 - Address already in use)
#     mdb_txn_commit error: MDB_MAP_FULL: Environment mapsize limit reached
#
# What comes out is "failedTests: 1, passedTests: 0" with no named test, or a plausible-looking
# few hundred passes from a run that executed forty. Both read as real results. Refuse instead.
# Matches a lingering test host as well as the dev app: a previous run's host that is still
# alive keeps writing into the next run's log, which is how a passing run came to contain a
# failure line from the run before it.
if pgrep -f "Context-Dock.app/Contents/MacOS/Context-Dock" >/dev/null 2>&1; then
  echo "error: Context-Dock is running. The test host collides with it over its port and" >&2
  echo "       LMDB store, and the suite truncates silently — a partial run still prints a" >&2
  echo "       pass count in the hundreds. Quit the app (or run scripts/dev-stop.sh) first." >&2
  exit 1
fi

xcodebuild test \
  -project "$ROOT_DIR/Context-Dock.xcodeproj" \
  -scheme Context-Dock \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  ENABLE_DEBUG_DYLIB=NO \
  "$@" 2>&1 | tee "$DERIVED_DATA_DIR/last-test-run.log" | grep -E \
  "Test Suite|Test Case|error:|warning: .*test|✔|✘|TEST (SUCCEEDED|FAILED)" || true

# The exit code is xcodebuild's, not the grep's. `set -o pipefail` alone is not enough: the
# `|| true` above swallows it, so the status is taken from PIPESTATUS before that runs. Without
# this the script exited 0 on a red suite, and anything reading the exit code — an agent, a
# hook, CI — read a failure as a pass.
XCODEBUILD_STATUS=${PIPESTATUS[0]}

RESULT_BUNDLE="$(ls -td "$DERIVED_DATA_DIR"/Logs/Test/*.xcresult 2>/dev/null | head -1 || true)"
if [ -n "$RESULT_BUNDLE" ]; then
  echo
  xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" 2>/dev/null \
    | grep -E '"passedTests"|"failedTests"|"skippedTests"|"result"' | head -4

  # A run killed partway prints "failedTests: 1, passedTests: 0" with no named test — the
  # host died before it could run anything, and that reads like an ordinary failure.
  #
  # Comparing counts is tempting and wrong: "Test run with N tests" counts only the
  # swift-testing tests, while the bundle summarises those *and* the XCTest ones, so the two
  # numbers legitimately differ in a mixed suite. This checks the shape instead.
  PASSED="$(xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" 2>/dev/null \
    | grep -oE '"passedTests" : [0-9]+' | head -1 | grep -oE "[0-9]+" || true)"
  FAILED="$(xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" 2>/dev/null \
    | grep -oE '"failedTests" : [0-9]+' | head -1 | grep -oE "[0-9]+" || true)"
  if [ "${PASSED:-1}" = "0" ] && [ "${FAILED:-0}" != "0" ]; then
    echo
    echo "error: nothing passed and something failed with no named test — the runner died" >&2
    echo "       before running the suite. Quit any running Context-Dock and retry. Issue #7." >&2
    XCODEBUILD_STATUS=1
  fi
fi

exit "$XCODEBUILD_STATUS"
