#!/usr/bin/env python3
import json
import sys


def main():
    _ = sys.stdin.read()
    controls = [
        ("playpause", "Play / Pause", "Toggle Spotify playback", "playpause.fill", "Play/Pause", "#1DB954"),
        ("next", "Next Track", "Skip to next song", "forward.fill", "Skip", "#1DB954"),
        ("previous", "Previous Track", "Return to previous song", "backward.fill", "Back", "#1DB954"),
        ("volup", "Volume +15%", "Raise Spotify volume", "speaker.wave.3.fill", "+15%", "#38BDF8"),
        ("voldown", "Volume -15%", "Lower Spotify volume", "speaker.wave.1.fill", "-15%", "#38BDF8"),
        ("open", "Open Spotify", "Bring Spotify window forward", "music.note", "App", "#94A3B8"),
    ]
    items = []
    for key, title, sub, icon, tag, color in controls:
        items.append({
            "id": key,
            "title": title,
            "subtitle": sub,
            "icon": icon,
            "accessories": [{"kind": "tag", "text": tag, "color": color}],
            "actions": [
                {"id": f"run-{key}", "title": title, "icon": icon, "shortcut": "↵", "kind": "script", "script": "commands/control.py", "value": key}
            ]
        })
    print(json.dumps({"items": items}))


if __name__ == "__main__":
    main()
