#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import safari_lib as sl


def main() -> None:
    ctx = sl.read_context()
    q, flt = sl.get_query_and_filter(ctx)
    bookmarks, err = sl.list_bookmarks()

    folders = sorted({b["folder"] for b in bookmarks if b.get("folder")})[:10]
    items = []
    for i, b in enumerate(bookmarks):
        if flt and flt != "All" and b["folder"] != flt:
            continue
        if q and q not in b["title"].lower() and q not in b["url"].lower() and q not in b["folder"].lower():
            continue
        url = b["url"]
        items.append({
            "id": f"bm:{i}:{url}",
            "title": b["title"],
            "subtitle": f"{b['folder']} · {sl.domain_of(url) or url}",
            "icon": "book.closed.fill",
            "category": b["folder"],
            "accessories": [{"kind": "tag", "text": b["folder"], "color": "#0EA5E9"}],
            "detail": {
                "markdown": f"### {b['title']}\n\n`{url}`",
                "metadata": [
                    {"label": "Folder", "value": b["folder"]},
                    {"label": "Domain", "value": sl.domain_of(url) or "Local"},
                ],
            },
            "actions": sl.standard_url_actions(url, b["title"]),
        })
        if len(items) >= 200:
            break

    if not items and err and "Full Disk Access" in err:
        items = [sl.permission_action_item(err)]

    print(json.dumps({
        "filter_options": ["All", *folders],
        "empty_message": err or "No matching Safari bookmarks.",
        "items": items,
    }))


if __name__ == "__main__":
    main()
