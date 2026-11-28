#!/usr/bin/env python3
import json
import os
import subprocess
import sys


def is_awake():
    pid_file = "/tmp/context-dock-caffeinate.pid"
    if os.path.isfile(pid_file):
        try:
            pid = int(open(pid_file).read().strip())
            r = subprocess.run(["/bin/kill", "-0", str(pid)], capture_output=True)
            if r.returncode == 0:
                return True
        except Exception:
            pass
    return False


def main():
    _ = sys.stdin.read()
    active = is_awake()
    items = [
        {
            "id": "stop",
            "title": "Allow Mac to Sleep" if active else "Normal Sleep Active",
            "subtitle": "Stop caffeinate timer" if active else "macOS sleep timer is currently idle",
            "icon": "powersleep",
            "accessories": [{"kind": "tag", "text": "Active" if active else "Idle", "color": "#F59E0B" if active else "#64748B"}],
            "actions": [{"id": "stop-awake", "title": "Stop Keep Awake", "icon": "powersleep", "shortcut": "↵", "kind": "script", "script": "commands/run-caffeinate.py", "value": "stop"}]
        },
        {
            "id": "15m",
            "title": "Keep Awake 15 min",
            "subtitle": "caffeinate -dimsu -t 900",
            "icon": "cup.and.saucer.fill",
            "accessories": [{"kind": "tag", "text": "15m", "color": "#38BDF8"}],
            "actions": [{"id": "start-15m", "title": "Start 15m Awake", "icon": "cup.and.saucer.fill", "shortcut": "↵", "kind": "script", "script": "commands/run-caffeinate.py", "value": "900"}]
        },
        {
            "id": "30m",
            "title": "Keep Awake 30 min",
            "subtitle": "caffeinate -dimsu -t 1800",
            "icon": "cup.and.saucer.fill",
            "accessories": [{"kind": "tag", "text": "30m", "color": "#38BDF8"}],
            "actions": [{"id": "start-30m", "title": "Start 30m Awake", "icon": "cup.and.saucer.fill", "shortcut": "↵", "kind": "script", "script": "commands/run-caffeinate.py", "value": "1800"}]
        },
        {
            "id": "1h",
            "title": "Keep Awake 1 hour",
            "subtitle": "caffeinate -dimsu -t 3600",
            "icon": "cup.and.saucer.fill",
            "accessories": [{"kind": "tag", "text": "1h", "color": "#34D399"}],
            "actions": [{"id": "start-1h", "title": "Start 1h Awake", "icon": "cup.and.saucer.fill", "shortcut": "↵", "kind": "script", "script": "commands/run-caffeinate.py", "value": "3600"}]
        },
        {
            "id": "forever",
            "title": "Keep Awake Indefinitely",
            "subtitle": "Stay awake until manually stopped",
            "icon": "infinity.circle.fill",
            "accessories": [{"kind": "tag", "text": "∞", "color": "#A855F7"}],
            "actions": [{"id": "start-inf", "title": "Start Keep Awake", "icon": "infinity", "shortcut": "↵", "kind": "script", "script": "commands/run-caffeinate.py", "value": "0"}]
        },
    ]
    print(json.dumps({"items": items}))


if __name__ == "__main__":
    main()
