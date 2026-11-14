#!/usr/bin/env bash
#
# corner.sh — open the Corner from a script. DEBUG builds only (DevCornerRemote.swift).
#
# Synthetic ⌘⌘ / ⌥⌥ never reach the app's global key monitor, so agents use this for hand
# checks instead of guessing at hotkeys.
#
#   scripts/corner.sh centre              ⌥⌥  — the centred launcher, scoped to the app in front
#   scripts/corner.sh bottom              ⌘⌘  — the bottom dock's field, scoped to the app in front
#   scripts/corner.sh global              Global Context, in whichever place is open
#   scripts/corner.sh general             General Chat
#   scripts/corner.sh cmd                 a single ⌘ tap: app <-> Global
#   scripts/corner.sh ask "question"      put text in the field and submit it
#   scripts/corner.sh attach /abs/path    attach a file to the next ask
#   scripts/corner.sh clear [bundle id]   delete the General Chat thread, or that app's thread
#   scripts/corner.sh hide                put the Corner away
#   scripts/corner.sh state               only report the state
#
#   --app <bundle id>   bring that app to the front first, so the Corner scopes to it
#
# Prints the state the app reports afterwards (corner-state.json, beside turns.log).

set -euo pipefail

if [ "${1:-}" = "--app" ]; then
    # `open -b` raises the window but can leave the menu bar with the previous app, and the
    # Corner scopes to the menu-bar owner. AppleScript activation moves both.
    osascript -e "tell application id \"$2\" to activate"
    sleep 1
    shift 2
fi

COMMAND="${1:?usage: corner.sh [--app <bundle id>] centre|bottom|global|general|cmd|ask <text>|attach <path>|clear [bundle id]|hide|state}"
[ "$COMMAND" = "ask" ] && COMMAND="ask:${2:?ask needs the question}"
[ "$COMMAND" = "clear" ] && COMMAND="clear:${2:-}"
[ "$COMMAND" = "attach" ] && COMMAND="attach:${2:?attach needs an absolute file path}"

pgrep -x Context-Dock >/dev/null || { echo "Context-Dock is not running — ./scripts/dev-run.sh first." >&2; exit 1; }

STATE="$HOME/Library/Application Support/Context-Dock/corner-state.json"
rm -f "$STATE"

CORNER_COMMAND="$COMMAND" osascript -l JavaScript -e '
ObjC.import("Foundation");
var command = $.NSProcessInfo.processInfo.environment.objectForKey("CORNER_COMMAND");
$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately(
    "com.krishgokul.ContextDock.dev.corner", command, $(), true);
' >/dev/null

for _ in $(seq 1 20); do
    [ -f "$STATE" ] && { cat "$STATE"; echo; exit 0; }
    sleep 0.25
done
echo "No state reported — is the running app a DEBUG build of this branch?" >&2
exit 1
