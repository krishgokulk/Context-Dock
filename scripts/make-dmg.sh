#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Context-Dock"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$ROOT_DIR/Context-Dock/Info.plist")"
# ship.sh passes APP_BUNDLE, DMG_PATH and CHANNEL; the defaults keep a bare run working.
CHANNEL="${CHANNEL:-beta}"
SUFFIX=""; [ "$CHANNEL" = "beta" ] && SUFFIX="-beta"
APP_BUNDLE="${APP_BUNDLE:-$ROOT_DIR/.build/XcodeDerivedData/Build/Products/Release/$APP_NAME.app}"
STAGE_DIR="$ROOT_DIR/.build/dmg-stage"
DMG_PATH="${DMG_PATH:-$ROOT_DIR/.build/release/$APP_NAME-$VERSION$SUFFIX.dmg}"
/bin/mkdir -p "$(dirname "$DMG_PATH")"

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
  -volname "$APP_NAME $VERSION${SUFFIX:+ beta}" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

/usr/bin/hdiutil verify "$DMG_PATH"
echo "Created $DMG_PATH"
