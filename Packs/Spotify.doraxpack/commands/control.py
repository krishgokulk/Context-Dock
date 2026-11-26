#!/usr/bin/env python3
import os
import subprocess
import sys


SCRIPTS = {
    "playpause": 'tell application "Spotify" to playpause',
    "next": 'tell application "Spotify" to next track',
    "previous": 'tell application "Spotify" to previous track',
    "volup": 'tell application "Spotify" to set sound volume to (min of {100, (sound volume + 15)})',
    "voldown": 'tell application "Spotify" to set sound volume to (max of {0, (sound volume - 15)})',
}


def main():
    action = os.environ.get("DORAX_ACTION_VALUE", "").strip()
    if action == "open":
        subprocess.run(["/usr/bin/open", "-a", "Spotify"], check=False, timeout=4)
        print("Opened Spotify")
        return
    stmt = SCRIPTS.get(action)
    if not stmt:
        print(f"Unknown control: {action}")
        sys.exit(1)
    proc = subprocess.run(["/usr/bin/osascript", "-e", stmt], capture_output=True, text=True, timeout=4)
    if proc.returncode != 0:
        print((proc.stderr or "Spotify AppleScript error").strip()[:200])
        sys.exit(1)
    print(f"Spotify: {action}")


if __name__ == "__main__":
    main()
