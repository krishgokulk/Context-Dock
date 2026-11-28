#!/usr/bin/env python3
from __future__ import annotations

import datetime
import json
import os
import subprocess
import sys

IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".webp", ".heic", ".tiff", ".tif", ".gif"}
MAX_ITEMS = 80


def read_context() -> dict:
    raw = sys.stdin.read()
    try:
        return json.loads(raw) if raw.strip() else {}
    except Exception:
        return {}


def defaults_read(domain: str, key: str) -> str | None:
    try:
        proc = subprocess.run(
            ["/usr/bin/defaults", "read", domain, key],
            capture_output=True,
            text=True,
            timeout=1.5,
        )
        if proc.returncode == 0:
            val = proc.stdout.strip()
            if val:
                return os.path.expanduser(val)
    except Exception:
        pass
    return None


def resolve_folder(ctx: dict) -> str:
    prefs = ctx.get("preferences") or {}
    pref_dir = str(prefs.get("screenshots_folder") or "").strip()
    if pref_dir:
        expanded = os.path.expanduser(pref_dir)
        if os.path.isdir(expanded):
            return expanded

    candidates = [
        defaults_read("com.krishgokul.ContextDock", "captureSaveFolderPath"),
        defaults_read("com.apple.screencapture", "location"),
        os.path.expanduser("~/Pictures/Screenshot"),
        os.path.expanduser("~/Pictures/Screenshots"),
        os.path.expanduser("~/Desktop"),
    ]
    for path in candidates:
        if path and os.path.isdir(path):
            return path
    return os.path.expanduser("~/Desktop")


def format_bytes(size: int) -> str:
    if size >= 1024 * 1024:
        return f"{size / (1024 * 1024):.1f} MB"
    if size >= 1024:
        return f"{size / 1024:.0f} KB"
    return f"{size} B"


def format_time(mtime: float, now_dt: datetime.datetime) -> str:
    dt = datetime.datetime.fromtimestamp(mtime)
    if dt.date() == now_dt.date():
        return f"Today · {dt.strftime('%H:%M')}"
    if dt.date() == (now_dt - datetime.timedelta(days=1)).date():
        return f"Yesterday · {dt.strftime('%H:%M')}"
    return dt.strftime("%b %d · %H:%M")


def main() -> None:
    ctx = read_context()
    query = (os.environ.get("DORAX_QUERY") or ctx.get("query") or "").strip().lower()
    active_filter = (os.environ.get("DORAX_FILTER") or ctx.get("filter") or "All").strip()

    folder = resolve_folder(ctx)
    now_dt = datetime.datetime.now()
    today_start = now_dt.replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
    week_start = (now_dt - datetime.timedelta(days=7)).timestamp()

    records: list[tuple[float, int, str, str]] = []
    try:
        with os.scandir(folder) as it:
            for entry in it:
                name = entry.name
                if name.startswith("."):
                    continue
                ext = os.path.splitext(name)[1].lower()
                if ext not in IMAGE_EXTS:
                    continue
                try:
                    if not entry.is_file(follow_symlinks=True):
                        continue
                    st = entry.stat(follow_symlinks=True)
                except OSError:
                    continue

                if active_filter == "Today" and st.st_mtime < today_start:
                    continue
                if active_filter == "This Week" and st.st_mtime < week_start:
                    continue
                if active_filter == "PNG" and ext != ".png":
                    continue
                if active_filter == "JPEG" and ext not in {".jpg", ".jpeg"}:
                    continue

                if query and query not in name.lower():
                    continue

                records.append((st.st_mtime, st.st_size, name, entry.path))
    except OSError:
        records = []

    records.sort(key=lambda r: r[0], reverse=True)
    records = records[:MAX_ITEMS]

    short_folder = folder.replace(os.path.expanduser("~"), "~")
    items = []
    for mtime, size, name, path in records:
        size_str = format_bytes(size)
        time_str = format_time(mtime, now_dt)
        ext_upper = os.path.splitext(name)[1].lstrip(".").upper() or "IMG"
        dt_full = datetime.datetime.fromtimestamp(mtime).strftime("%Y-%m-%d %H:%M:%S")

        actions = [
            {
                "id": "open-screenshot",
                "title": "Open in Preview",
                "icon": "arrow.up.forward.app",
                "shortcut": "↵",
                "kind": "open",
                "value": path,
            },
            {
                "id": "copy-image",
                "title": "Copy Image",
                "icon": "photo.on.rectangle",
                "shortcut": "⌘C",
                "kind": "copy_image",
                "value": path,
            },
            {
                "id": "ocr-screenshot",
                "title": "Extract Text (OCR)",
                "icon": "text.viewfinder",
                "shortcut": "⌘T",
                "kind": "ocr",
                "value": path,
            },
            {
                "id": "reveal-screenshot",
                "title": "Reveal in Finder",
                "icon": "folder",
                "shortcut": "⌘R",
                "kind": "reveal",
                "value": path,
            },
            {
                "id": "copy-path",
                "title": "Copy Path",
                "icon": "doc.on.doc",
                "kind": "copy",
                "value": path,
            },
            {
                "id": "pick-folder",
                "title": "Change Screenshots Folder…",
                "icon": "folder.badge.gearshape",
                "shortcut": "⌘O",
                "kind": "pick_folder",
                "value": "screenshots_folder",
            },
            {
                "id": "trash-screenshot",
                "title": "Move to Trash",
                "icon": "trash",
                "kind": "script",
                "script": "commands/trash-screenshot.py",
                "destructive": True,
                "confirm_message": f"Move {name} to the Trash?",
                "payload": {"path": path},
            },
        ]

        items.append({
            "id": path,
            "title": name,
            "subtitle": f"{time_str} · {size_str}",
            "thumbnail_path": path,
            "category": ext_upper,
            "accessories": [{"kind": "tag", "text": ext_upper, "color": "#0EA5E9"}],
            "detail": {
                "image_path": path,
                "markdown": f"### {name}\n\nSaved in `{short_folder}`",
                "metadata": [
                    {"label": "Modified", "value": dt_full},
                    {"label": "Size", "value": size_str},
                    {"label": "Format", "value": ext_upper},
                    {"label": "Folder", "value": short_folder},
                ],
            },
            "actions": actions,
        })

    if not items and not query:
        items.append({
            "id": "no-screenshots-help",
            "title": f"No screenshots in {short_folder}",
            "subtitle": "Press ↵ to choose your Screenshots folder, or capture a new screenshot",
            "icon": "folder.badge.gearshape",
            "actions": [
                {
                    "id": "pick-folder-empty",
                    "title": "Choose Screenshots Folder…",
                    "icon": "folder.badge.gearshape",
                    "shortcut": "↵",
                    "kind": "pick_folder",
                    "value": "screenshots_folder",
                },
                {
                    "id": "capture-area-empty",
                    "title": "Capture Area Now",
                    "icon": "viewfinder",
                    "kind": "script",
                    "script": "commands/capture-screenshot.py",
                    "payload": {"mode": "capture-area"},
                },
            ],
        })

    out = {
        "filter_options": ["All", "Today", "This Week", "PNG", "JPEG"],
        "empty_message": f"No matching screenshots in {short_folder}.",
        "items": items,
    }
    print(json.dumps(out))


if __name__ == "__main__":
    main()
