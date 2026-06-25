#!/usr/bin/env bash
# scripts/notarize.sh
# Full archive → Developer ID sign → notarize → staple → DMG pipeline.
#
# Prerequisites:
#   - Xcode with an active Developer ID Application certificate in Keychain
#   - An app-specific password stored in Keychain:
#       xcrun notarytool store-credentials "AC_PASSWORD" \
#         --apple-id your@email.com --team-id F4PP2L7U76 --password <app-specific-password>
#   - Then pass --keychain-profile AC_PASSWORD (or use --apple-id / --password directly)
#
# Usage:
#   scripts/notarize.sh --keychain-profile AC_PASSWORD
#   scripts/notarize.sh --apple-id your@email.com --password "@keychain:AC_PASSWORD"
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Context-Dock"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "Context-Dock/Info.plist")"
BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "Context-Dock/Info.plist")"

ARCHIVE_PATH=".build/archive/$APP_NAME.xcarchive"
EXPORT_PATH=".build/export"
APP_BUNDLE="$EXPORT_PATH/$APP_NAME.app"
STAGE_DIR=".build/dmg-stage"
DMG_PATH="$APP_NAME-$VERSION.dmg"

# Notarytool auth — pass either --keychain-profile or (--apple-id + --password)
NOTARY_ARGS=()
APPLE_ID=""
APP_PASSWORD=""
KEYCHAIN_PROFILE=""
TEAM_ID="F4PP2L7U76"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apple-id)       APPLE_ID="$2";         shift 2 ;;
    --password)       APP_PASSWORD="$2";     shift 2 ;;
    --team-id)        TEAM_ID="$2";          shift 2 ;;
    --keychain-profile) KEYCHAIN_PROFILE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -n "$KEYCHAIN_PROFILE" ]]; then
  NOTARY_ARGS=(--keychain-profile "$KEYCHAIN_PROFILE")
elif [[ -n "$APPLE_ID" && -n "$APP_PASSWORD" ]]; then
  NOTARY_ARGS=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD")
else
  echo "Error: pass --keychain-profile NAME  or  --apple-id EMAIL --password PASS" >&2
  exit 1
fi

echo "▶ Archiving $APP_NAME $VERSION (build $BUILD)…"
mkdir -p .build/archive
xcodebuild archive \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  | xcpretty 2>/dev/null || true

echo "▶ Exporting with Developer ID…"
rm -rf "$EXPORT_PATH"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist scripts/ExportOptions-DevID.plist \
  -allowProvisioningUpdates

echo "▶ Verifying signature…"
codesign --verify --deep --strict --verbose=1 "$APP_BUNDLE"
spctl --assess --type exec --verbose "$APP_BUNDLE"

echo "▶ Creating DMG…"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$APP_BUNDLE" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"
hdiutil verify "$DMG_PATH"

echo "▶ Submitting for notarization…"
xcrun notarytool submit "$DMG_PATH" \
  "${NOTARY_ARGS[@]}" \
  --wait \
  --verbose

echo "▶ Stapling ticket…"
xcrun stapler staple "$DMG_PATH"

echo "▶ Validating stapled DMG…"
spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"

echo ""
echo "✅ Signed, notarized, and stapled: $DMG_PATH"
