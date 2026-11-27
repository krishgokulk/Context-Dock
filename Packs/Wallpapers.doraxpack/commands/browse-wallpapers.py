#!/usr/bin/env python3
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wallpaper_lib as wl


def main() -> None:
    ctx = wl.read_context()
    query = (os.environ.get("DORAX_QUERY") or ctx.get("query") or "").strip().lower()
    active_filter = (os.environ.get("DORAX_FILTER") or ctx.get("filter") or "").strip()

    active_folder, entries = wl.resolve_folder_and_entries(ctx)
    current_path = wl.get_current_wallpaper()
    cur_real = os.path.realpath(current_path) if current_path else ""

    items = []
    for entry in entries:
        if query and query not in entry["name"].lower() and query not in entry["source"].lower():
            continue
        if active_filter and active_filter != "All" and entry["source"] != active_filter:
            continue
        path = entry["path"]
        is_active = bool(cur_real) and os.path.realpath(path) == cur_real
        short_folder = entry["folder"].replace(os.path.expanduser("~"), "~")
        accessories = []
        if is_active:
            accessories.append({"kind": "badge", "text": "Active", "color": "#10B981"})
        elif entry["source"] == "Added Pictures":
            accessories.append({"kind": "tag", "text": "Added", "color": "#06B6D4"})

        actions = [
            {
                "id": "set-wallpaper",
                "title": "Set as Wallpaper",
                "icon": "checkmark.circle",
                "shortcut": "↵",
                "kind": "script",
                "script": "commands/set-wallpaper.py",
                "value": path,
            },
            {
                "id": "next-wallpaper",
                "title": "Next Wallpaper",
                "icon": "photo.on.rectangle.angled",
                "shortcut": "⌘N",
                "kind": "script",
                "script": "commands/set-wallpaper.py",
                "value": "__next__",
            },
            {
                "id": "random-wallpaper",
                "title": "Random Wallpaper",
                "icon": "shuffle",
                "shortcut": "⌘S",
                "kind": "script",
                "script": "commands/set-wallpaper.py",
                "value": "__random__",
            },
            *wl.picker_actions(
                current_path=path,
                can_remove=(entry["source"] == "Added Pictures"),
            ),
        ]

        items.append({
            "id": path,
            "title": entry["name"],
            "subtitle": short_folder,
            "thumbnail_path": path,
            "category": entry["source"],
            "accessories": accessories,
            "actions": actions,
        })

    if not entries:
        empty_msg = "No wallpapers found. Press ⌘O to choose a folder or ⌘I to add pictures."
    else:
        empty_msg = "No matching wallpapers."

    out = {
        "filter_options": ["All", "Folder", "Added Pictures"],
        "empty_message": empty_msg,
        "items": items,
    }
    print(json.dumps(out))


if __name__ == "__main__":
    main()
