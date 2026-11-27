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
    tabs = sl.list_open_tabs()

    items = []
    for t in tabs:
        scope_cat = "Current Window" if t["is_current_window"] else "Other Windows"
        if flt and flt != "All" and scope_cat != flt:
            continue
        if q and q not in t["title"].lower() and q not in t["url"].lower():
            continue
        w, idx, url = t["window"], t["tab"], t["url"]
        acc = [{"kind": "tag", "text": f"W{w}·T{idx}", "color": "#0EA5E9"}]
        if t["is_active"]:
            acc.insert(0, {"kind": "badge", "text": "Active", "color": "#10B981"})

        actions = [
            {
                "id": "switch-tab",
                "title": "Switch to Tab",
                "icon": "macwindow",
                "shortcut": "↵",
                "kind": "script",
                "script": "commands/tab-action.py",
                "value": f"switch:{w}:{idx}",
            },
            *sl.standard_url_actions(url, t["title"])[1:],
            {
                "id": "close-tab",
                "title": "Close Tab",
                "icon": "xmark.circle",
                "shortcut": "⌘⌫",
                "kind": "script",
                "script": "commands/tab-action.py",
                "value": f"close:{w}:{idx}",
                "destructive": True,
                "confirm_message": f"Close tab \"{t['title']}\"?",
            },
        ]
        items.append({
            "id": f"tab:{w}:{idx}",
            "title": t["title"],
            "subtitle": sl.domain_of(url) or url,
            "icon": "safari.fill",
            "category": scope_cat,
            "accessories": acc,
            "detail": {
                "markdown": f"### {t['title']}\n\n`{url}`",
                "metadata": [
                    {"label": "Window", "value": str(w)},
                    {"label": "Tab", "value": str(idx)},
                    {"label": "Domain", "value": sl.domain_of(url) or "Local"},
                ],
            },
            "actions": actions,
        })

    print(json.dumps({
        "filter_options": ["All", "Current Window", "Other Windows"],
        "empty_message": "No open Safari tabs found (open Safari or clear your filter).",
        "items": items,
    }))


if __name__ == "__main__":
    main()
