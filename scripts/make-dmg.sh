#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Context-Dock"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$ROOT_DIR/Context-Dock/Info.plist")"
DERIVED_DATA_DIR="$ROOT_DIR/.build/XcodeDerivedData"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/Release/$APP_NAME.app"
STAGE_DIR="$ROOT_DIR/.build/dmg-stage"
DMG_PATH="$ROOT_DIR/$APP_NAME-$VERSION-beta.dmg"

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Missing Release app: $APP_BUNDLE" >&2
  echo "Run scripts/build-release.sh first." >&2
  exit 1
fi

/bin/rm -rf "$STAGE_DIR"
/bin/mkdir -p "$STAGE_DIR"
/bin/cp -R "$APP_BUNDLE" "$STAGE_DIR/"
/bin/ln -s /Applications "$STAGE_DIR/Applications"

/usr/bin/hdiutil create \
  -volname "$APP_NAME $VERSION beta" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

/usr/bin/hdiutil verify "$DMG_PATH"
echo "Created $DMG_PATH"
