#!/usr/bin/env python3
import json
import os
import subprocess

def main():
    load1, load5, load15 = os.getloadavg()
    cpus = os.cpu_count() or 1

    try:
        ps_out = subprocess.check_output(["/bin/ps", "-ax", "-o", "pid="], text=True, stderr=subprocess.DEVNULL)
        proc_count = len([l for l in ps_out.splitlines() if l.strip()])
    except Exception:
        proc_count = 0

    try:
        lsof_out = subprocess.check_output(["/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN"], text=True, stderr=subprocess.DEVNULL)
        port_count = max(0, len(lsof_out.splitlines()) - 1)
    except Exception:
        port_count = 0

    try:
        uptime_out = subprocess.check_output(["/usr/bin/uptime"], text=True, stderr=subprocess.DEVNULL).strip()
        up_part = uptime_out.split("up ", 1)[-1].split(",")[0].strip()
    except Exception:
        up_part = "Active"

    items = [
        {
            "id": "load",
            "title": f"{load1:.2f} Load",
            "subtitle": f"{cpus} cores · 5m {load5:.2f} · 15m {load15:.2f}",
            "icon": "cpu",
            "swatch": "#38BDF8",
            "accessories": [{"kind": "tag", "text": "CPU", "color": "#38BDF8"}],
            "actions": [{"id": "copy", "title": "Copy Load Average", "icon": "doc.on.doc", "kind": "copy", "value": f"{load1:.2f} {load5:.2f} {load15:.2f}"}],
        },
        {
            "id": "procs",
            "title": f"{proc_count} Processes",
            "subtitle": "Active macOS user & system processes",
            "icon": "list.bullet.rectangle",
            "swatch": "#818CF8",
            "accessories": [{"kind": "tag", "text": "Active", "color": "#818CF8"}],
            "actions": [{"id": "copy", "title": "Copy Count", "icon": "doc.on.doc", "kind": "copy", "value": str(proc_count)}],
        },
        {
            "id": "ports",
            "title": f"{port_count} Open Ports",
            "subtitle": "Listening local TCP sockets",
            "icon": "network",
            "swatch": "#34D399",
            "accessories": [{"kind": "tag", "text": "TCP", "color": "#34D399"}],
            "actions": [{"id": "copy", "title": "Copy Port Count", "icon": "doc.on.doc", "kind": "copy", "value": str(port_count)}],
        },
        {
            "id": "uptime",
            "title": up_part,
            "subtitle": "Current Mac uptime",
            "icon": "clock.fill",
            "swatch": "#F59E0B",
            "accessories": [{"kind": "tag", "text": "Uptime", "color": "#F59E0B"}],
            "actions": [{"id": "copy", "title": "Copy Uptime", "icon": "doc.on.doc", "kind": "copy", "value": up_part}],
        },
    ]
    print(json.dumps({"items": items}))

if __name__ == "__main__":
    main()
