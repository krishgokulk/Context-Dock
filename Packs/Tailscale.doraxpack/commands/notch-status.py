#!/usr/bin/env python3
import json
import os
import shutil
import subprocess
import sys


def main():
    _ = sys.stdin.read()
    ts = "/usr/local/bin/tailscale" if os.path.exists("/usr/local/bin/tailscale") else (shutil.which("tailscale") or "tailscale")
    try:
        proc = subprocess.run([ts, "status", "--json"], capture_output=True, text=True, timeout=5)
        data = json.loads(proc.stdout or "{}")
        backend = data.get("BackendState") or "Stopped"
        peers = (data.get("Peer") or {}).values()
        online = sum(1 for p in peers if p.get("Online"))
        wing = f"TS {online}↑" if backend == "Running" else "TS Off"
        sub = f"{online} peer(s) online · {backend}"
    except Exception:
        wing = "Tailscale"
        sub = "Open Tailscale to inspect tailnet"

    print(json.dumps({
        "notch": {
            "wing_text": wing,
            "wing_icon": "network.badge.shield.half.filled",
            "wing_color": "#38BDF8",
            "title": "Tailscale Network",
            "subtitle": sub
        },
        "appearance": {"tint": "#38BDF8", "glow": "soft"}
    }))


if __name__ == "__main__":
    main()
