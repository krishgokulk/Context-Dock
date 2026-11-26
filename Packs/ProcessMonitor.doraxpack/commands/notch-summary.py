#!/usr/bin/env python3
import json
import os
import subprocess

def main():
    load1, _, _ = os.getloadavg()
    try:
        lsof_out = subprocess.check_output(
            ["/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
        port_count = max(0, len(lsof_out.splitlines()) - 1)
    except Exception:
        port_count = 0

    print(json.dumps({
        "notch": {
            "wing_text": f"{port_count}p · {load1:.1f}",
            "wing_icon": "cpu",
            "wing_color": "#38BDF8",
            "title": "Process & Port Monitor",
            "subtitle": f"{port_count} listening TCP ports · 1m load {load1:.2f}",
            "progress": min(1.0, load1 / max(1, os.cpu_count() or 1)),
            "actions": [
                {
                    "id": "copy-summary",
                    "title": "Copy Summary",
                    "icon": "doc.on.doc",
                    "kind": "copy",
                    "value": f"{port_count} open ports, load {load1:.2f}",
                }
            ],
        },
        "appearance": {"tint": "#38BDF8", "glow": "soft"},
    }))

if __name__ == "__main__":
    main()
