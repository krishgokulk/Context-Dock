#!/usr/bin/env python3
import json
import sys


def main():
    try:
        ctx = json.loads(sys.stdin.read().strip() or "{}")
    except Exception:
        ctx = {}
    front = ctx.get("frontmost") or {}
    domain = (front.get("domain") or "youtube.com").strip()
    wing = "YT Music" if "music.youtube" in domain else "YouTube"
    print(json.dumps({
        "notch": {
            "wing_text": wing,
            "wing_icon": "play.rectangle.fill",
            "wing_color": "#FF0033",
            "title": "YouTube Quick Actions",
            "subtitle": f"Active on {domain}"
        },
        "suggestions": [
            {"title": "Play in IINA / Download", "subtitle": domain, "icon": "play.circle.fill"}
        ]
    }))


if __name__ == "__main__":
    main()
