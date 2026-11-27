#!/usr/bin/env python3
from __future__ import annotations

import os
import subprocess
import sys


def main() -> None:
    val = (os.environ.get("DORAX_ACTION_VALUE") or "").strip()
    if val.startswith("switch:"):
        _, w, t = val.split(":", 2)
        script = f'tell application "Safari"\nactivate\nset current tab of window {int(w)} to tab {int(t)} of window {int(w)}\nset index of window {int(w)} to 1\nend tell'
        subprocess.run(["osascript", "-e", script], check=True)
        print(f"Switched to Safari tab {w}:{t}")
    elif val.startswith("close:"):
        _, w, t = val.split(":", 2)
        script = f'tell application "Safari" to close tab {int(t)} of window {int(w)}'
        subprocess.run(["osascript", "-e", script], check=True)
        print(f"Closed Safari tab {w}:{t}")
    elif val.startswith("open:"):
        url = val[len("open:"):]
        subprocess.run(["open", "-a", "Safari", url], check=True)
        print(f"Opened in Safari")
    elif val.startswith("reading-list:"):
        url = val[len("reading-list:"):]
        script = (
            "on run argv\n"
            'tell application "Safari" to add reading list item (item 1 of argv)\n'
            "end run\n"
        )
        subprocess.run(["osascript", "-", url], input=script, text=True, check=True)
        print("Added to Safari Reading List")
    else:
        print(f"Unsupported action value: {val}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
