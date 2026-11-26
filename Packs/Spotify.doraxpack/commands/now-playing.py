#!/usr/bin/env python3
import json
import subprocess
import sys


AS = '''
if application "Spotify" is not running then
    return "NOT_RUNNING"
end if
tell application "Spotify"
    set st to player state as string
    set tr to name of current track
    set ar to artist of current track
    set al to album of current track
    set sid to id of current track
    set dur to duration of current track
    set pos to player position
    return st & "|||" & tr & "|||" & ar & "|||" & al & "|||" & sid & "|||" & (dur as string) & "|||" & (pos as string)
end tell
'''


def main():
    _ = sys.stdin.read()
    try:
        proc = subprocess.run(["/usr/bin/osascript", "-e", AS], capture_output=True, text=True, timeout=4)
    except Exception as exc:
        print(json.dumps({"detail": {"markdown": f"### Spotify Error\n`{exc}`"}}))
        return

    out = (proc.stdout or "").strip()
    if proc.returncode != 0 or not out or out == "NOT_RUNNING":
        print(json.dumps({
            "items": [{
                "id": "open-spotify",
                "title": "Open Spotify",
                "subtitle": "Spotify is not running — press ↵ to launch",
                "icon": "music.note",
                "app_icon_bundle_id": "com.spotify.client",
                "actions": [
                    {"id": "launch", "title": "Launch Spotify", "icon": "play.circle.fill", "shortcut": "↵", "kind": "cli", "binary": "/usr/bin/open", "args": ["-a", "Spotify"]}
                ]
            }]
        }))
        return

    parts = out.split("|||")
    state = parts[0] if len(parts) > 0 else "stopped"
    track = parts[1] if len(parts) > 1 else "Unknown Track"
    artist = parts[2] if len(parts) > 2 else "Unknown Artist"
    album = parts[3] if len(parts) > 3 else ""
    sid = parts[4] if len(parts) > 4 else ""
    try:
        dur_sec = max(1.0, float(parts[5]) / 1000.0)
        pos_sec = max(0.0, float(parts[6]))
        progress = min(1.0, pos_sec / dur_sec)
    except Exception:
        progress = 0.0

    playing = state.lower() == "playing"
    badge = "Playing" if playing else state.title()
    color = "#1DB954" if playing else "#FBBF24"

    item = {
        "id": sid or track,
        "title": track,
        "subtitle": f"{artist}" + (f" · {album}" if album else ""),
        "icon": "play.circle.fill" if playing else "pause.circle.fill",
        "app_icon_bundle_id": "com.spotify.client",
        "accessories": [
            {"kind": "tag", "text": badge, "color": color},
            {"kind": "progress", "progress": progress}
        ],
        "detail": {
            "markdown": f"### {track}\n\n**Artist:** {artist}\n\n**Album:** {album}\n\n**State:** {badge}",
            "metadata": [
                {"label": "State", "value": badge, "color": color},
                {"label": "Artist", "value": artist},
                {"label": "Album", "value": album or "-"},
            ]
        },
        "actions": [
            {"id": "playpause", "title": "Play / Pause", "icon": "playpause.fill", "shortcut": "↵", "kind": "script", "script": "commands/control.py", "value": "playpause"},
            {"id": "next", "title": "Next Track", "icon": "forward.fill", "shortcut": "⌘]", "kind": "script", "script": "commands/control.py", "value": "next"},
            {"id": "prev", "title": "Previous Track", "icon": "backward.fill", "shortcut": "⌘[", "kind": "script", "script": "commands/control.py", "value": "previous"},
            {"id": "copy-track", "title": "Copy Track Title", "icon": "doc.on.doc", "shortcut": "⌘C", "kind": "copy", "value": f"{track} — {artist}"},
            {"id": "copy-uri", "title": "Copy Spotify URI", "icon": "link", "kind": "copy", "value": sid},
        ]
    }
    print(json.dumps({"items": [item]}))


if __name__ == "__main__":
    main()
