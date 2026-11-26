#!/usr/bin/env python3
import json
import shutil
import subprocess
import sys


def main():
    _ = sys.stdin.read()
    gh = shutil.which("gh") or "/opt/homebrew/bin/gh"
    count = 0
    subtitle = "All caught up"
    try:
        proc = subprocess.run(
            [gh, "search", "prs", "--author=@me", "--state=open", "--limit", "20", "--json", "number,title"],
            capture_output=True, text=True, timeout=8
        )
        if proc.returncode == 0:
            rows = json.loads(proc.stdout or "[]")
            count = len(rows)
            if rows:
                subtitle = f"Latest: #{rows[0].get('number')} {rows[0].get('title', '')}"[:60]
    except Exception:
        subtitle = "Check gh auth status"

    print(json.dumps({
        "notch": {
            "wing_text": f"{count} PRs",
            "wing_icon": "arrow.triangle.pull",
            "wing_color": "#6366F1",
            "title": f"GitHub · {count} Open PR(s)",
            "subtitle": subtitle
        },
        "appearance": {"tint": "#6366F1", "glow": "soft"}
    }))


if __name__ == "__main__":
    main()
