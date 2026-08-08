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
sleep 0.5

# Signed (ad-hoc/dev) builds keep macOS Accessibility behavior consistent between
# runs; build-debug.sh defaults to unsigned, so override here.
CODE_SIGNING_ALLOWED=YES "$ROOT_DIR/scripts/build-debug.sh"

# Relaunch the exact app we just built.
open "$APP"
echo "Launched: $APP"
