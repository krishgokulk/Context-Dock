#!/usr/bin/env bash
# release-type-size.sh — how big LauncherView.body's opaque type is right now.
#
# The progress signal for #25. A Debug build proves nothing: Debug has always built. What
# matters is the size of the type SILGen prints while aborting, and whether it is going down.
#
#   ./scripts/release-type-size.sh            # build Release, then measure
#   ./scripts/release-type-size.sh <log>      # measure a log you already have
#
# Counting needs care. The compiler emits the substituted type TWICE — once plainly, once
# again prefixed with "| " inside the stack dump — while "Please submit a bug" appears only
# at the very end. A naive range between those two markers spans both copies and reports
# exactly double, which looks like a catastrophic regression and is not. This reads the first
# copy only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ $# -ge 1 ]; then
  LOG="$1"
  [ -f "$LOG" ] || { echo "no such log: $LOG" >&2; exit 1; }
else
  if pgrep -f "xcodebuild" >/dev/null 2>&1; then
    echo "another xcodebuild is running — wait for it." >&2
    echo "two builds against one DerivedData give 'database is locked' and a 0-test run." >&2
    exit 1
  fi
  LOG="/tmp/rel-$(git rev-parse --short HEAD).log"
  rm -rf .build/XcodeReleaseDerivedData
  echo "building Release (this takes ~12 minutes) → $LOG"
  set +e
  xcodebuild -project Context-Dock.xcodeproj -scheme Context-Dock \
    -configuration Release -derivedDataPath .build/XcodeReleaseDerivedData \
    -jobs 1 build > "$LOG" 2>&1
  echo "xcodebuild exit=$?"
  set -e
fi

if grep -q '^\*\* BUILD SUCCEEDED \*\*' "$LOG"; then
  echo
  echo "BUILD SUCCEEDED — there is no type to measure. #25 is done; verify with Task 9."
  exit 0
fi

if ! grep -q '^Substituted type:' "$LOG"; then
  echo "no substituted-type dump in this log — the build failed for some other reason:" >&2
  grep -nE "error:|Command .* failed" "$LOG" | head -5 >&2
  exit 1
fi

DUMP="$(mktemp)"
trap 'rm -f "$DUMP"' EXIT
awk '/^Substituted type:/{f=1} f&&/Please submit a bug/{exit} f' "$LOG" > "$DUMP"

printf 'commit          %s\n' "$(git rev-parse --short HEAD)"
printf 'opaque types    %s\n' "$(grep -c opaque_type "$DUMP")"
printf 'ModifiedContent %s\n' "$(grep -c ModifiedContent "$DUMP")"
printf 'dump lines      %s\n' "$(wc -l < "$DUMP" | tr -d ' ')"
echo
echo "-- the current worst offender is whatever these first decls name --"
# awk rather than `| head`, which closes the pipe and trips pipefail with SIGPIPE.
awk '/decl="/{ match($0, /decl="[^"]+"/); print substr($0, RSTART+5, RLENGTH-5); n++ } n>=8{exit}' "$DUMP"
