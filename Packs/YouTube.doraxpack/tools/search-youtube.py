#!/usr/bin/env python3
import json
import os
import shutil
import subprocess
import sys


def main():
    try:
        ctx = json.loads(sys.stdin.read().strip() or "{}")
    except Exception:
        ctx = {}
    query = (ctx.get("query") or os.environ.get("DORAX_QUERY") or "").strip()
    if not query:
        print("Pass a YouTube search query, e.g. @youtube.search-youtube swift concurrency")
        return
    yt_dlp = shutil.which("yt-dlp") or "/opt/homebrew/bin/yt-dlp"
    proc = subprocess.run(
        [yt_dlp, "--flat-playlist", "--dump-json", "--no-warnings", f"ytsearch5:{query}"],
        capture_output=True, text=True, timeout=9
    )
    rows = []
    for line in proc.stdout.splitlines():
        try:
            e = json.loads(line)
        except Exception:
            continue
        vid = e.get("id") or ""
        title = e.get("title") or "Untitled"
        ch = e.get("channel") or e.get("uploader") or "YouTube"
        url = e.get("webpage_url") or (f"https://www.youtube.com/watch?v={vid}" if vid else "")
        rows.append(f"- {title} ({ch}) — {url}")
    print("\n".join(rows) if rows else f"No YouTube results for {query}")


if __name__ == "__main__":
    main()
