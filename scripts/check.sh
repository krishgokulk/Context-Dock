#!/usr/bin/env bash
# The fast gate: Debug build + oversized-file report. Every agent runs this before it
# finishes (the .claude Stop hook calls it); CI will run it on every PR.
#
#   ./scripts/check.sh          build + file-size report
#   ./scripts/check.sh --full   also run the whole test suite (scripts/test.sh)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$ROOT_DIR/.build/check.log"
MAX_LINES=1500
mkdir -p "$ROOT_DIR/.build"

# Another session's build is already running into the shared DerivedData — don't race it.
if pgrep -qf "xcodebuild.*Context-Dock" 2>/dev/null; then
  echo "check: another Context-Dock build is running; skipped (re-run when it finishes)."
  exit 0
fi

APP_BIN="$ROOT_DIR/.build/XcodeDerivedData/Build/Products/Debug/Context-Dock.app/Contents/MacOS/Context-Dock"
START_MARK="$ROOT_DIR/.build/check.start"
touch "$START_MARK"

echo "check: building Debug…"
if ! "$ROOT_DIR/scripts/build-debug.sh" >"$LOG" 2>&1; then
  # xcodebuild can exit non-zero on the trailing PruneExplicitPrecompiledModules step with
  # "build.db: disk I/O error" after compile, link and sign all succeeded — the product is
  # fine (ship.sh tolerates the same flake by checking the product). Pass only when that
  # is the ONLY error and the binary was rebuilt by this run; any other error still fails.
  other_errors="$(grep -E "error:" "$LOG" | grep -Ev 'build\.db.*disk I/O error' || true)"
  if [ -z "$other_errors" ] && [ -x "$APP_BIN" ] && [ "$APP_BIN" -nt "$START_MARK" ]; then
    echo "check: warning — xcodebuild hit the known build.db prune flake; the app was built fresh, treating as OK."
  else
    echo "check: BUILD FAILED — last errors (full log: .build/check.log):"
    grep -E "error:" "$LOG" | head -20 || tail -30 "$LOG"
    exit 1
  fi
fi
echo "check: build OK"

# Warn (not fail) when a changed Swift file is over the size limit. Flip to a failure once
# the existing giants are split (docs/master/00-CODEBASE-PLAN.md §3).
changed="$(git -C "$ROOT_DIR" diff --name-only HEAD -- '*.swift' 2>/dev/null || true)"
for f in $changed; do
  [ -f "$ROOT_DIR/$f" ] || continue
  n=$(wc -l <"$ROOT_DIR/$f")
  [ "$n" -gt "$MAX_LINES" ] && echo "check: warning — $f is $n lines (limit $MAX_LINES). Don't grow it; split if you can."
done

if [ "${1:-}" = "--full" ]; then
  echo "check: running tests…"
  "$ROOT_DIR/scripts/test.sh"
fi
echo "check: done"
