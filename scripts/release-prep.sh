#!/usr/bin/env bash
#
# release-prep.sh — step 1 of a release: open the release pull request.
#
#   ./scripts/release-prep.sh beta          # next build number, beta channel
#   ./scripts/release-prep.sh beta 17       # explicit build number
#   ./scripts/release-prep.sh stable        # stable: needs a version not yet released
#
# On a work branch, this bumps the build, writes the channel's update manifest (the DMG link
# is known in advance: it is the GitHub Release asset ship.sh will publish), commits, pushes
# and opens a PR into main. Merge the PR once CI is green, then run ./scripts/ship.sh <channel>
# from main right away — until it runs, the manifest names a DMG that does not exist yet.
#
# Beta writes update-manifest.json (every shipped build reads it). Stable writes
# update-manifest-stable.json and the beta manifest too, so beta users also get the stable build.
# Manifest notes come from the first bullets of the top section of CHANGELOG.md.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

REPO="krishgokulk/Context-Dock"
APP_NAME="Context-Dock"
CHANNEL="${1:-}"
BUILD_ARG="${2:-}"

die() { printf '\033[1;31m✖ %s\033[0m\n' "$1" >&2; exit 1; }
ok()  { printf '\033[1;32m✓ %s\033[0m\n' "$1"; }

[ "$CHANNEL" = "beta" ] || [ "$CHANNEL" = "stable" ] || die "Usage: release-prep.sh beta|stable [build]"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" != "main" ] || die "Run on a work branch — the release reaches main through its PR."
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "Commit or set aside your changes first."

TOKEN="$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>/dev/null | sed -n 's/^password=//p')"
[ -n "$TOKEN" ] || die "No GitHub token in the git credential store."
API="https://api.github.com/repos/$REPO"
AUTH="Authorization: Bearer $TOKEN"

if [ -n "$BUILD_ARG" ]; then scripts/bump-build.sh "$BUILD_ARG"; else scripts/bump-build.sh; fi
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - Context-Dock/Info.plist)"
BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -o - Context-Dock/Info.plist)"

if [ "$CHANNEL" = "beta" ]; then
  TAG="v${VERSION}-beta.${BUILD}"
  DMG="$APP_NAME-$VERSION-beta.dmg"
else
  TAG="v${VERSION}"
  DMG="$APP_NAME-$VERSION.dmg"
fi

STATUS="$(curl -s -o /dev/null -w '%{http_code}' -H "$AUTH" "$API/releases/tags/$TAG")"
if [ "$STATUS" = "200" ]; then
  git checkout -q -- Context-Dock/Info.plist Context-DockExtension/Info.plist Context-Dock.xcodeproj/project.pbxproj
  die "Release $TAG already exists. A stable release needs a new CFBundleShortVersionString."
fi

DMG_URL="https://github.com/$REPO/releases/download/$TAG/$DMG"
python3 - "$CHANNEL" "$VERSION" "$BUILD" "$DMG_URL" <<'PY'
import datetime, json, re, sys
channel, version, build, dmg_url = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]

# First bullets of the top "## " section of CHANGELOG.md, as user-facing notes.
notes, in_top = [], False
for line in open("CHANGELOG.md", encoding="utf-8"):
    if line.startswith("## "):
        if in_top:
            break
        in_top = True
        continue
    if in_top and re.match(r"^\s*- ", line):
        notes.append(line.strip()[2:])
notes = notes[:5] or [f"{channel.capitalize()} build {build}."]

manifest = {
    "version": version, "build": build, "channel": channel,
    "minimumSystemVersion": "26.1", "dmgURL": dmg_url,
    "releaseNotesURL": "https://github.com/krishgokulk/Context-Dock/blob/main/CHANGELOG.md",
    "publishedAt": datetime.date.today().isoformat(), "notes": notes,
}
files = ["update-manifest.json"] if channel == "beta" else ["update-manifest-stable.json", "update-manifest.json"]
for f in files:
    with open(f, "w", encoding="utf-8") as out:
        json.dump(manifest, out, indent=2, ensure_ascii=False)
        out.write("\n")
    print(f"wrote {f}")
PY

MANIFESTS="update-manifest.json"
[ "$CHANNEL" = "stable" ] && MANIFESTS="update-manifest.json update-manifest-stable.json"
# shellcheck disable=SC2086
git add Context-Dock/Info.plist Context-DockExtension/Info.plist Context-Dock.xcodeproj/project.pbxproj $MANIFESTS
git commit -q -m "release: $CHANNEL $VERSION ($BUILD)"
git push -q -u origin "$BRANCH"
ok "Committed and pushed release: $CHANNEL $VERSION ($BUILD) on $BRANCH"

BODY_FILE="$(mktemp)"
python3 - "$CHANNEL" "$VERSION" "$BUILD" "$BRANCH" "$TAG" > "$BODY_FILE" <<'PY'
import json, sys
channel, version, build, branch, tag = sys.argv[1:6]
body = (f"Release PR for **{channel} {version} ({build})**, tag `{tag}`.\n\n"
        "- [ ] CI is green\n- [ ] `CHANGELOG.md` top section describes this release\n\n"
        f"After merging, run `./scripts/ship.sh {channel}` from `main` straight away: until it "
        "runs, the manifest names a DMG that does not exist yet.")
print(json.dumps({"title": f"release: {channel} {version} ({build})", "head": branch,
                  "base": "main", "body": body}))
PY
PR_URL="$(curl -s -X POST "$API/pulls" -H "$AUTH" -H 'Accept: application/vnd.github+json' -d @"$BODY_FILE" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('html_url',''))")"
rm -f "$BODY_FILE"
[ -n "$PR_URL" ] && ok "Release PR: $PR_URL" \
  || echo "Could not open the PR automatically (one may already exist for $BRANCH) — open it on GitHub."
