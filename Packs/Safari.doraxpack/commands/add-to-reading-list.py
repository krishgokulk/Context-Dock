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
            "empty_message": "No active Safari tab found.",
            "detail": {"markdown": "### No Active Safari Tab\n\nOpen a page in Safari first, then run **Add to Safari Reading List**.", "metadata": []},
            "items": [],
        }))
        return

    script = (
        "on run argv\n"
        'tell application "Safari" to add reading list item (item 1 of argv) with title (item 2 of argv)\n'
        "end run\n"
    )
    res = subprocess.run(["osascript", "-", url, title or url], input=script, text=True, capture_output=True, timeout=6)
    if res.returncode != 0:
        err = (res.stderr or res.stdout or "Failed to add to Reading List").strip()
        print(json.dumps({"detail": {"markdown": f"### Failed\n\n{err}", "metadata": []}, "items": []}))
        return

    print(json.dumps({
        "toast": f"Saved to Reading List: {title or url}",
        "detail": {
            "markdown": f"### Added to Reading List\n\n**{title or url}**\n\n`{url}`",
            "metadata": [{"label": "Domain", "value": sl.domain_of(url) or "Web"}, {"label": "Status", "value": "Saved", "color": "#10B981"}],
        },
        "items": [{
            "id": url,
            "title": title or url,
            "subtitle": url,
            "icon": "eyeglasses",
            "actions": sl.standard_url_actions(url, title or url),
        }],
    }))


if __name__ == "__main__":
    main()
