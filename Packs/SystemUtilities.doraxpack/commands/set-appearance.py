#!/usr/bin/env python3
import os
import subprocess
import sys


MODE_MAP = {
    "toggle": 'tell application "System Events" to tell appearance preferences to set dark mode to not dark mode',
    "dark": 'tell application "System Events" to tell appearance preferences to set dark mode to true',
    "light": 'tell application "System Events" to tell appearance preferences to set dark mode to false',
}


def main():
    val = os.environ.get("DORAX_ACTION_VALUE", "toggle").strip()
    script = MODE_MAP.get(val, MODE_MAP["toggle"])
    proc = subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True, text=True, timeout=4)
    if proc.returncode != 0:
        print((proc.stderr or "Appearance change failed").strip()[:200])
        sys.exit(1)
    print(f"Appearance updated: {val}")


if __name__ == "__main__":
    main()
