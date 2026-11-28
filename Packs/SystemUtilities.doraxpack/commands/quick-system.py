#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
import sys


def run_cmd(cmd: list[str]) -> tuple[int, str, str]:
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()


def main() -> None:
    raw = sys.stdin.read()
    try:
        ctx = json.loads(raw) if raw.strip() else {}
    except Exception:
        ctx = {}

    cmd_id = str(ctx.get("commandId") or ctx.get("command_id") or "").strip().lower()

    if cmd_id == "lock-screen":
        code, _, err = run_cmd(["/usr/bin/pmset", "displaysleepnow"])
        if code != 0:
            print(json.dumps({"empty_message": err or "Could not lock display"}))
            return
        print(json.dumps({
            "toast": "Screen Locked",
            "notch": {
                "wing_text": "Locked",
                "wing_icon": "lock.fill",
                "wing_color": "#38BDF8",
                "title": "Screen Locked",
                "subtitle": "Display put to sleep",
            },
            "appearance": {"tint": "#38BDF8", "glow": "pulse"},
        }))
        return

    if cmd_id == "sleep-mac":
        code, _, err = run_cmd(["/usr/bin/osascript", "-e", 'tell application "System Events" to sleep'])
        if code != 0:
            print(json.dumps({"empty_message": err or "Could not sleep Mac"}))
            return
        print(json.dumps({
            "toast": "Sleeping Mac…",
            "notch": {
                "wing_text": "Sleep",
                "wing_icon": "moon.fill",
                "wing_color": "#F59E0B",
                "title": "Sleeping Mac",
                "subtitle": "Entering sleep mode",
            },
            "appearance": {"tint": "#F59E0B", "glow": "pulse"},
        }))
        return

    if cmd_id == "empty-trash":
        code, _, err = run_cmd(["/usr/bin/osascript", "-e", 'tell application "Finder" to empty trash'])
        if code != 0:
            print(json.dumps({"empty_message": err or "Could not empty Trash"}))
            return
        print(json.dumps({
            "toast": "Trash Emptied",
            "notch": {
                "wing_text": "Trash Emptied",
                "wing_icon": "trash.fill",
                "wing_color": "#34D399",
                "title": "Trash Emptied",
                "subtitle": "All items removed cleanly",
            },
            "appearance": {"tint": "#34D399", "glow": "pulse"},
        }))
        return

    if cmd_id == "restart-mac":
        code, _, err = run_cmd(["/usr/bin/osascript", "-e", 'tell application "System Events" to restart'])
        if code != 0:
            print(json.dumps({"empty_message": err or "Could not restart Mac"}))
            return
        print(json.dumps({
            "toast": "Restarting Mac…",
            "notch": {
                "wing_text": "Restarting",
                "wing_icon": "arrow.clockwise.circle.fill",
                "wing_color": "#EF4444",
                "title": "Restarting Mac",
                "subtitle": "System restart initiated",
            },
            "appearance": {"tint": "#EF4444", "glow": "pulse"},
        }))
        return

    if cmd_id == "shutdown-mac":
        code, _, err = run_cmd(["/usr/bin/osascript", "-e", 'tell application "System Events" to shut down'])
        if code != 0:
            print(json.dumps({"empty_message": err or "Could not shut down Mac"}))
            return
        print(json.dumps({
            "toast": "Shutting Down…",
            "notch": {
                "wing_text": "Shutting Down",
                "wing_icon": "power.circle.fill",
                "wing_color": "#EF4444",
                "title": "Shutting Down Mac",
                "subtitle": "Powering off system",
            },
            "appearance": {"tint": "#EF4444", "glow": "pulse"},
        }))
        return

    if cmd_id == "toggle-dark-mode":
        script = (
            'tell application "System Events"\n'
            '  tell appearance preferences to set dark mode to not dark mode\n'
            '  return dark mode\n'
            'end tell'
        )
        code, out, err = run_cmd(["/usr/bin/osascript", "-e", script])
        if code != 0:
            print(json.dumps({"empty_message": err or "Could not toggle appearance"}))
            return
        is_dark = out.lower() == "true"
        mode_name = "Dark" if is_dark else "Light"
        color = "#6366F1" if is_dark else "#F59E0B"
        print(json.dumps({
            "toast": f"Switched to {mode_name} Mode",
            "notch": {
                "wing_text": f"{mode_name} Mode",
                "wing_icon": "moon.stars.fill" if is_dark else "sun.max.fill",
                "wing_color": color,
                "title": f"{mode_name} Mode Enabled",
                "subtitle": "macOS appearance updated",
            },
            "appearance": {"tint": color, "glow": "pulse"},
        }))
        return

    print(json.dumps({"toast": f"Ran {cmd_id or 'System Action'}"}))


if __name__ == "__main__":
    main()
