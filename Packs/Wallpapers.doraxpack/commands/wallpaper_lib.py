#!/usr/bin/env python3
"""Shared helpers for Packs/Wallpapers.doraxpack commands."""

from __future__ import annotations

import json
import os
import random
import subprocess
import sys

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".heic", ".webp", ".tiff", ".bmp"}
COLLECTION_DIR = os.path.expanduser("~/Library/Application Support/Context-Dock/wallpapers/collection")
STATE_PATH = os.path.expanduser("~/Library/Application Support/Context-Dock/wallpapers/state.json")
SYSTEM_WALLPAPER_DIR = "/System/Library/Desktop Pictures"


def read_context() -> dict:
    try:
        raw = sys.stdin.read().strip()
        return json.loads(raw) if raw else {}
    except Exception:
        return {}


def get_current_wallpaper() -> str:
    try:
        res = subprocess.run(
            ["osascript", "-e", 'tell application "System Events" to get picture of desktop 1'],
            capture_output=True, text=True, timeout=4,
        )
        if res.returncode == 0:
            val = res.stdout.strip()
            if val and val != "missing value" and os.path.exists(val):
                return val
    except Exception:
        pass
    last = load_state().get("last_path", "")
    if last and os.path.exists(last):
        return last
    return ""


def _recent_macos_wallpaper_folders() -> list[str]:
    """Reads recent user-chosen image folders/files from macOS wallpaper store as zero-config fallback."""
    store = os.path.expanduser("~/Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    if not os.path.isfile(store):
        return []
    try:
        import plistlib
        import urllib.parse

        with open(store, "rb") as f:
            root = plistlib.load(f)
        candidates: list[tuple[str, str]] = []

        def inspect_node(desktop_dict: dict) -> None:
            if not isinstance(desktop_dict, dict):
                return
            ls = str(desktop_dict.get("LastSet") or "")
            choices = ((desktop_dict.get("Content") or {}).get("Choices") or [])
            for ch in choices:
                cfg = ch.get("Configuration") if isinstance(ch, dict) else None
                if not (isinstance(cfg, bytes) and cfg.startswith(b"bplist")):
                    continue
                try:
                    parsed = plistlib.loads(cfg)
                    rel = ((parsed.get("url") or {}).get("relative")) if isinstance(parsed, dict) else None
                    if isinstance(rel, str) and rel.startswith("file://"):
                        path = urllib.parse.unquote(rel[len("file://"):])
                        candidates.append((ls, path))
                except Exception:
                    continue

        for d in (root.get("Displays") or {}).values():
            if isinstance(d, dict):
                inspect_node(d.get("Desktop") or {})
        for sp in (root.get("Spaces") or {}).values():
            if isinstance(sp, dict):
                inspect_node(((sp.get("Default") or {}).get("Desktop")) or {})

        candidates.sort(key=lambda x: x[0], reverse=True)
        folders: list[str] = []
        seen: set[str] = set()
        for _, p in candidates:
            if p.startswith("/System/") or "/Safari Shared Data/" in p:
                continue
            folder = p.rstrip("/") if os.path.isdir(p) else os.path.dirname(p)
            if folder and os.path.isdir(folder) and folder not in seen:
                seen.add(folder)
                folders.append(folder)
        return folders
    except Exception:
        return []


def load_state() -> dict:
    try:
        with open(STATE_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def save_state(path: str) -> None:
    try:
        os.makedirs(os.path.dirname(STATE_PATH), exist_ok=True)
        with open(STATE_PATH, "w", encoding="utf-8") as f:
            json.dump({"last_path": path}, f)
    except Exception:
        pass


def _images_in_dir(directory: str) -> list[str]:
    if not directory or not os.path.isdir(directory):
        return []
    found = []
    try:
        for name in os.listdir(directory):
            if name.startswith("."):
                continue
            ext = os.path.splitext(name)[1].lower()
            if ext not in IMAGE_EXTS:
                continue
            full = os.path.join(directory, name)
            if os.path.isfile(full):
                found.append(full)
    except Exception:
        return []
    found.sort(key=lambda p: os.path.basename(p).lower())
    return found


def resolve_folder_and_entries(ctx: dict) -> tuple[str | None, list[dict]]:
    """
    Returns `(active_folder, entries)` where each entry is:
      {"path": str, "name": str, "source": "Folder" | "Added Pictures", "folder": str}
    """
    prefs = ctx.get("preferences") or {}
    pref_folder = os.path.expanduser((prefs.get("folder") or "").strip())

    active_folder: str | None = None
    folder_images: list[str] = []

    if pref_folder and os.path.isdir(pref_folder):
        active_folder = pref_folder
        folder_images = _images_in_dir(pref_folder)
    else:
        cur = get_current_wallpaper()
        cur_dir = os.path.dirname(cur) if cur else ""
        if cur_dir and os.path.isdir(cur_dir) and os.path.realpath(cur_dir) != os.path.realpath(COLLECTION_DIR):
            imgs = _images_in_dir(cur_dir)
            if imgs:
                active_folder = cur_dir
                folder_images = imgs

        if not folder_images:
            for candidate_dir in [
                *_recent_macos_wallpaper_folders(),
                os.path.expanduser("~/Pictures/Wallpapers"),
            ]:
                if os.path.realpath(candidate_dir) == os.path.realpath(COLLECTION_DIR):
                    continue
                imgs = _images_in_dir(candidate_dir)
                if imgs:
                    active_folder = candidate_dir
                    folder_images = imgs
                    break

    added_images = _images_in_dir(COLLECTION_DIR)

    if not folder_images and not added_images and os.path.isdir(SYSTEM_WALLPAPER_DIR):
        sys_imgs = _images_in_dir(SYSTEM_WALLPAPER_DIR)
        if sys_imgs:
            active_folder = SYSTEM_WALLPAPER_DIR
            folder_images = sys_imgs

    entries: list[dict] = []
    seen_real: set[str] = set()

    for p in folder_images:
        rp = os.path.realpath(p)
        if rp in seen_real:
            continue
        seen_real.add(rp)
        entries.append({
            "path": p,
            "name": os.path.basename(p),
            "source": "Folder",
            "folder": os.path.dirname(p),
        })

    for p in added_images:
        rp = os.path.realpath(p)
        if rp in seen_real:
            continue
        seen_real.add(rp)
        entries.append({
            "path": p,
            "name": os.path.basename(p),
            "source": "Added Pictures",
            "folder": COLLECTION_DIR,
        })

    return active_folder, entries


def apply_wallpaper(path: str, scope: str = "all") -> None:
    if not path or not os.path.isfile(path):
        raise RuntimeError(f"Wallpaper file not found: {path}")
    if scope == "current":
        script = (
            "on run argv\n"
            'tell application "System Events" to set picture of desktop 1 to (item 1 of argv)\n'
            "end run\n"
        )
    else:
        script = (
            "on run argv\n"
            'tell application "System Events" to tell every desktop to set picture to (item 1 of argv)\n'
            "end run\n"
        )
    res = subprocess.run(["osascript", "-", path], input=script, text=True, capture_output=True, timeout=8)
    if res.returncode != 0:
        err = (res.stderr or res.stdout or "Failed to set wallpaper").strip()
        raise RuntimeError(err)
    save_state(path)


def image_dimensions(path: str) -> str:
    try:
        res = subprocess.run(
            ["sips", "-g", "pixelWidth", "-g", "pixelHeight", path],
            capture_output=True, text=True, timeout=3,
        )
        if res.returncode != 0:
            return ""
        w = h = ""
        for line in res.stdout.splitlines():
            if "pixelWidth:" in line:
                w = line.split(":", 1)[1].strip()
            elif "pixelHeight:" in line:
                h = line.split(":", 1)[1].strip()
        if w and h:
            return f"{w} × {h}"
    except Exception:
        pass
    return ""


def pick_next_index(entries: list[dict], current_path: str, random_mode: bool = False) -> int:
    if not entries:
        return -1
    cur_real = os.path.realpath(current_path) if current_path else ""
    cur_idx = next((i for i, e in enumerate(entries) if os.path.realpath(e["path"]) == cur_real), -1)
    if cur_idx < 0:
        last_real = os.path.realpath(load_state().get("last_path", "")) if load_state().get("last_path") else ""
        cur_idx = next((i for i, e in enumerate(entries) if os.path.realpath(e["path"]) == last_real), -1)

    if random_mode and len(entries) > 1:
        candidates = [i for i in range(len(entries)) if i != cur_idx]
        return random.choice(candidates)
    if cur_idx < 0:
        return 0
    return (cur_idx + 1) % len(entries)


def picker_actions(current_path: str | None = None, can_remove: bool = False) -> list[dict]:
    acts = [
        {
            "id": "choose-folder",
            "title": "Choose Wallpaper Folder…",
            "icon": "folder.badge.plus",
            "shortcut": "⌘O",
            "kind": "pick_folder",
            "value": "folder",
        },
        {
            "id": "add-pictures",
            "title": "Add Pictures…",
            "icon": "photo.badge.plus",
            "shortcut": "⌘I",
            "kind": "pick_files",
            "value": "~/Library/Application Support/Context-Dock/wallpapers/collection",
        },
    ]
    if current_path:
        acts.append({
            "id": "reveal",
            "title": "Reveal in Finder",
            "icon": "finder",
            "shortcut": "⌘⇧R",
            "kind": "reveal",
            "value": current_path,
        })
    if can_remove and current_path:
        acts.append({
            "id": "remove-added",
            "title": "Remove Added Picture",
            "icon": "trash",
            "kind": "script",
            "script": "commands/remove-picture.py",
            "value": current_path,
            "destructive": True,
            "confirm_message": f"Remove {os.path.basename(current_path)} from your Added Pictures collection? Your external folders are never touched.",
        })
    return acts
