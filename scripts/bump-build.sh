#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PLIST="$ROOT_DIR/Context-Dock/Info.plist"
EXTENSION_PLIST="$ROOT_DIR/Context-DockExtension/Info.plist"
PROJECT_FILE="$ROOT_DIR/Context-Dock.xcodeproj/project.pbxproj"
MANIFEST="$ROOT_DIR/update-manifest.json"

current_build="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$APP_PLIST")"
new_build="${1:-}"

if [[ -z "$new_build" ]]; then
  new_build="$((current_build + 1))"
fi

if ! [[ "$new_build" =~ ^[0-9]+$ ]]; then
  echo "Build number must be integer: $new_build" >&2
  exit 2
fi

/usr/bin/plutil -replace CFBundleVersion -string "$new_build" "$APP_PLIST"
/usr/bin/plutil -replace CFBundleVersion -string "$new_build" "$EXTENSION_PLIST"
/usr/bin/perl -0pi -e "s/CURRENT_PROJECT_VERSION = \\d+;/CURRENT_PROJECT_VERSION = $new_build;/g" "$PROJECT_FILE"
/usr/bin/plutil -replace build -integer "$new_build" "$MANIFEST"
/usr/bin/plutil -replace publishedAt -string "$(/bin/date +%F)" "$MANIFEST"

echo "Bumped build: $current_build -> $new_build"
