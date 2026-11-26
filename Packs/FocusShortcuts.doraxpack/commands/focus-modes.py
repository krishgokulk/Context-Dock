#!/usr/bin/env python3
import json
import sys


def main():
    _ = sys.stdin.read()
    items = [
        {
            "id": "dnd",
            "title": "Do Not Disturb",
            "subtitle": "Open Focus settings or toggle DND shortcut",
            "icon": "moon.fill",
            "accessories": [{"kind": "tag", "text": "Focus", "color": "#8B5CF6"}],
            "actions": [{"id": "open-focus", "title": "Open Focus Settings", "icon": "moon.fill", "shortcut": "↵", "kind": "open", "value": "x-apple.systempreferences:com.apple.Focus-Settings.extension"}]
        },
        {
            "id": "work",
            "title": "Work Focus",
            "subtitle": "Run 'Focus Work' shortcut if configured",
            "icon": "briefcase.fill",
            "accessories": [{"kind": "tag", "text": "Work", "color": "#38BDF8"}],
            "actions": [{"id": "run-work", "title": "Run Work Focus", "icon": "play.fill", "shortcut": "↵", "kind": "cli", "binary": "/usr/bin/shortcuts", "args": ["run", "Focus Work"]}]
        },
        {
            "id": "personal",
            "title": "Personal Focus",
            "subtitle": "Run 'Focus Personal' shortcut if configured",
            "icon": "person.fill",
            "accessories": [{"kind": "tag", "text": "Personal", "color": "#34D399"}],
            "actions": [{"id": "run-personal", "title": "Run Personal Focus", "icon": "play.fill", "shortcut": "↵", "kind": "cli", "binary": "/usr/bin/shortcuts", "args": ["run", "Focus Personal"]}]
        },
        {
            "id": "shortcuts-app",
            "title": "Open Shortcuts App",
            "subtitle": "Edit or create Focus automations",
            "icon": "square.stack.3d.up.fill",
            "app_icon_bundle_id": "com.apple.shortcuts",
            "accessories": [{"kind": "tag", "text": "App", "color": "#94A3B8"}],
            "actions": [{"id": "open-app", "title": "Open Shortcuts", "icon": "square.stack.3d.up.fill", "shortcut": "↵", "kind": "cli", "binary": "/usr/bin/open", "args": ["-a", "Shortcuts"]}]
        },
    ]
    print(json.dumps({"items": items}))


if __name__ == "__main__":
    main()
