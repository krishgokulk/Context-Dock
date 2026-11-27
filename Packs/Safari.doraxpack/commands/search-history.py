#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import safari_lib as sl


def main() -> None:
    ctx = sl.read_context()
    q, _ = sl.get_query_and_filter(ctx)
    history, err = sl.list_history(limit=250)

    items = []
    for i, h in enumerate(history):
        if q and q not in h["title"].lower() and q not in h["url"].lower():
            continue
        url = h["url"]
        items.append({
            "id": f"hist:{i}:{url}",
            "title": h["title"],
            "subtitle": f"{sl.domain_of(url) or url} · {h['visited']}",
            "icon": "clock.arrow.circlepath",
            "accessories": [{"kind": "date", "text": f"{h['visits']}×", "color": "#0EA5E9"}],
            "detail": {
                "markdown": f"### {h['title']}\n\n`{url}`",
                "metadata": [
                    {"label": "Visited", "value": h["visited"]},
                    {"label": "Visits", "value": str(h["visits"])},
                    {"label": "Domain", "value": sl.domain_of(url) or "Web"},
                ],
            },
            "actions": sl.standard_url_actions(url, h["title"]),
        })

    if not items and err and "Full Disk Access" in err:
        items = [sl.permission_action_item(err)]

    print(json.dumps({
        "empty_message": err or "No matching Safari history items.",
        "items": items,
    }))


if __name__ == "__main__":
    main()
