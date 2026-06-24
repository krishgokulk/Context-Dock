#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Context-Dock"
BUNDLE_ID="com.krishgokul.ContextDock"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/.build/XcodeDerivedData"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

build_app() {
  xcodebuild \
    -project "$ROOT_DIR/Context-Dock.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}" \
    build
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

# Build-only mode leaves the running app untouched (just compile-checks).
case "$MODE" in
  --build|build) ;;
  *) pkill -x "$APP_NAME" >/dev/null 2>&1 || true ;;
esac
build_app

case "$MODE" in
  run)
    open_app
    ;;
  --build|build)
    # Compile-check only — no relaunch. Fast loop for verifying edits.
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|build|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
