#!/usr/bin/env python3
import json
import subprocess
import sys


AS = '''
if application "Spotify" is not running then
    return "IDLE"
end if
tell application "Spotify"
    set st to player state as string
    set tr to name of current track
    set ar to artist of current track
    return st & "|||" & tr & "|||" & ar
end tell
'''


def main():
    _ = sys.stdin.read()
    proc = subprocess.run(["/usr/bin/osascript", "-e", AS], capture_output=True, text=True, timeout=4)
    out = (proc.stdout or "").strip()
    if proc.returncode != 0 or not out or out == "IDLE":
        print(json.dumps({
            "notch": {
                "wing_text": "Spotify Idle",
                "wing_icon": "music.note",
                "wing_color": "#1DB954",
                "title": "Spotify",
                "subtitle": "Press Play in Spotify to show track"
            }
        }))
        return
    parts = out.split("|||")
    state = parts[0] if len(parts) > 0 else ""
    track = parts[1] if len(parts) > 1 else "Spotify"
    artist = parts[2] if len(parts) > 2 else ""
    sym = "♫" if state.lower() == "playing" else "❚❚"
    print(json.dumps({
        "notch": {
            "wing_text": f"{sym} {track[:10]}",
            "wing_icon": "music.note",
            "wing_color": "#1DB954",
            "title": track,
            "subtitle": artist
        },
        "appearance": {"tint": "#1DB954", "glow": "breathe"}
    }))


if __name__ == "__main__":
    main()
