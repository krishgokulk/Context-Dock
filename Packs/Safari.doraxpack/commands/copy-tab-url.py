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
            "detail": {"markdown": "### No Active Safari Tab\n\nOpen a tab in Safari to copy its URL.", "metadata": []},
            "items": [],
        }))
        return

    if os.environ.get("DORAX_CLIPBOARD_DRY_RUN") != "1":
        subprocess.run(["pbcopy"], input=url, text=True, check=True)

    print(json.dumps({
        "toast": f"Copied URL: {url}",
        "detail": {
            "markdown": f"### Copied URL\n\n`{url}`",
            "metadata": [{"label": "Page", "value": title or url}, {"label": "Clipboard", "value": "URL", "color": "#0EA5E9"}],
        },
        "items": [{
            "id": url,
            "title": url,
            "subtitle": title,
            "icon": "link",
            "actions": [{"id": "copy-url", "title": "Copy URL Again", "icon": "link", "shortcut": "↵", "kind": "copy", "value": url}],
        }],
    }))


if __name__ == "__main__":
    main()
