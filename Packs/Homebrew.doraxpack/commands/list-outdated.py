#!/usr/bin/env python3
import json
import shutil
import subprocess
import sys


def main():
    _ = sys.stdin.read()
    brew = shutil.which("brew") or "/opt/homebrew/bin/brew"
    try:
        proc = subprocess.run([brew, "outdated", "--json=v2"], capture_output=True, text=True, timeout=10)
        data = json.loads(proc.stdout or "{}")
    except Exception as exc:
        print(json.dumps({"detail": {"markdown": f"### Brew Outdated Error\n`{exc}`"}}))
        return

    items = []
    for f in data.get("formulae", []):
        name = f.get("name", "formula")
        installed = ", ".join(f.get("installed_versions") or [])
        current = f.get("current_version", "")
        items.append({
            "id": f"formula:{name}",
            "title": name,
            "subtitle": f"{installed} → {current}",
            "icon": "arrow.up.circle.fill",
            "category": "Formula",
            "accessories": [
                {"kind": "tag", "text": "Formula", "color": "#F59E0B"},
                {"kind": "metric", "text": current}
            ],
            "actions": [
                {"id": "upgrade", "title": "Upgrade Package", "icon": "arrow.up.circle", "shortcut": "↵", "kind": "cli", "binary": brew, "args": ["upgrade", name]},
                {"id": "copy", "title": "Copy Upgrade Command", "icon": "doc.on.doc", "shortcut": "⌘C", "kind": "copy", "value": f"brew upgrade {name}"},
            ]
        })

    for c in data.get("casks", []):
        name = c.get("name", "cask")
        installed = ", ".join(c.get("installed_versions") or [])
        current = c.get("current_version", "")
        items.append({
            "id": f"cask:{name}",
            "title": name,
            "subtitle": f"{installed} → {current}",
            "icon": "app.badge.checkmark",
            "category": "Cask",
            "accessories": [
                {"kind": "tag", "text": "Cask", "color": "#38BDF8"},
                {"kind": "metric", "text": current}
            ],
            "actions": [
                {"id": "upgrade", "title": "Upgrade Cask", "icon": "arrow.up.circle", "shortcut": "↵", "kind": "cli", "binary": brew, "args": ["upgrade", "--cask", name]},
                {"id": "copy", "title": "Copy Upgrade Command", "icon": "doc.on.doc", "shortcut": "⌘C", "kind": "copy", "value": f"brew upgrade --cask {name}"},
            ]
        })

    print(json.dumps({
        "items": items,
        "filter_options": ["All", "Formula", "Cask"],
        "empty_message": "All Homebrew formulae and casks are up to date!"
    }))


if __name__ == "__main__":
    main()
