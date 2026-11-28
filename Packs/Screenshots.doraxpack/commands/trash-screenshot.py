#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import subprocess
import sys


def main() -> None:
    raw = sys.stdin.read()
    try:
        ctx = json.loads(raw) if raw.strip() else {}
    except Exception:
        ctx = {}

    action = ctx.get("action") or {}
    path = str(action.get("path") or os.environ.get("DORAX_ACTION_VALUE") or "").strip()
    if path:
        path = os.path.expanduser(path)

    if not path or not os.path.exists(path):
        print(json.dumps({"toast": "Screenshot file not found"}))
        return

    escaped = path.replace("\\", "\\\\").replace('"', '\\"')
    proc = subprocess.run(
        ["/usr/bin/osascript", "-e", f'tell application "Finder" to delete POSIX file "{escaped}"'],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        print(json.dumps({"toast": f"Failed to trash: {proc.stderr.strip()}"}))
        return

    print(json.dumps({"toast": f"Moved {os.path.basename(path)} to Trash"}))


if __name__ == "__main__":
    main()
