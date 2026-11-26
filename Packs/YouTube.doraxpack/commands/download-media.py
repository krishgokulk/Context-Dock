#!/usr/bin/env python3
import os
import shutil
import subprocess
import sys


def main():
    raw = os.environ.get("DORAX_ACTION_VALUE", "").strip()
    if "|" not in raw:
        print("Missing format|url")
        sys.exit(1)
    fmt, url = raw.split("|", 1)
    yt_dlp = shutil.which("yt-dlp") or "/opt/homebrew/bin/yt-dlp"
    downloads = os.path.expanduser("~/Downloads")
    os.makedirs(downloads, exist_ok=True)
    out_tmpl = os.path.join(downloads, "%(title).120s.%(ext)s")
    if fmt == "mp3":
        args = [yt_dlp, "-x", "--audio-format", "mp3", "--no-playlist", "-o", out_tmpl, url]
    else:
        args = [yt_dlp, "-f", "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best", "--no-playlist", "-o", out_tmpl, url]
    proc = subprocess.run(args, capture_output=True, text=True, timeout=14)
    if proc.returncode != 0:
        print((proc.stderr or "Download error").strip()[:300])
        sys.exit(1)
    print(f"Downloaded {fmt.upper()} to ~/Downloads")


if __name__ == "__main__":
    main()
