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
    items = []

    if not flt or flt in ("All", "Tab"):
        for t in sl.list_open_tabs():
            if q and q not in t["title"].lower() and q not in t["url"].lower():
                continue
            w, idx, url = t["window"], t["tab"], t["url"]
            items.append({
                "id": f"tab:{w}:{idx}",
                "title": t["title"],
                "subtitle": sl.domain_of(url) or url,
                "icon": "macwindow.on.rectangle",
                "category": "Tab",
                "accessories": [{"kind": "badge", "text": "Tab", "color": "#10B981"}],
                "detail": {"markdown": f"### {t['title']}\n\n`{url}`", "metadata": [{"label": "Source", "value": f"Window {w} · Tab {idx}"}]},
                "actions": [
                    {"id": "switch", "title": "Switch to Tab", "icon": "macwindow", "shortcut": "↵", "kind": "script", "script": "commands/tab-action.py", "value": f"switch:{w}:{idx}"},
                    *sl.standard_url_actions(url, t["title"])[1:],
                ],
            })

    if not flt or flt in ("All", "Bookmark"):
        bookmarks, _ = sl.list_bookmarks()
        for i, b in enumerate(bookmarks):
            if q and q not in b["title"].lower() and q not in b["url"].lower():
                continue
            url = b["url"]
            items.append({
                "id": f"bm:{i}:{url}",
                "title": b["title"],
                "subtitle": f"{b['folder']} · {sl.domain_of(url) or url}",
                "icon": "book.closed.fill",
                "category": "Bookmark",
                "accessories": [{"kind": "tag", "text": "Bookmark", "color": "#0EA5E9"}],
                "detail": {"markdown": f"### {b['title']}\n\n`{url}`", "metadata": [{"label": "Folder", "value": b["folder"]}]},
                "actions": sl.standard_url_actions(url, b["title"]),
            })
            if len(items) >= 140:
                break

    if not flt or flt in ("All", "Reading List"):
        rl, _ = sl.list_reading_list()
        for i, e in enumerate(rl):
            if q and q not in e["title"].lower() and q not in e["url"].lower():
                continue
            url = e["url"]
            items.append({
                "id": f"rl:{i}:{url}",
                "title": e["title"],
                "subtitle": sl.domain_of(url) or url,
                "icon": "eyeglasses",
                "category": "Reading List",
                "accessories": [{"kind": "tag", "text": "Reading List", "color": "#8B5CF6"}],
                "detail": {"markdown": f"### {e['title']}\n\n`{url}`", "metadata": [{"label": "Source", "value": "Reading List"}]},
                "actions": sl.standard_url_actions(url, e["title"]),
            })

    if not flt or flt in ("All", "History"):
        history, _ = sl.list_history(limit=120)
        for i, h in enumerate(history):
            if q and q not in h["title"].lower() and q not in h["url"].lower():
                continue
            url = h["url"]
            items.append({
                "id": f"hist:{i}:{url}",
                "title": h["title"],
                "subtitle": f"{sl.domain_of(url) or url} · {h['visited']}",
                "icon": "clock.arrow.circlepath",
                "category": "History",
                "accessories": [{"kind": "date", "text": "History", "color": "#6B7280"}],
                "detail": {"markdown": f"### {h['title']}\n\n`{url}`", "metadata": [{"label": "Visited", "value": h["visited"]}]},
                "actions": sl.standard_url_actions(url, h["title"]),
            })

    print(json.dumps({
        "filter_options": ["All", "Tab", "Bookmark", "Reading List", "History"],
        "empty_message": "No matching Safari tabs, bookmarks, Reading List, or history items.",
        "items": items[:250],
    }))


if __name__ == "__main__":
    main()
