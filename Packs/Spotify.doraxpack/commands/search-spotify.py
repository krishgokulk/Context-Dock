#!/usr/bin/env python3
import json
import subprocess
import sys
import urllib.parse


def main():
    try:
        ctx = json.loads(sys.stdin.read().strip() or "{}")
    except Exception:
        ctx = {}
    q = ((ctx.get("formValues") or {}).get("query") or ctx.get("query") or "").strip()
    if not q:
        print(json.dumps({"empty_message": "Enter a song, artist, or playlist name."}))
        return
    uri = "spotify:search:" + urllib.parse.quote(q)
    subprocess.run(["/usr/bin/open", uri], check=False, timeout=4)
    print(json.dumps({
        "detail": {
            "markdown": f"### Opened Spotify Search\n\nQuery: **{q}**\n\nURI: `{uri}`",
            "metadata": [{"label": "App", "value": "Spotify", "color": "#1DB954"}]
        },
        "toast": f"Searching Spotify for {q}"
    }))


if __name__ == "__main__":
    main()
