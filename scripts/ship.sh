#!/usr/bin/env bash
#
# ship.sh — step 2 of a release: publish what main already says.
#
#   ./scripts/ship.sh beta      # default
#   ./scripts/ship.sh stable
#
# Run from main, after the release PR from scripts/release-prep.sh has merged with green CI.
# It does not commit, merge or push anything — main is protected and merging is the PR's job
# (docs/master/00-ENGINEERING-OPERATING-MODEL.md §2.7). It:
#
#   1. checks main is clean, matches origin/main, has green CI, and names a build to ship
#   2. builds Release (serial, to dodge the build.db prune flake) and signs it
#   3. makes the DMG
#   4. publishes a GitHub Release at that commit with the DMG attached — exactly the URL the
#      channel's manifest on main already points at

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

REPO="krishgokulk/Context-Dock"
APP_NAME="Context-Dock"
CHANNEL="${1:-beta}"

log()  { printf '\n\033[1;36m▶ %s\033[0m\n' "$1"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$1"; }
die()  { printf '\033[1;31m✖ %s\033[0m\n' "$1" >&2; exit 1; }

[ "$CHANNEL" = "beta" ] || [ "$CHANNEL" = "stable" ] || die "Usage: ship.sh beta|stable"
command -v python3 >/dev/null || die "python3 is required."

# ── 1. Preconditions ───────────────────────────────────────────────────────
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || die "Ship from main, after the release PR has merged."
DIRTY="$(git status --porcelain --untracked-files=no | grep -v ' CHANGES.md$' || true)"
[ -z "$DIRTY" ] || die "main has uncommitted changes."
git fetch -q origin main || die "Could not fetch origin/main."
HEAD_SHA="$(git rev-parse HEAD)"
[ "$HEAD_SHA" = "$(git rev-parse origin/main)" ] || die "Local main is not origin/main — pull first."

TOKEN="$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>/dev/null | sed -n 's/^password=//p')"
[ -n "$TOKEN" ] || die "No GitHub token in git credential store."
AUTH="Authorization: Bearer $TOKEN"
API="https://api.github.com/repos/$REPO"

MANIFEST="update-manifest.json"
[ "$CHANNEL" = "stable" ] && MANIFEST="update-manifest-stable.json"
[ -f "$MANIFEST" ] || die "$MANIFEST missing — run scripts/release-prep.sh $CHANNEL and merge its PR."
read -r M_VERSION M_BUILD M_CHANNEL DMG_URL < <(python3 -c "
import json; m=json.load(open('$MANIFEST'))
print(m['version'], m['build'], m.get('channel',''), m['dmgURL'])")
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - Context-Dock/Info.plist)"
BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -o - Context-Dock/Info.plist)"
[ "$M_CHANNEL" = "$CHANNEL" ] || die "$MANIFEST is for channel '$M_CHANNEL', not '$CHANNEL'."
[ "$M_VERSION" = "$VERSION" ] && [ "$M_BUILD" = "$BUILD" ] \
  || die "$MANIFEST names $M_VERSION ($M_BUILD) but the app is $VERSION ($BUILD) — merge the release PR first."

TAG="$(python3 -c "import sys;print(sys.argv[1].split('/releases/download/')[1].split('/')[0])" "$DMG_URL")"
DMG_NAME="$(basename "$DMG_URL")"
[ "$(curl -s -o /dev/null -w '%{http_code}' -H "$AUTH" "$API/releases/tags/$TAG")" != "200" ] \
  || die "Release $TAG already exists."

# CI must have passed on this exact commit.
CI="$(curl -s -H "$AUTH" -H 'Accept: application/vnd.github+json' "$API/commits/$HEAD_SHA/check-runs" \
  | python3 -c "
import sys, json
runs = json.load(sys.stdin).get('check_runs', [])
if not runs: print('none')
elif all(r['status'] == 'completed' and r['conclusion'] in ('success', 'skipped', 'neutral') for r in runs): print('green')
else: print('not-green')")"
[ "$CI" = "green" ] || die "CI on $HEAD_SHA is '$CI' — ship only a commit whose checks passed."
ok "Shipping $CHANNEL $VERSION ($BUILD) from ${HEAD_SHA:0:7} — tag $TAG"

# ── 2. Build Release ───────────────────────────────────────────────────────
log "Building Release (a few minutes)…"
DERIVED=".build/ReleaseDerivedData"
BUILD_LOG="$(mktemp)"
# -jobs 1 avoids the new-build-system build.db race; the build can exit non-zero on the
# harmless post-build prune step, so the product is verified instead of the exit code.
# Built UNSIGNED (the project's stored team has no matching cert on this machine, and forcing
# automatic signing breaks the SPM deps), then signed below with the local Apple Development
# identity: a stable signature keeps macOS permissions across updates. An ad-hoc signature
# changes every build, and macOS then treats each update as a new app.
rm -rf "$DERIVED"
xcodebuild -project Context-Dock.xcodeproj -scheme "$APP_NAME" -configuration Release \
  -derivedDataPath "$DERIVED" -jobs 1 \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO clean build \
  > "$BUILD_LOG" 2>&1 || true

APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
if [ ! -x "$APP/Contents/MacOS/$APP_NAME" ]; then
  tail -40 "$BUILD_LOG"
  die "Release build failed (see log above)."
fi
BUILT="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")"
[ "$BUILT" = "$BUILD" ] || die "Built app is build $BUILT, expected $BUILD."

# ── Sign inside-out: nested code first, app last ───────────────────────────
SIGN_HASH="$(security find-identity -v -p codesigning | awk '/Apple Development/{print $2; exit}')"
[ -n "$SIGN_HASH" ] || die "No Apple Development signing identity found."
CS="codesign --force --timestamp=none --sign $SIGN_HASH"
if [ -d "$APP/Contents/Frameworks" ]; then
  find "$APP/Contents/Frameworks" \( -name '*.framework' -o -name '*.dylib' \) -print0 \
    | while IFS= read -r -d '' f; do $CS "$f" >/dev/null 2>&1 || true; done
fi
if [ -d "$APP/Contents/PlugIns/$APP_NAME"Extension.appex ]; then
  $CS --entitlements Context-DockExtension/Context-DockExtension.entitlements \
    "$APP/Contents/PlugIns/$APP_NAME"Extension.appex >/dev/null 2>&1 || true
fi
$CS --entitlements Context-Dock/ILauncher.entitlements "$APP" || die "Signing the app failed."

SIGN_AUTH="$(codesign -dvv "$APP" 2>&1 | awk -F'=' '/^Authority=/{print $2; exit}')"
codesign --verify --strict "$APP" >/dev/null 2>&1 || die "Signature verify failed."
if [ -z "$SIGN_AUTH" ] || echo "$SIGN_AUTH" | grep -qi "adhoc"; then
  die "Release is not stably signed (Authority='${SIGN_AUTH:-none}'). Permissions would reset on every update."
fi
ok "Built $APP_NAME $VERSION ($BUILD) — signed by $SIGN_AUTH"

# ── 3. DMG ─────────────────────────────────────────────────────────────────
log "Creating DMG"
DMG=".build/release/$DMG_NAME"
APP_BUNDLE="$APP" DMG_PATH="$DMG" CHANNEL="$CHANNEL" scripts/make-dmg.sh >/dev/null \
  || die "DMG creation failed."
[ -f "$DMG" ] || die "DMG not found: $DMG"
ok "Created $DMG"

# ── 4. GitHub Release + DMG asset ──────────────────────────────────────────
log "Publishing GitHub Release $TAG"
BODY_FILE="$(mktemp)"
RESP_FILE="$(mktemp)"
# The JSON body is written by python into a file: shell-quoting the em-dash and nested quotes
# once produced an empty POST and a missing release.
python3 - "$TAG" "$APP_NAME" "$VERSION" "$BUILD" "$CHANNEL" "$HEAD_SHA" "$MANIFEST" > "$BODY_FILE" <<'PY'
import json, sys
tag, app, ver, build, channel, sha, manifest = sys.argv[1:8]
notes = json.load(open(manifest)).get("notes", [])
lines = [f"- {n}" for n in notes] + ["",
    f"Download the DMG, open it, drag {app} to Applications. Signed with Apple Development — "
    "first launch may need right-click → Open. Minimum macOS 26.1."]
print(json.dumps({
    "tag_name": tag, "target_commitish": sha,
    "name": f"{app} {ver} ({build})" + (" — beta" if channel == "beta" else ""),
    "body": "\n".join(lines), "prerelease": channel == "beta",
}))
PY
curl -s -X POST "$API/releases" -H "$AUTH" -H 'Accept: application/vnd.github+json' \
  -d @"$BODY_FILE" > "$RESP_FILE"

RID="$(python3 -c "import sys,json;print(json.load(open('$RESP_FILE')).get('id') or '')" 2>/dev/null)"
if [ -z "$RID" ]; then
  # GitHub may take a moment to index a brand-new release.
  for _ in 1 2 3 4 5 6 7 8; do
    RID="$(curl -s "$API/releases/tags/$TAG" -H "$AUTH" \
      | python3 -c "import sys,json;print(json.load(sys.stdin).get('id') or '')" 2>/dev/null)"
    [ -n "$RID" ] && break
    sleep 2
  done
fi
rm -f "$BODY_FILE" "$RESP_FILE"
[ -n "$RID" ] || die "Could not create or find the release."

DOWNLOAD_URL="$(curl -s -X POST "https://uploads.github.com/repos/$REPO/releases/$RID/assets?name=$DMG_NAME" \
  -H "$AUTH" -H 'Content-Type: application/octet-stream' --data-binary @"$DMG" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('browser_download_url','') if d.get('state')=='uploaded' else '')" 2>/dev/null)"
[ -n "$DOWNLOAD_URL" ] || die "DMG asset upload failed."
[ "$DOWNLOAD_URL" = "$DMG_URL" ] || die "Uploaded to $DOWNLOAD_URL but $MANIFEST points at $DMG_URL."
ok "Release published with DMG"

printf '\n\033[1;32m🚀 Shipped %s %s (%s)\033[0m\n' "$CHANNEL" "$VERSION" "$BUILD"
echo "   Release: https://github.com/$REPO/releases/tag/$TAG"
echo "   Installed apps on the $CHANNEL channel see it on their next update check."
