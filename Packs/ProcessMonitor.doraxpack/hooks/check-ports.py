#!/usr/bin/env python3
import json
import os
import subprocess

def main():
    load1, _, _ = os.getloadavg()
    cpus = os.cpu_count() or 1
    if load1 >= cpus * 1.5:
        print(json.dumps({
            "notch": {
                "wing_text": f"CPU {load1:.1f}",
                "wing_icon": "flame.fill",
                "wing_color": "#EF4444",
                "title": "High System Load",
                "subtitle": f"1m load {load1:.2f} across {cpus} cores",
            },
            "appearance": {"tint": "#EF4444", "glow": "pulse"},
            "suggestions": [
                {
                    "title": "Inspect High CPU Processes",
                    "subtitle": f"Load {load1:.2f} on {cpus} cores",
                    "icon": "cpu",
                }
            ],
        }))
    else:
        print(json.dumps({"state": {"last_load": f"{load1:.2f}"}}))

if __name__ == "__main__":
    main()
