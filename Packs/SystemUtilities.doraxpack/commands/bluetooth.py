#!/usr/bin/env python3
import json
import subprocess
import sys


def parse_bt(data):
    items = []
    entries = data.get("SPBluetoothDataType") or []
    for block in entries:
        for cat, key, color in [
            ("Connected", "device_connected", "#34D399"),
            ("Paired", "device_not_connected", "#94A3B8"),
        ]:
            for dev in block.get(key) or []:
                for name, info in dev.items():
                    if not isinstance(info, dict):
                        continue
                    addr = info.get("device_address") or "-"
                    batt = info.get("device_batteryLevelMain") or info.get("device_batteryLevelLeft") or ""
                    minor = info.get("device_minorType") or "Bluetooth Device"
                    accs = [{"kind": "tag", "text": cat, "color": color}]
                    if batt:
                        accs.append({"kind": "metric", "text": str(batt)})
                    items.append({
                        "id": f"{cat}:{addr}:{name}",
                        "title": name,
                        "subtitle": f"{minor} · {addr}",
                        "icon": "headphones" if "audio" in minor.lower() or "head" in minor.lower() else "wave.3.right.circle.fill",
                        "category": cat,
                        "accessories": accs,
                        "detail": {
                            "markdown": f"### {name}\n\n**Status:** {cat}\n\n**Type:** {minor}\n\n**Address:** `{addr}`" + (f"\n\n**Battery:** {batt}" if batt else ""),
                            "metadata": [
                                {"label": "Status", "value": cat, "color": color},
                                {"label": "Address", "value": addr},
                                {"label": "Type", "value": minor},
                            ]
                        },
                        "actions": [
                            {"id": "copy-addr", "title": "Copy Device Address", "icon": "doc.on.doc", "shortcut": "↵", "kind": "copy", "value": addr},
                            {"id": "open-bt", "title": "Open Bluetooth Settings", "icon": "gearshape", "kind": "open", "value": "x-apple.systempreferences:com.apple.BluetoothSettings"},
                        ]
                    })
    return items


def main():
    _ = sys.stdin.read()
    try:
        proc = subprocess.run(["/usr/sbin/system_profiler", "SPBluetoothDataType", "-json"], capture_output=True, text=True, timeout=6.5)
        data = json.loads(proc.stdout or "{}")
    except Exception as exc:
        print(json.dumps({"detail": {"markdown": f"### Bluetooth Error\n`{exc}`"}}))
        return

    items = parse_bt(data)
    print(json.dumps({
        "items": items,
        "filter_options": ["All", "Connected", "Paired"],
        "empty_message": "No paired Bluetooth devices found."
    }))


if __name__ == "__main__":
    main()
