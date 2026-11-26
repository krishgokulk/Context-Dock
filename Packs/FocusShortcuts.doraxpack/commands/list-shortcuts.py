#!/usr/bin/env python3
import json
import subprocess
import sys


def main():
    _ = sys.stdin.read()
    try:
        proc = subprocess.run(["/usr/bin/shortcuts", "list"], capture_output=True, text=True, timeout=6)
        names = [ln.strip() for ln in proc.stdout.splitlines() if ln.strip()]
    except Exception as exc:
        print(json.dumps({"detail": {"markdown": f"### Shortcuts Error\n`{exc}`"}}))
        return

    items = []
    for name in names:
        items.append({
            "id": name,
            "title": name,
            "subtitle": f"shortcuts run \"{name}\"",
            "icon": "square.stack.3d.up.fill",
            "app_icon_bundle_id": "com.apple.shortcuts",
            "category": "Shortcut",
            "accessories": [{"kind": "tag", "text": "Shortcut", "color": "#8B5CF6"}],
            "detail": {
                "markdown": f"### {name}\n\n**CLI:** `shortcuts run \"{name}\"`\n\nPress `↵` to execute this shortcut now.",
                "metadata": [
                    {"label": "App", "value": "Shortcuts", "color": "#8B5CF6"},
                ]
            },
            "actions": [
                {"id": "run", "title": "Run Shortcut", "icon": "play.fill", "shortcut": "↵", "kind": "cli", "binary": "/usr/bin/shortcuts", "args": ["run", name]},
                {"id": "open-app", "title": "Open Shortcuts App", "icon": "square.stack.3d.up.fill", "shortcut": "⌘O", "kind": "cli", "binary": "/usr/bin/open", "args": ["-a", "Shortcuts"]},
                {"id": "copy-cli", "title": "Copy CLI Command", "icon": "doc.on.doc", "shortcut": "⌘C", "kind": "copy", "value": f"shortcuts run \"{name}\""},
            ]
        })

    print(json.dumps({
        "items": items,
        "empty_message": "No Apple Shortcuts found. Open the Shortcuts app to create one."
    }))


if __name__ == "__main__":
    main()
