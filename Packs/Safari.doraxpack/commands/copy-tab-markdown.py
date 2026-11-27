#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import safari_lib as sl


def main() -> None:
    title, url = sl.frontmost_safari_tab()
    if not url:
        print(json.dumps({
            "detail": {"markdown": "### No Active Safari Tab\n\nOpen a tab in Safari to copy its Markdown link.", "metadata": []},
            "items": [],
        }))
        return

    md = f"[{title or url}]({url})"
    if os.environ.get("DORAX_CLIPBOARD_DRY_RUN") != "1":
        subprocess.run(["pbcopy"], input=md, text=True, check=True)

    print(json.dumps({
        "toast": f"Copied Markdown link for {title or url}",
        "detail": {
            "markdown": f"### Copied Markdown Link\n\n`{md}`",
            "metadata": [{"label": "Format", "value": "Markdown", "color": "#0EA5E9"}],
        },
        "items": [{
            "id": url,
            "title": md,
            "subtitle": title,
            "icon": "doc.on.clipboard",
            "actions": [{"id": "copy-md", "title": "Copy Markdown Link", "icon": "doc.on.clipboard", "shortcut": "↵", "kind": "copy", "value": md}],
        }],
    }))


if __name__ == "__main__":
    main()
