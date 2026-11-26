#!/usr/bin/env python3
import json
import sys


def main():
    try:
        ctx = json.loads(sys.stdin.read().strip() or "{}")
    except Exception:
        ctx = {}
    url = (ctx.get("frontmost") or {}).get("url") or ""
    path_parts = [p for p in url.replace("https://", "").replace("http://", "").split("/")[1:] if p]
    repo_label = "/".join(path_parts[:2]) if len(path_parts) >= 2 else "GitHub"
    print(json.dumps({
        "notch": {
            "wing_text": repo_label[:12],
            "wing_icon": "chevron.left.forwardslash.chevron.right",
            "wing_color": "#6366F1",
            "title": "GitHub Context Active",
            "subtitle": repo_label
        },
        "suggestions": [
            {"title": "View My Pull Requests", "subtitle": "GitHub", "icon": "arrow.triangle.pull"}
        ]
    }))


if __name__ == "__main__":
    main()
