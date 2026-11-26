#!/usr/bin/env python3
import json
import os
import shutil
import subprocess
import sys


def find_tailscale():
    for cand in ["/usr/local/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]:
        if os.path.exists(cand):
            return cand
    return shutil.which("tailscale") or "tailscale"


def main():
    _ = sys.stdin.read()
    ts = find_tailscale()
    try:
        proc = subprocess.run([ts, "status", "--json"], capture_output=True, text=True, timeout=5)
        data = json.loads(proc.stdout or "{}")
    except Exception as exc:
        print(json.dumps({"detail": {"markdown": f"### Tailscale Error\n`{exc}`"}}))
        return

    backend = data.get("BackendState") or "Unknown"
    nodes = []
    if data.get("Self"):
        nodes.append(("This Mac", data["Self"]))
    for peer in (data.get("Peer") or {}).values():
        nodes.append(("Peer", peer))

    items = []
    for role, node in nodes:
        dns = (node.get("DNSName") or "").rstrip(".")
        host = node.get("HostName") or dns or "node"
        ips = node.get("TailscaleIPs") or []
        ip4 = next((i for i in ips if "." in i), ips[0] if ips else "-")
        os_name = node.get("OS") or "macOS"
        online = bool(node.get("Online", role == "This Mac" and backend == "Running"))
        status_label = "Online" if online else "Offline"
        color = "#34D399" if online else "#64748B"

        items.append({
            "id": node.get("ID") or host,
            "title": host,
            "subtitle": f"{role} · {dns or ip4}",
            "icon": "laptopcomputer" if "mac" in os_name.lower() else "server.rack",
            "category": status_label,
            "accessories": [
                {"kind": "tag", "text": status_label, "color": color},
                {"kind": "metric", "text": ip4},
                {"kind": "tag", "text": os_name, "color": "#38BDF8"}
            ],
            "detail": {
                "markdown": f"### {host}\n\n**Tailscale IP:** `{ip4}`\n\n**MagicDNS:** `{dns or host}`\n\n**OS:** {os_name}",
                "metadata": [
                    {"label": "Status", "value": status_label, "color": color},
                    {"label": "IPv4", "value": ip4},
                    {"label": "Backend", "value": backend},
                ]
            },
            "actions": [
                {"id": "copy-ip", "title": "Copy Tailscale IP", "icon": "doc.on.doc", "shortcut": "↵", "kind": "copy", "value": ip4},
                {"id": "copy-dns", "title": "Copy MagicDNS", "icon": "globe", "shortcut": "⌘C", "kind": "copy", "value": dns or host},
                {"id": "copy-ssh", "title": "Copy SSH Command", "icon": "terminal", "kind": "copy", "value": f"ssh {dns or ip4}"},
                {"id": "ping", "title": "Ping Peer", "icon": "waveform.path.ecg", "kind": "cli", "binary": ts, "args": ["ping", "--c", "1", ip4]},
            ]
        })

    print(json.dumps({
        "items": items,
        "filter_options": ["All", "Online", "Offline"],
        "empty_message": f"Tailscale backend state: {backend}. Open Tailscale to connect."
    }))


if __name__ == "__main__":
    main()
