#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/.build/XcodeDerivedData"

# Self-heal the recurring macOS custom-folder-icon detritus. Finder re-adds a
# "has custom icon" FinderInfo xattr + an "Icon\r" resource-fork file to folders;
# the PBXFileSystemSynchronizedRootGroup then flattens those into a colliding
# "Icon" resource ("Multiple commands produce Icon") and codesign rejects the
# leftover FinderInfo ("resource fork … detritus not allowed"). Strip both before
# every build so it never blocks compilation again.
find "$ROOT_DIR/Context-Dock" "$ROOT_DIR/Context-DockExtension" "$ROOT_DIR/Base.lproj" \
  -name $'Icon\r' -type f -delete 2>/dev/null || true
xattr -rc "$ROOT_DIR/Context-Dock" "$ROOT_DIR/Context-DockExtension" "$ROOT_DIR/Base.lproj" 2>/dev/null || true
# Also clean the already-built product: an incremental build won't recopy unchanged
# resources, so a stray "Icon"/"Icon\r" file copied into the bundle (e.g.
# Contents/MacOS/Icon) or leftover FinderInfo would still fail codesign.
if [ -d "$DERIVED_DATA_DIR/Build/Products" ]; then
  find "$DERIVED_DATA_DIR/Build/Products" \( -name 'Icon' -o -name $'Icon\r' \) -type f -delete 2>/dev/null || true
  xattr -rc "$DERIVED_DATA_DIR/Build/Products" 2>/dev/null || true
fi

# ENABLE_DEBUG_DYLIB=NO: Xcode 16 Debug builds default to splitting the executable
# into a thin stub + a separate Context-Dock.debug.dylib the stub loads at @rpath.
# With two agents (Claude + Codex, Desktop + VSCode) building into overlapping
# DerivedData, a launch can race another build and find the stub but not the dylib →
# "Namespace DYLD, Library not loaded: @rpath/Context-Dock.debug.dylib" SIGABRT, app
# never opens. Forcing a monolithic debug binary removes the missing-dylib failure mode.
xcodebuild \
  -project "$ROOT_DIR/Context-Dock.xcodeproj" \
  -scheme Context-Dock \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  -allowProvisioningUpdates \
  CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-YES}" \
  ENABLE_DEBUG_DYLIB=NO \
  build
# Default is SIGNED (Apple Development): unsigned ad-hoc builds have no stable
# designated requirement, so macOS re-prompts Accessibility/Keychain on every
# launch — deadly for an AX-driven app. Export CODE_SIGNING_ALLOWED=NO only for
# environments without the signing cert (CI).
