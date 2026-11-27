#!/usr/bin/env python3
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wallpaper_lib as wl


def main() -> None:
    ctx = wl.read_context()
    prefs = ctx.get("preferences") or {}
    scope = (prefs.get("apply_scope") or "all").strip() or "all"
    cmd_id = os.environ.get("DORAX_COMMAND_ID", "next-wallpaper")
    random_mode = cmd_id == "random-wallpaper" or os.environ.get("DORAX_ACTION_VALUE") == "random"
    dry_run = os.environ.get("DORAX_WALLPAPER_DRY_RUN") == "1"

    active_folder, entries = wl.resolve_folder_and_entries(ctx)
    if not entries:
        out = {
            "empty_message": "No wallpapers found yet. Choose a Wallpaper Folder or Add Pictures via ⌘K or buttons below.",
            "detail": {
                "markdown": (
                    "### No Wallpapers Found\n\n"
                    "Pick a folder containing images or add individual pictures into your collection.\n\n"
                    "- Use **Choose Wallpaper Folder…** (`⌘O`) to link any folder.\n"
                    "- Use **Add Pictures…** (`⌘I`) to add individual `.jpg`, `.png`, or `.heic` images."
                ),
                "metadata": [
                    {"label": "Status", "value": "Empty", "color": "#F59E0B"},
                    {"label": "Collection", "value": "0 images"},
                ],
            },
            "items": [
                {
                    "id": "setup-folder",
                    "title": "Choose Wallpaper Folder…",
                    "subtitle": "Select a folder of wallpapers",
                    "icon": "folder.badge.plus",
                    "actions": wl.picker_actions(),
                }
            ],
        }
        print(json.dumps(out))
        return

    current_path = wl.get_current_wallpaper()
    idx = wl.pick_next_index(entries, current_path, random_mode=random_mode)
    chosen = entries[idx]
    target_path = chosen["path"]

    if not dry_run:
        wl.apply_wallpaper(target_path, scope=scope)

    dims = wl.image_dimensions(target_path)
    folder_label = active_folder or wl.COLLECTION_DIR
    short_folder = folder_label.replace(os.path.expanduser("~"), "~")
    size_mb = os.path.getsize(target_path) / (1024.0 * 1024.0)

    metadata = [
        {"label": "Position", "value": f"{idx + 1} / {len(entries)}", "color": "#06B6D4"},
        {"label": "Source", "value": chosen["source"]},
        {"label": "Scope", "value": "All Desktops" if scope == "all" else "Current Desktop"},
    ]
    if dims:
        metadata.append({"label": "Dimensions", "value": dims})
    metadata.append({"label": "Size", "value": f"{size_mb:.1f} MB"})

    actions = [
        {
            "id": "next",
            "title": "Next Wallpaper" if not random_mode else "Random Wallpaper",
            "icon": "photo.on.rectangle.angled" if not random_mode else "shuffle",
            "shortcut": "↵",
            "kind": "refresh",
        },
        *wl.picker_actions(
            current_path=target_path,
            can_remove=(chosen["source"] == "Added Pictures"),
        ),
    ]

    verb = "Random Wallpaper" if random_mode else "Wallpaper Changed"
    out = {
        "toast": f"{verb}: {chosen['name']} ({idx + 1}/{len(entries)})",
        "detail": {
            "image_path": target_path,
            "markdown": f"### {chosen['name']}\n\nFolder: `{short_folder}`",
            "metadata": metadata,
        },
        "items": [
            {
                "id": target_path,
                "title": chosen["name"],
                "subtitle": short_folder,
                "thumbnail_path": target_path,
                "category": chosen["source"],
                "actions": actions,
            }
        ],
    }
    print(json.dumps(out))


if __name__ == "__main__":
    main()
