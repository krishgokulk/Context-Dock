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
    entries, err = sl.list_reading_list()

    items = []
    for i, e in enumerate(entries):
        cat = "Read" if e["is_read"] else "Unread"
        if flt and flt != "All" and cat != flt:
            continue
        if q and q not in e["title"].lower() and q not in e["url"].lower() and q not in e["preview"].lower():
            continue
        url = e["url"]
        badge_color = "#6B7280" if e["is_read"] else "#0EA5E9"
        preview_md = f"\n\n> {e['preview']}" if e["preview"] else ""
        meta = [
            {"label": "Status", "value": cat, "color": badge_color},
            {"label": "Domain", "value": sl.domain_of(url) or "Web"},
        ]
        if e["added"]:
            meta.append({"label": "Added", "value": e["added"]})
        items.append({
            "id": f"rl:{i}:{url}",
            "title": e["title"],
            "subtitle": sl.domain_of(url) or url,
            "icon": "eyeglasses",
            "category": cat,
            "accessories": [{"kind": "badge", "text": cat, "color": badge_color}],
            "detail": {
                "markdown": f"### {e['title']}\n\n`{url}`{preview_md}",
                "metadata": meta,
            },
            "actions": sl.standard_url_actions(url, e["title"]),
        })

    if not items and err and "Full Disk Access" in err:
        items = [sl.permission_action_item(err)]

    print(json.dumps({
        "filter_options": ["All", "Unread", "Read"],
        "empty_message": err or "Your Safari Reading List is empty.",
        "items": items,
    }))


if __name__ == "__main__":
    main()
