#!/usr/bin/env bash
#
# ship.sh — one command to release a beta build.
#
#   1. bump the build number
#   2. build Release (serial, to dodge the build.db prune flake)
#   3. make the DMG
#   4. commit the release on your work branch and push it
#   5. merge the work branch into main and push main
#   6. publish a GitHub Release with the DMG attached
#
# Usage:
#   ./scripts/ship.sh           # auto-increment the build number
#   ./scripts/ship.sh 9         # ship as an explicit build number
#
# Run it from a WORK branch (not main). Commit your code first — ship only
# handles the release bookkeeping, not your feature work.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

REPO="krishgokulk/Context-Dock"
APP_NAME="Context-Dock"
BUILD_ARG="${1:-}"

# Commit with hooks disabled so the CHANGES.md journal hook doesn't fire (and
# loop) during the automated release commits.
GIT_NOHOOK="git -c core.hooksPath=/dev/null"

log()  { printf '\n\033[1;36m▶ %s\033[0m\n' "$1"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$1"; }
die()  { printf '\033[1;31m✖ %s\033[0m\n' "$1" >&2; exit 1; }

ORIG_BRANCH="$(git rev-parse --abbrev-ref HEAD)"

# ── Preconditions ──────────────────────────────────────────────────────────
[ "$ORIG_BRANCH" != "main" ] || die "Run ship from a work branch, not main."

# Ignore the auto-generated CHANGES.md journal and untracked files; block only
# on real uncommitted source changes.
DIRTY="$(git status --porcelain --untracked-files=no | grep -v ' CHANGES.md$' || true)"
[ -z "$DIRTY" ] || die "You have uncommitted changes — commit your work first."

command -v python3 >/dev/null || die "python3 is required."

# Park the journal file so branch switches stay clean; restored at the end.
git stash push -q -m ship-journal -- CHANGES.md 2>/dev/null || true
restore_journal() {
  git stash list | grep -q 'ship-journal' && git stash pop -q 2>/dev/null || true
}

# ── 1. Bump build number ───────────────────────────────────────────────────
log "Bumping build number"
if [ -n "$BUILD_ARG" ]; then scripts/bump-build.sh "$BUILD_ARG"; else scripts/bump-build.sh; fi
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - Context-Dock/Info.plist)"
BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -o - Context-Dock/Info.plist)"
TAG="v${VERSION}-beta.${BUILD}"
DMG="$APP_NAME-$VERSION-beta.dmg"
ok "Shipping $VERSION ($BUILD) — tag $TAG"

# ── 2. Build Release ───────────────────────────────────────────────────────
log "Building Release (a few minutes)…"
BUILD_LOG="$(mktemp)"
rm -rf .build
# -jobs 1 avoids the new-build-system build.db race; the build can exit non-zero
# on the harmless post-build prune step, so we verify the product instead.
xcodebuild -project Context-Dock.xcodeproj -scheme "$APP_NAME" -configuration Release \
  -derivedDataPath .build/XcodeDerivedData -jobs 1 \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO clean build \
  > "$BUILD_LOG" 2>&1 || true

APP=".build/XcodeDerivedData/Build/Products/Release/$APP_NAME.app"
if [ ! -x "$APP/Contents/MacOS/$APP_NAME" ]; then
  tail -40 "$BUILD_LOG"
  restore_journal
  die "Release build failed (see log above)."
fi
BUILT="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")"
[ "$BUILT" = "$BUILD" ] || { restore_journal; die "Built app is build $BUILT, expected $BUILD."; }
ok "Built $APP_NAME $VERSION ($BUILD)"

# ── 3. DMG ─────────────────────────────────────────────────────────────────
log "Creating DMG"
scripts/make-dmg.sh >/dev/null || { restore_journal; die "DMG creation failed."; }
[ -f "$DMG" ] || { restore_journal; die "DMG not found: $DMG"; }
ok "Created $DMG"

# ── 4. Commit release on the work branch ───────────────────────────────────
log "Committing release on $ORIG_BRANCH"
$GIT_NOHOOK add Context-Dock/Info.plist Context-DockExtension/Info.plist \
  Context-Dock.xcodeproj/project.pbxproj update-manifest.json "$DMG"
$GIT_NOHOOK commit -q -m "release: beta build $BUILD"
git push -q origin "$ORIG_BRANCH"
ok "Pushed $ORIG_BRANCH"

# ── 5. Merge into main ─────────────────────────────────────────────────────
log "Merging into main"
git checkout -q main
git pull -q --ff-only origin main 2>/dev/null || true
$GIT_NOHOOK merge --no-ff --no-edit "$ORIG_BRANCH" >/dev/null \
  || { git merge --abort 2>/dev/null; git checkout -q "$ORIG_BRANCH"; restore_journal; \
       die "Merge into main hit conflicts — resolve by hand."; }
git push -q origin main
git checkout -q "$ORIG_BRANCH"
ok "main updated"

# ── 6. GitHub Release + DMG asset ──────────────────────────────────────────
log "Publishing GitHub Release $TAG"
TOKEN="$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>/dev/null | sed -n 's/^password=//p')"
[ -n "$TOKEN" ] || { restore_journal; die "No GitHub token in git credential store."; }
AUTH="Authorization: Bearer $TOKEN"
API="https://api.github.com/repos/$REPO"

# Build the JSON body with python into a temp file (no shell-quoting of the body —
# the em-dash + nested quotes used to corrupt it, producing an empty POST and a
# missing release). curl reads the file; then resolve the release id by tag with
# retries (GitHub may take a moment to index a brand-new release).
BODY_FILE="$(mktemp)"
RESP_FILE="$(mktemp)"
python3 - "$TAG" "$APP_NAME" "$VERSION" "$BUILD" > "$BODY_FILE" <<'PY'
import json, sys
tag, app, ver, build = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
notes = (f"Beta build {build}. Download the DMG, open it, drag {app} to "
         f"Applications. Unsigned beta — first launch may need right-click → "
         f"Open. Minimum macOS 26.1.")
print(json.dumps({
    "tag_name": tag, "target_commitish": "main",
    "name": f"{app} {ver} ({build}) — beta", "body": notes, "prerelease": True,
}))
PY
curl -s -X POST "$API/releases" -H "$AUTH" -H 'Accept: application/vnd.github+json' \
  -d @"$BODY_FILE" > "$RESP_FILE"

RID="$(python3 -c "import sys,json;print(json.load(open('$RESP_FILE')).get('id') or '')" 2>/dev/null)"
if [ -z "$RID" ]; then
  for _ in 1 2 3 4 5 6 7 8; do
    RID="$(curl -s "$API/releases/tags/$TAG" -H "$AUTH" \
      | python3 -c "import sys,json;print(json.load(sys.stdin).get('id') or '')" 2>/dev/null)"
    [ -n "$RID" ] && break
    sleep 2
  done
fi
rm -f "$BODY_FILE" "$RESP_FILE"
[ -n "$RID" ] || { restore_journal; die "Could not create or find the release."; }

# Replace any existing same-name asset, then upload.
curl -s "$API/releases/$RID/assets" -H "$AUTH" \
  | python3 -c "import sys,json;[print(a['id']) for a in json.load(sys.stdin) if a.get('name')=='$DMG']" 2>/dev/null \
  | while read -r aid; do [ -n "$aid" ] && curl -s -X DELETE "$API/releases/assets/$aid" -H "$AUTH" >/dev/null; done
STATE="$(curl -s -X POST "https://uploads.github.com/repos/$REPO/releases/$RID/assets?name=$DMG" \
  -H "$AUTH" -H 'Content-Type: application/octet-stream' --data-binary @"$DMG" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('state',''))" 2>/dev/null)"
[ "$STATE" = "uploaded" ] || { restore_journal; die "DMG asset upload failed."; }
ok "Release published with DMG"

restore_journal
printf '\n\033[1;32m🚀 Shipped %s (%s)\033[0m\n' "$VERSION" "$BUILD"
echo "   Release: https://github.com/$REPO/releases/tag/$TAG"
echo "   Homepage (main) now current."
