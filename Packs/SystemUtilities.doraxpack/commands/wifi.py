#!/usr/bin/env python3
import json
import subprocess
import sys


def detect_wifi_device():
    r = subprocess.run(["/usr/sbin/networksetup", "-listallhardwareports"], capture_output=True, text=True, timeout=4)
    lines = r.stdout.splitlines()
    for i, line in enumerate(lines):
        if "Wi-Fi" in line or "AirPort" in line:
            for j in range(i + 1, min(i + 4, len(lines))):
                if lines[j].strip().startswith("Device:"):
                    return lines[j].split(":", 1)[1].strip()
    return "en0"


def main():
    _ = sys.stdin.read()
    dev = detect_wifi_device()
    pwr = subprocess.run(["/usr/sbin/networksetup", "-getairportpower", dev], capture_output=True, text=True, timeout=4).stdout.strip()
    is_on = pwr.lower().endswith("on")
    ip = subprocess.run(["/usr/sbin/ipconfig", "getifaddr", dev], capture_output=True, text=True, timeout=3).stdout.strip() or "No IP"
    ssid_out = subprocess.run(["/usr/sbin/ipconfig", "getsummary", dev], capture_output=True, text=True, timeout=4).stdout
    ssid = ""
    for line in ssid_out.splitlines():
        if "SSID" in line and "BSSID" not in line and ":" in line:
            ssid = line.split(":", 1)[1].strip()
            break
    if not ssid:
        ssid = "Wi-Fi Connected" if is_on and ip != "No IP" else ("Wi-Fi On" if is_on else "Wi-Fi Off")

    toggle_val = "off" if is_on else "on"
    items = [
        {
            "id": "wifi-status",
            "title": ssid,
            "subtitle": f"Interface {dev} · IP {ip}",
            "icon": "wifi" if is_on else "wifi.slash",
            "category": "Status",
            "accessories": [
                {"kind": "tag", "text": "On" if is_on else "Off", "color": "#34D399" if is_on else "#64748B"},
                {"kind": "metric", "text": ip}
            ],
            "detail": {
                "markdown": f"### {ssid}\n\n**Power:** {'On' if is_on else 'Off'}\n\n**Interface:** `{dev}`\n\n**Local IPv4:** `{ip}`",
                "metadata": [
                    {"label": "State", "value": "On" if is_on else "Off", "color": "#34D399" if is_on else "#64748B"},
                    {"label": "Interface", "value": dev},
                    {"label": "IPv4", "value": ip},
                ]
            },
            "actions": [
                {"id": "copy-ip", "title": "Copy Local IPv4", "icon": "doc.on.doc", "shortcut": "↵", "kind": "copy", "value": ip},
                {"id": "toggle-wifi", "title": f"Turn Wi-Fi {'Off' if is_on else 'On'}", "icon": "wifi", "kind": "cli", "binary": "/usr/sbin/networksetup", "args": ["-setairportpower", dev, toggle_val]},
                {"id": "open-settings", "title": "Open Wi-Fi Settings", "icon": "gearshape", "kind": "open", "value": "x-apple.systempreferences:com.apple.wifi-settings-extension"},
            ]
        },
        {
            "id": "wifi-toggle-row",
            "title": f"Turn Wi-Fi {'Off' if is_on else 'On'}",
            "subtitle": f"Toggle radio power on {dev}",
            "icon": "power",
            "category": "Action",
            "accessories": [{"kind": "tag", "text": "Action", "color": "#38BDF8"}],
            "actions": [
                {"id": "toggle", "title": f"Turn Wi-Fi {'Off' if is_on else 'On'}", "icon": "wifi", "shortcut": "↵", "kind": "cli", "binary": "/usr/sbin/networksetup", "args": ["-setairportpower", dev, toggle_val]}
            ]
        },
    ]
    print(json.dumps({"items": items}))


if __name__ == "__main__":
    main()
