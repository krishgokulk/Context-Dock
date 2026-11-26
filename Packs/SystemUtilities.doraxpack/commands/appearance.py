#!/usr/bin/env python3
import json
import subprocess
import sys


def current_dark_mode():
    r = subprocess.run(["/usr/bin/defaults", "read", "-g", "AppleInterfaceStyle"], capture_output=True, text=True, timeout=3)
    return "dark" in (r.stdout or "").lower()


def main():
    _ = sys.stdin.read()
    is_dark = current_dark_mode()
    items = [
        {
            "id": "toggle",
            "title": "Toggle Dark / Light Mode",
            "subtitle": f"Currently: {'Dark' if is_dark else 'Light'} Mode",
            "icon": "circle.lefthalf.filled",
            "accessories": [{"kind": "tag", "text": "Dark" if is_dark else "Light", "color": "#38BDF8"}],
            "actions": [{"id": "toggle", "title": "Toggle Appearance", "icon": "circle.lefthalf.filled", "shortcut": "↵", "kind": "script", "script": "commands/set-appearance.py", "value": "toggle"}]
        },
        {
            "id": "dark",
            "title": "Dark Mode",
            "subtitle": "Switch macOS appearance to Dark",
            "icon": "moon.fill",
            "accessories": [{"kind": "tag", "text": "Active" if is_dark else "Switch", "color": "#818CF8" if is_dark else "#64748B"}],
            "actions": [{"id": "set-dark", "title": "Enable Dark Mode", "icon": "moon.fill", "shortcut": "↵", "kind": "script", "script": "commands/set-appearance.py", "value": "dark"}]
        },
        {
            "id": "light",
            "title": "Light Mode",
            "subtitle": "Switch macOS appearance to Light",
            "icon": "sun.max.fill",
            "accessories": [{"kind": "tag", "text": "Active" if not is_dark else "Switch", "color": "#FBBF24" if not is_dark else "#64748B"}],
            "actions": [{"id": "set-light", "title": "Enable Light Mode", "icon": "sun.max.fill", "shortcut": "↵", "kind": "script", "script": "commands/set-appearance.py", "value": "light"}]
        },
        {
            "id": "prefs",
            "title": "Open Appearance Settings",
            "subtitle": "System Settings ▸ Appearance",
            "icon": "gearshape.fill",
            "accessories": [{"kind": "tag", "text": "Settings", "color": "#94A3B8"}],
            "actions": [{"id": "open-prefs", "title": "Open Settings", "icon": "gearshape", "shortcut": "↵", "kind": "open", "value": "x-apple.systempreferences:com.apple.Appearance-Settings.extension"}]
        },
    ]
    print(json.dumps({"items": items}))


if __name__ == "__main__":
    main()
