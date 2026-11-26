#!/usr/bin/env python3
import json
import shutil
import subprocess
import sys


def load_context():
    try:
        raw = sys.stdin.read().strip()
        return json.loads(raw) if raw else {}
    except Exception:
        return {}


def format_duration(seconds):
    if not isinstance(seconds, (int, float)) or seconds <= 0:
        return "Live/Stream"
    s = int(seconds)
    m, sec = divmod(s, 60)
    h, m = divmod(m, 60)
    return f"{h}:{m:02d}:{sec:02d}" if h else f"{m}:{sec:02d}"


def main():
    ctx = load_context()
    form = ctx.get("formValues") or {}
    query = (form.get("query") or ctx.get("query") or "").strip()
    limit_raw = (form.get("limit") or "8").strip()
    try:
        limit = max(1, min(20, int(limit_raw)))
    except ValueError:
        limit = 8

    if not query:
        print(json.dumps({
            "empty_message": "Enter a search term (e.g. SwiftUI animations) and click Run Search YouTube Videos."
        }))
        return

    yt_dlp = shutil.which("yt-dlp") or "/opt/homebrew/bin/yt-dlp"
    try:
        proc = subprocess.run(
            [yt_dlp, "--flat-playlist", "--dump-json", "--no-warnings", f"ytsearch{limit}:{query}"],
            capture_output=True,
            text=True,
            timeout=13,
        )
    except Exception as exc:
        print(json.dumps({
            "detail": {
                "markdown": f"### Search Failed\nCould not run `yt-dlp`: `{exc}`\n\nInstall via `brew install yt-dlp`.",
                "metadata": [{"label": "Binary", "value": yt_dlp}]
            }
        }))
        return

    if proc.returncode != 0 and not proc.stdout.strip():
        err = (proc.stderr or "yt-dlp failed").strip()
        print(json.dumps({
            "detail": {
                "markdown": f"### yt-dlp Error\n```\n{err[:600]}\n```",
                "metadata": [{"label": "Query", "value": query}]
            }
        }))
        return

    items = []
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except Exception:
            continue
        vid_id = entry.get("id") or ""
        title = entry.get("title") or "Untitled Video"
        channel = entry.get("channel") or entry.get("uploader") or "YouTube"
        duration = format_duration(entry.get("duration"))
        url = entry.get("webpage_url") or entry.get("url") or (f"https://www.youtube.com/watch?v={vid_id}" if vid_id else "")
        if url and not url.startswith("http"):
            url = f"https://www.youtube.com/watch?v={url}"
        if not url:
            continue
        views = entry.get("view_count")
        views_label = f"{views:,} views" if isinstance(views, int) else "YouTube"

        items.append({
            "id": vid_id or url,
            "title": title,
            "subtitle": f"{channel} · {views_label}",
            "icon": "play.rectangle.fill",
            "category": "Video",
            "accessories": [
                {"kind": "tag", "text": duration, "color": "#FF0033"}
            ],
            "detail": {
                "markdown": f"### {title}\n\n**Channel:** {channel}\n\n**URL:** {url}",
                "metadata": [
                    {"label": "Duration", "value": duration, "color": "#FF0033"},
                    {"label": "Channel", "value": channel},
                    {"label": "Views", "value": views_label},
                ]
            },
            "actions": [
                {"id": "play-iina", "title": "Play in IINA", "icon": "play.circle.fill", "shortcut": "↵", "kind": "cli", "binary": "/usr/bin/open", "args": ["-a", "IINA", url]},
                {"id": "open-browser", "title": "Open in Browser", "icon": "safari", "shortcut": "⌘O", "kind": "open", "value": url},
                {"id": "send-downie", "title": "Send to Downie 4", "icon": "arrow.down.circle", "shortcut": "⌘D", "kind": "cli", "binary": "/usr/bin/open", "args": ["-a", "Downie 4", url]},
                {"id": "download-mp4", "title": "Download MP4 (yt-dlp)", "icon": "film", "kind": "script", "script": "commands/download-media.py", "value": f"mp4|{url}"},
                {"id": "download-mp3", "title": "Download MP3 (yt-dlp)", "icon": "music.note", "kind": "script", "script": "commands/download-media.py", "value": f"mp3|{url}"},
                {"id": "copy-url", "title": "Copy Video URL", "icon": "doc.on.doc", "shortcut": "⌘C", "kind": "copy", "value": url}
            ]
        })

    print(json.dumps({
        "items": items,
        "empty_message": f"No YouTube videos found for \"{query}\"."
    }))


if __name__ == "__main__":
    main()
