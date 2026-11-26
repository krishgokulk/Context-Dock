#!/usr/bin/env python3
import json
import os
import subprocess
import sys

def main():
    try:
        out = subprocess.check_output(
            ["/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        out = ""

    seen = set()
    items = []
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 9:
            continue
        proc, pid, user, name_col = parts[0], parts[1], parts[2], parts[8]
        port = name_col.rsplit(":", 1)[-1]
        key = (pid, port)
        if key in seen:
            continue
        seen.add(key)

        try:
            port_num = int(port)
        except ValueError:
            port_num = 0
        is_dev = port_num >= 1024
        category = "Dev Ports" if is_dev else "System"
        url = f"http://localhost:{port}"

        items.append({
            "id": f"{pid}:{port}",
            "title": f"{proc}  :{port}",
            "subtitle": f"PID {pid} · {user} · {name_col}",
            "icon": "network",
            "category": category,
            "keywords": [proc, pid, port, "localhost"],
            "accessories": [
                {"kind": "tag", "text": f":{port}", "color": "#38BDF8" if is_dev else "#94A3B8"},
                {"kind": "metric", "text": f"PID {pid}"},
            ],
            "detail": {
                "markdown": f"### {proc} on Port {port}\n\nListening address: `{name_col}`\nLocal URL: `{url}`",
                "metadata": [
                    {"label": "Process", "value": proc},
                    {"label": "PID", "value": pid},
                    {"label": "Port", "value": port, "color": "#38BDF8"},
                    {"label": "User", "value": user},
                ],
            },
            "actions": [
                {
                    "id": "open-localhost",
                    "title": f"Open {url}",
                    "icon": "safari",
                    "shortcut": "↵",
                    "kind": "open",
                    "value": url,
                },
                {
                    "id": "copy-url",
                    "title": "Copy Localhost URL",
                    "icon": "doc.on.doc",
                    "shortcut": "⌘C",
                    "kind": "copy",
                    "value": url,
                },
                {
                    "id": "kill-server",
                    "title": "Stop Server (SIGTERM)",
                    "icon": "stop.circle.fill",
                    "shortcut": "⌘⌫",
                    "kind": "cli",
                    "binary": "/bin/kill",
                    "args": ["-15", pid],
                    "destructive": True,
                    "confirm_message": f"Stop {proc} (PID {pid}) listening on port {port}?",
                },
            ],
        })

    print(json.dumps({
        "items": items[:30],
        "filter_options": ["All", "Dev Ports", "System"],
        "empty_message": "No TCP servers are currently listening.",
    }))

if __name__ == "__main__":
    main()
