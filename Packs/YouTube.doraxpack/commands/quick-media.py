#!/usr/bin/env python3
import json
import os
import shutil
import subprocess
import sys


def load_context():
    try:
        raw = sys.stdin.read().strip()
        return json.loads(raw) if raw else {}
    except Exception:
        return {}


def is_youtube_url(val):
    if not val:
        return False
    low = val.strip().lower()
    return low.startswith("http") and ("youtube.com" in low or "youtu.be" in low)


def main():
    ctx = load_context()
    form = ctx.get("formValues") or {}
    prefs = ctx.get("preferences") or {}

    url = (form.get("url") or "").strip()
    if not url:
        front_url = (ctx.get("frontmost") or {}).get("url") or ""
        clip_text = (ctx.get("clipboard") or {}).get("text") or ""
        if is_youtube_url(front_url):
            url = front_url.strip()
        elif is_youtube_url(clip_text):
            url = clip_text.strip()

    action = (form.get("action") or "Play in IINA").strip()
    download_dir = os.path.expanduser(prefs.get("download_dir") or "~/Downloads")

    if not url:
        print(json.dumps({
            "detail": {
                "markdown": "### No YouTube URL Found\nPaste a `youtube.com` / `youtu.be` URL into the URL field, focus a YouTube browser tab, or copy a YouTube link to your clipboard.",
                "metadata": [{"label": "Action", "value": action}]
            }
        }))
        return

    yt_dlp = shutil.which("yt-dlp") or "/opt/homebrew/bin/yt-dlp"
    try:
        if action == "Play in IINA":
            subprocess.run(["/usr/bin/open", "-a", "IINA", url], check=True, timeout=5)
            msg = f"Opened in **IINA**:\n\n{url}"
            toast = "Playing in IINA"
        elif action == "Send to Downie 4":
            subprocess.run(["/usr/bin/open", "-a", "Downie 4", url], check=True, timeout=5)
            msg = f"Sent to **Downie 4**:\n\n{url}"
            toast = "Queued in Downie 4"
        elif action == "Open in Browser":
            subprocess.run(["/usr/bin/open", url], check=True, timeout=5)
            msg = f"Opened in browser:\n\n{url}"
            toast = "Opened in browser"
        elif action == "Download MP3 (yt-dlp)":
            os.makedirs(download_dir, exist_ok=True)
            out_tmpl = os.path.join(download_dir, "%(title).120s.%(ext)s")
            proc = subprocess.run(
                [yt_dlp, "-x", "--audio-format", "mp3", "--no-playlist", "-o", out_tmpl, url],
                capture_output=True, text=True, timeout=23
            )
            tail = (proc.stdout or proc.stderr or "").strip()[-400:]
            msg = f"### MP3 Download ({'Done' if proc.returncode == 0 else 'Finished with warning'})\nFolder: `{download_dir}`\n```\n{tail}\n```"
            toast = "MP3 saved to Downloads" if proc.returncode == 0 else "yt-dlp finished"
        else:
            os.makedirs(download_dir, exist_ok=True)
            out_tmpl = os.path.join(download_dir, "%(title).120s.%(ext)s")
            proc = subprocess.run(
                [yt_dlp, "-f", "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best", "--no-playlist", "-o", out_tmpl, url],
                capture_output=True, text=True, timeout=23
            )
            tail = (proc.stdout or proc.stderr or "").strip()[-400:]
            msg = f"### MP4 Download ({'Done' if proc.returncode == 0 else 'Finished with warning'})\nFolder: `{download_dir}`\n```\n{tail}\n```"
            toast = "Video saved to Downloads" if proc.returncode == 0 else "yt-dlp finished"

        print(json.dumps({
            "detail": {
                "markdown": msg,
                "metadata": [
                    {"label": "Action", "value": action, "color": "#FF0033"},
                    {"label": "Folder", "value": download_dir},
                ]
            },
            "toast": toast
        }))
    except Exception as exc:
        print(json.dumps({
            "detail": {
                "markdown": f"### Error\n`{exc}`",
                "metadata": [{"label": "Action", "value": action}]
            }
        }))


if __name__ == "__main__":
    main()
