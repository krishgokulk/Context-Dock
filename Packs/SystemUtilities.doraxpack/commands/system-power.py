#!/usr/bin/env python3
import json
import re
import subprocess
import sys


def battery_summary():
    r = subprocess.run(["/usr/bin/pmset", "-g", "batt"], capture_output=True, text=True, timeout=3).stdout
    m = re.search(r"(\d+%)", r)
    pct = m.group(1) if m else "AC"
    src = "Battery" if "Battery Power" in r else "AC Power"
    return pct, src


def main():
    _ = sys.stdin.read()
    pct, src = battery_summary()
    items = [
        {
            "id": "battery",
            "title": f"Battery · {pct}",
            "subtitle": f"Source: {src}",
            "icon": "battery.100.bolt",
            "accessories": [{"kind": "tag", "text": pct, "color": "#34D399"}],
            "actions": [{"id": "copy-batt", "title": "Copy Battery Status", "icon": "doc.on.doc", "shortcut": "↵", "kind": "copy", "value": f"Battery {pct} ({src})"}]
        },
        {
            "id": "lock-screen",
            "title": "Lock Screen",
            "subtitle": "Put display to sleep / Lock Mac",
            "icon": "lock.fill",
            "accessories": [{"kind": "tag", "text": "Lock", "color": "#38BDF8"}],
            "actions": [{"id": "lock", "title": "Lock Display", "icon": "lock.fill", "shortcut": "↵", "kind": "cli", "binary": "/usr/bin/pmset", "args": ["displaysleepnow"]}]
        },
        {
            "id": "sleep-mac",
            "title": "Sleep Mac",
            "subtitle": "Put Mac to sleep (requires confirmation)",
            "icon": "powersleep",
            "accessories": [{"kind": "tag", "text": "Confirm", "color": "#F59E0B"}],
            "actions": [{"id": "sleep", "title": "Sleep Mac", "icon": "powersleep", "shortcut": "↵", "kind": "cli", "binary": "/usr/bin/osascript", "args": ["-e", 'tell application "System Events" to sleep'], "destructive": True, "confirm_message": "Put this Mac to sleep now?"}]
        },
        {
            "id": "empty-trash",
            "title": "Empty Trash",
            "subtitle": "Permanently delete items in Trash (requires confirmation)",
            "icon": "trash.fill",
            "accessories": [{"kind": "tag", "text": "Destructive", "color": "#EF4444"}],
            "actions": [{"id": "trash", "title": "Empty Trash", "icon": "trash", "shortcut": "↵", "kind": "cli", "binary": "/usr/bin/osascript", "args": ["-e", 'tell application "Finder" to empty trash'], "destructive": True, "confirm_message": "Permanently empty all items in the macOS Trash?"}]
        },
        {
            "id": "restart-mac",
            "title": "Restart Mac",
            "subtitle": "Restart this Mac safely (requires confirmation)",
            "icon": "arrow.clockwise.circle.fill",
            "accessories": [{"kind": "tag", "text": "Destructive", "color": "#EF4444"}],
            "actions": [{"id": "restart", "title": "Restart Mac", "icon": "arrow.clockwise.circle", "shortcut": "↵", "kind": "cli", "binary": "/usr/bin/osascript", "args": ["-e", 'tell application "System Events" to restart'], "destructive": True, "confirm_message": "Restart your Mac now?"}]
        },
        {
            "id": "shutdown-mac",
            "title": "Shut Down Mac",
            "subtitle": "Power off this Mac safely (requires confirmation)",
            "icon": "power.circle.fill",
            "accessories": [{"kind": "tag", "text": "Destructive", "color": "#EF4444"}],
            "actions": [{"id": "shutdown", "title": "Shut Down Mac", "icon": "power", "shortcut": "↵", "kind": "cli", "binary": "/usr/bin/osascript", "args": ["-e", 'tell application "System Events" to shut down'], "destructive": True, "confirm_message": "Shut down your Mac now?"}]
        },
    ]
    print(json.dumps({"items": items}))


if __name__ == "__main__":
    main()
