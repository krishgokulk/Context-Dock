#!/usr/bin/env python3
import glob
import json
import os
import sys


def main():
    _ = sys.stdin.read()
    local_folders = sorted(glob.glob(os.path.expanduser("~/Library/CloudStorage/GoogleDrive-*")))
    items = [
        {
            "id": "new-doc",
            "title": "New Google Doc",
            "subtitle": "Create blank document (docs.new)",
            "icon": "doc.badge.plus",
            "accessories": [{"kind": "tag", "text": "Docs", "color": "#4285F4"}],
            "actions": [{"id": "open", "title": "Open docs.new", "icon": "safari", "shortcut": "↵", "kind": "open", "value": "https://docs.new"}]
        },
        {
            "id": "new-sheet",
            "title": "New Google Sheet",
            "subtitle": "Create blank spreadsheet (sheets.new)",
            "icon": "tablecells.badge.ellipsis",
            "accessories": [{"kind": "tag", "text": "Sheets", "color": "#34A853"}],
            "actions": [{"id": "open", "title": "Open sheets.new", "icon": "safari", "shortcut": "↵", "kind": "open", "value": "https://sheets.new"}]
        },
        {
            "id": "new-slide",
            "title": "New Google Slide",
            "subtitle": "Create blank presentation (slides.new)",
            "icon": "rectangle.stack.badge.plus",
            "accessories": [{"kind": "tag", "text": "Slides", "color": "#FBBC05"}],
            "actions": [{"id": "open", "title": "Open slides.new", "icon": "safari", "shortcut": "↵", "kind": "open", "value": "https://slides.new"}]
        },
        {
            "id": "drive-web",
            "title": "Open Google Drive Web",
            "subtitle": "drive.google.com",
            "icon": "globe",
            "accessories": [{"kind": "tag", "text": "Web", "color": "#4285F4"}],
            "actions": [{"id": "open", "title": "Open Drive Web", "icon": "safari", "shortcut": "↵", "kind": "open", "value": "https://drive.google.com/"}]
        },
    ]
    if local_folders:
        items.append({
            "id": "local-folder",
            "title": "Reveal Synced Drive Folder",
            "subtitle": os.path.basename(local_folders[0]),
            "icon": "folder.fill",
            "accessories": [{"kind": "tag", "text": "Finder", "color": "#94A3B8"}],
            "actions": [{"id": "reveal", "title": "Reveal in Finder", "icon": "folder", "shortcut": "↵", "kind": "reveal", "value": local_folders[0]}]
        })
    print(json.dumps({"items": items}))


if __name__ == "__main__":
    main()
