#!/usr/bin/env python3
from __future__ import annotations

import datetime
import json
import os
import subprocess
import sys


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


def main() -> None:
    ctx = read_context()
    action = ctx.get("action") or {}
    cmd_id = str(
        action.get("mode")
        or ctx.get("commandId")
        or ctx.get("command_id")
        or "capture-area"
    ).strip().lower()

    folder = resolve_folder(ctx)
    os.makedirs(folder, exist_ok=True)

    if cmd_id == "open-screenshots-folder":
        subprocess.run(["/usr/bin/open", folder], check=False)
        short_folder = folder.replace(os.path.expanduser("~"), "~")
        print(json.dumps({
            "toast": "Opened Screenshots Folder",
            "notch": {
                "wing_text": "Screenshots",
                "wing_icon": "folder.fill",
                "wing_color": "#0EA5E9",
                "title": "Opened Screenshots Folder",
                "subtitle": short_folder,
            },
            "appearance": {"tint": "#0EA5E9", "glow": "pulse"},
        }))
        return

    if cmd_id == "capture-clipboard":
        proc = subprocess.run(["/usr/sbin/screencapture", "-i", "-c"], capture_output=True, text=True)
        if proc.returncode != 0:
            print(json.dumps({"toast": "Screenshot cancelled"}))
            return
        print(json.dumps({
            "toast": "Screenshot Copied to Clipboard",
            "notch": {
                "wing_text": "Copied",
                "wing_icon": "camera.viewfinder",
                "wing_color": "#0EA5E9",
                "title": "Screenshot Copied",
                "subtitle": "Ready to paste from clipboard",
            },
            "appearance": {"tint": "#0EA5E9", "glow": "pulse"},
        }))
        return

    stamp = datetime.datetime.now().strftime("%Y-%m-%d at %H.%M.%S")
    out_path = os.path.join(folder, f"Screenshot {stamp}.png")
    args = ["/usr/sbin/screencapture"]
    if cmd_id == "capture-window":
        args += ["-i", "-W", out_path]
        label = "Window Captured"
    elif cmd_id == "capture-screen":
        args += ["-x", out_path]
        label = "Screen Captured"
    else:
        args += ["-i", out_path]
        label = "Area Captured"

    proc = subprocess.run(args, capture_output=True, text=True)
    if proc.returncode != 0 or not os.path.isfile(out_path):
        print(json.dumps({"toast": "Screenshot cancelled"}))
        return

    print(json.dumps({
        "toast": label,
        "notch": {
            "wing_text": "Captured",
            "wing_icon": "camera.viewfinder",
            "wing_color": "#0EA5E9",
            "title": label,
            "subtitle": os.path.basename(out_path),
        },
        "appearance": {"tint": "#0EA5E9", "glow": "pulse"},
    }))


if __name__ == "__main__":
    main()
