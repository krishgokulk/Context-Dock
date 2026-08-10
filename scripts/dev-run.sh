#!/usr/bin/env bash
#
# dev-run.sh — THE canonical build + relaunch for local development.
#
# Every agent (Claude Code, Codex) and every human MUST use this after code edits.
# Do NOT run raw `xcodebuild` + `open` on a DerivedData path: this project has had
# three different Context-Dock.app copies (Xcode's default DerivedData, a stale
# hashed DerivedData, and .build/XcodeDerivedData), and launching the wrong one
# means testing stale code.
#
# Single source of truth:
#   build  → .build/XcodeDerivedData   (repo-local, gitignored, via build-debug.sh)
#   launch → .build/XcodeDerivedData/Build/Products/Debug/Context-Dock.app

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT_DIR/.build/XcodeDerivedData/Build/Products/Debug/Context-Dock.app"

# Quit BEFORE building, not after. The build rewrites and re-signs the .app in place,
# so a running instance has its bundle replaced underneath it. The process survives
# until something reads the bundle again — and then CFBundleGetValueForInfoKey throws,
# AppKit rethrows it out of the status-item scene, and the app aborts. That crash looks
# like it belongs to whatever the user was doing at the time, which is exactly how it
# got blamed on a chat thread.
pkill -x Context-Dock 2>/dev/null || true

# Verify it actually went. `open` on an app that is already running does not start a
# new process — it activates the old one and still exits 0, so a survivor here means
# the script cheerfully reports "Launched" while you go on testing the previous build.
# That has already cost a debugging session: a process 34 minutes older than the binary
# answering questions about code it did not contain.
for _ in $(seq 1 20); do
    pgrep -x Context-Dock >/dev/null || break
    sleep 0.25
done
if pgrep -x Context-Dock >/dev/null; then
    echo "Context-Dock ignored SIGTERM; forcing." >&2
    pkill -9 -x Context-Dock 2>/dev/null || true
    sleep 0.5
fi
if pgrep -x Context-Dock >/dev/null; then
    echo "ERROR: Context-Dock is still running and will not quit. Not launching a" >&2
    echo "       second copy — the old one would keep the hotkeys and you would be" >&2
    echo "       testing stale code." >&2
    exit 1
fi

# Signed (ad-hoc/dev) builds keep macOS Accessibility behavior consistent between
# runs; build-debug.sh defaults to unsigned, so override here.
CODE_SIGNING_ALLOWED=YES "$ROOT_DIR/scripts/build-debug.sh"

# Relaunch the exact app we just built.
open "$APP"

# Confirm something actually came up, and that it is this bundle. Reporting the pid and
# its start time makes "am I testing the new build?" answerable without guessing.
for _ in $(seq 1 20); do
    pgrep -x Context-Dock >/dev/null && break
    sleep 0.25
done
PID="$(pgrep -x Context-Dock || true)"
if [ -z "$PID" ]; then
    echo "ERROR: build succeeded but Context-Dock did not start." >&2
    exit 1
fi
echo "Launched: $APP"
echo "  pid $PID, started $(ps -p "$PID" -o lstart= | sed 's/^ *//')"
