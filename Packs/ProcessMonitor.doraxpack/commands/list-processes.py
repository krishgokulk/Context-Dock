#!/usr/bin/env python3
import json
import os
import subprocess
import sys

def main():
    ctx_raw = sys.stdin.read().strip()
    ctx = {}
    if ctx_raw:
        try:
            ctx = json.loads(ctx_raw)
        except Exception:
            ctx = {}

    active_filter = (ctx.get("filter") or os.environ.get("DORAX_FILTER") or "").strip().lower()
    sort_by_mem = active_filter == "high memory"

    out = subprocess.check_output(
        ["/bin/ps", "-axo", "pid=,%cpu=,rss=,comm="],
        text=True,
        stderr=subprocess.DEVNULL,
    )
    rows = []
    for line in out.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) < 4:
            continue
        try:
            pid = int(parts[0])
            cpu = float(parts[1])
            rss_kb = int(parts[2])
        except ValueError:
            continue
        comm = parts[3].strip()
        name = os.path.basename(comm) or comm
        mb = round(rss_kb / 1024.0, 1)
        rows.append((pid, cpu, mb, name, comm))

    if sort_by_mem:
        rows.sort(key=lambda r: r[2], reverse=True)
    else:
        rows.sort(key=lambda r: (r[1], r[2]), reverse=True)

    items = []
    for pid, cpu, mb, name, comm in rows[:30]:
        category = "High CPU" if cpu >= 15.0 else ("High Memory" if mb >= 300.0 else "Normal")
        if active_filter == "high cpu" and cpu < 5.0:
            continue
        if active_filter == "high memory" and mb < 150.0:
            continue

        cpu_color = "#EF4444" if cpu >= 50.0 else ("#F59E0B" if cpu >= 15.0 else "#34D399")
        mem_color = "#F472B6" if mb >= 500.0 else "#94A3B8"
        items.append({
            "id": str(pid),
            "title": name,
            "subtitle": f"PID {pid} · {comm}",
            "icon": "cpu",
            "category": category,
            "keywords": [name, str(pid), comm],
            "accessories": [
                {"kind": "metric", "text": f"{cpu:.1f}%", "color": cpu_color},
                {"kind": "metric", "text": f"{mb:.0f} MB", "color": mem_color},
            ],
            "detail": {
                "markdown": f"### {name}\n\nExecutable path:\n`{comm}`\n\nUse **Quit Process (SIGTERM)** for a graceful shutdown, or **Force Kill** only if unresponsive.",
                "metadata": [
                    {"label": "PID", "value": str(pid)},
                    {"label": "CPU", "value": f"{cpu:.1f}%", "color": cpu_color},
                    {"label": "Memory", "value": f"{mb:.1f} MB", "color": mem_color},
                    {"label": "Status", "value": category},
                ],
            },
            "actions": [
                {
                    "id": "copy-pid",
                    "title": "Copy PID",
                    "icon": "doc.on.doc",
                    "shortcut": "↵",
                    "kind": "copy",
                    "value": str(pid),
                },
                {
                    "id": "reveal-binary",
                    "title": "Reveal Binary in Finder",
                    "icon": "folder",
                    "shortcut": "⌘R",
                    "kind": "reveal",
                    "value": comm,
                },
                {
                    "id": "quit-sigterm",
                    "title": "Quit Process (SIGTERM)",
                    "icon": "xmark.circle",
                    "shortcut": "⌘⌫",
                    "kind": "cli",
                    "binary": "/bin/kill",
                    "args": ["-15", str(pid)],
                    "destructive": True,
                    "confirm_message": f"Send SIGTERM to {name} (PID {pid})?",
                },
                {
                    "id": "kill-sigkill",
                    "title": "Force Kill (SIGKILL)",
                    "icon": "flame.fill",
                    "shortcut": "⌥⌘⌫",
                    "kind": "cli",
                    "binary": "/bin/kill",
                    "args": ["-9", str(pid)],
                    "destructive": True,
                    "confirm_message": f"Force kill {name} (PID {pid}) immediately? Unsaved work may be lost.",
                },
            ],
        })

    print(json.dumps({
        "items": items,
        "filter_options": ["All", "High CPU", "High Memory"],
        "empty_message": "No matching processes found.",
    }))

if __name__ == "__main__":
    main()
