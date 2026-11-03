#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_NUMBER=""
DO_COMMIT=0
DO_PUSH=0

usage() {
  cat >&2 <<'USAGE'
usage: scripts/release-beta.sh [--build N] [--commit] [--push]

Default:
  bump to next build, build Release, create DMG, verify DMG, show git diff.

Options:
  --build N   Use explicit build number.
  --commit    Commit release files after successful build.
  --push      Push after commit. Implies --commit.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)
      BUILD_NUMBER="${2:-}"
      shift 2
      ;;
    --commit)
      DO_COMMIT=1
      shift
      ;;
    --push)
      DO_COMMIT=1
      DO_PUSH=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

cd "$ROOT_DIR"

if [[ -n "$BUILD_NUMBER" ]]; then
  scripts/bump-build.sh "$BUILD_NUMBER"
else
  scripts/bump-build.sh
fi

scripts/build-release.sh
scripts/make-dmg.sh

new_build="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$ROOT_DIR/Context-Dock/Info.plist")"
version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$ROOT_DIR/Context-Dock/Info.plist")"
dmg_path="Context-Dock-$version-beta.dmg"

git status --short
git diff -- Context-Dock/Info.plist Context-DockExtension/Info.plist Context-Dock.xcodeproj/project.pbxproj update-manifest.json README.md

if [[ "$DO_COMMIT" -eq 1 ]]; then
  git add Context-Dock/Info.plist Context-DockExtension/Info.plist Context-Dock.xcodeproj/project.pbxproj update-manifest.json "$dmg_path"
  git commit -m "release: beta build $new_build"
fi

if [[ "$DO_PUSH" -eq 1 ]]; then
  git push
fi

echo "Beta release prepared: build $new_build"
