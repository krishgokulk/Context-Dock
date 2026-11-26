#!/usr/bin/env python3
import json
import shutil
import subprocess
import sys


def main():
    try:
        ctx = json.loads(sys.stdin.read().strip() or "{}")
    except Exception:
        ctx = {}
    form = ctx.get("formValues") or {}
    q = (form.get("query") or ctx.get("query") or "").strip()
    if not q:
        print(json.dumps({"empty_message": "Enter a Homebrew package query and run Search Homebrew."}))
        return

    brew = shutil.which("brew") or "/opt/homebrew/bin/brew"
    proc = subprocess.run([brew, "search", q], capture_output=True, text=True, timeout=10)
    lines = [ln.strip() for ln in proc.stdout.splitlines() if ln.strip() and not ln.startswith("==>")]
    items = []
    for name in lines[:40]:
        items.append({
            "id": name,
            "title": name,
            "subtitle": f"brew install {name}",
            "icon": "shippingbox",
            "category": "Search",
            "actions": [
                {"id": "copy-install", "title": "Copy Install Command", "icon": "doc.on.doc", "shortcut": "↵", "kind": "copy", "value": f"brew install {name}"},
                {"id": "copy-info", "title": "Copy Info Command", "icon": "info.circle", "shortcut": "⌘C", "kind": "copy", "value": f"brew info {name}"},
            ]
        })
    print(json.dumps({
        "items": items,
        "empty_message": f"No Homebrew formulae or casks matched \"{q}\"."
    }))


if __name__ == "__main__":
    main()
