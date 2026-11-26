#!/usr/bin/env python3
import json
import shutil
import subprocess
import sys


def parse_lines(raw, category):
    items = []
    color = "#F59E0B" if category == "Formula" else "#38BDF8"
    icon = "terminal" if category == "Formula" else "app.badge"
    for line in (raw or "").splitlines():
        parts = line.strip().split()
        if not parts:
            continue
        name = parts[0]
        versions = " ".join(parts[1:]) if len(parts) > 1 else "installed"
        items.append({
            "id": f"{category.lower()}:{name}",
            "title": name,
            "subtitle": f"{category} · {versions}",
            "icon": icon,
            "category": category,
            "accessories": [
                {"kind": "tag", "text": category, "color": color},
                {"kind": "metric", "text": parts[1] if len(parts) > 1 else "-"}
            ],
            "detail": {
                "markdown": f"### {name}\n\n**Type:** {category}\n\n**Installed versions:** `{versions}`\n\n`brew info {name}`",
                "metadata": [
                    {"label": "Kind", "value": category, "color": color},
                    {"label": "Version", "value": versions},
                ]
            },
            "actions": [
                {"id": "copy-upgrade", "title": "Copy Upgrade Command", "icon": "arrow.up.circle", "shortcut": "↵", "kind": "copy", "value": f"brew upgrade {name}"},
                {"id": "copy-info", "title": "Copy Info Command", "icon": "info.circle", "shortcut": "⌘C", "kind": "copy", "value": f"brew info {name}"},
                {"id": "uninstall", "title": "Uninstall Package", "icon": "trash", "kind": "cli", "binary": "/opt/homebrew/bin/brew", "args": ["uninstall", name], "destructive": True, "confirm_message": f"Uninstall {name} via Homebrew?"},
            ]
        })
    return items


def main():
    _ = sys.stdin.read()
    brew = shutil.which("brew") or "/opt/homebrew/bin/brew"
    try:
        f_proc = subprocess.run([brew, "list", "--formula", "--versions"], capture_output=True, text=True, timeout=6)
        c_proc = subprocess.run([brew, "list", "--cask", "--versions"], capture_output=True, text=True, timeout=6)
    except Exception as exc:
        print(json.dumps({"detail": {"markdown": f"### Homebrew Error\n`{exc}`"}}))
        return

    items = parse_lines(f_proc.stdout, "Formula") + parse_lines(c_proc.stdout, "Cask")
    print(json.dumps({
        "items": items,
        "filter_options": ["All", "Formula", "Cask"],
        "empty_message": "No Homebrew packages found."
    }))


if __name__ == "__main__":
    main()
