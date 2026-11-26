#!/usr/bin/env python3
import json
import subprocess
import sys


def get_audio():
    r = subprocess.run(
        ["/usr/bin/osascript", "-e", "get {output volume of (get volume settings), output muted of (get volume settings)}"],
        capture_output=True, text=True, timeout=4
    )
    parts = [p.strip() for p in r.stdout.split(",")]
    try:
        vol = int(parts[0])
    except Exception:
        vol = 50
    muted = len(parts) > 1 and parts[1].lower() == "true"
    return vol, muted


def main():
    _ = sys.stdin.read()
    vol, muted = get_audio()
    items = [
        {
            "id": "mute-toggle",
            "title": "Unmute Audio" if muted else "Mute Audio",
            "subtitle": f"Current volume: {vol}% ({'Muted' if muted else 'Active'})",
            "icon": "speaker.slash.fill" if muted else "speaker.wave.2.fill",
            "accessories": [{"kind": "tag", "text": "Muted" if muted else f"{vol}%", "color": "#EF4444" if muted else "#34D399"}],
            "actions": [{"id": "mute", "title": "Toggle Mute", "icon": "speaker.slash.fill", "shortcut": "↵", "kind": "script", "script": "commands/set-volume.py", "value": "mute-toggle"}]
        },
    ]
    for pct, label in [(25, "Quiet"), (50, "Medium"), (75, "Loud"), (100, "Max"), ("+15", "Up +15%"), ("-15", "Down -15%")]:
        key = str(pct)
        is_current = (not muted and isinstance(pct, int) and abs(vol - pct) <= 4)
        items.append({
            "id": f"vol-{key}",
            "title": f"Volume {pct}%" if isinstance(pct, int) else f"Volume {pct}",
            "subtitle": f"Preset: {label}",
            "icon": "speaker.wave.3.fill",
            "accessories": [{"kind": "tag", "text": "Current" if is_current else label, "color": "#38BDF8" if is_current else "#94A3B8"}],
            "actions": [{"id": f"set-{key}", "title": f"Set {key}", "icon": "speaker.wave.2.fill", "shortcut": "↵", "kind": "script", "script": "commands/set-volume.py", "value": key}]
        })
    print(json.dumps({"items": items}))


if __name__ == "__main__":
    main()
