#!/usr/bin/env python3
import json
import sys


def main():
    _ = sys.stdin.read()
    items = [
        {
            "id": "open-desktop",
            "title": "Open WhatsApp Desktop",
            "subtitle": "Launch native Mac app",
            "icon": "message.circle.fill",
            "app_icon_bundle_id": "net.whatsapp.WhatsApp",
            "accessories": [{"kind": "tag", "text": "Desktop", "color": "#25D366"}],
            "actions": [{"id": "open", "title": "Open WhatsApp", "icon": "message", "shortcut": "↵", "kind": "cli", "binary": "/usr/bin/open", "args": ["-a", "WhatsApp"]}]
        },
        {
            "id": "open-web",
            "title": "Open WhatsApp Web",
            "subtitle": "web.whatsapp.com in default browser",
            "icon": "safari.fill",
            "accessories": [{"kind": "tag", "text": "Web", "color": "#38BDF8"}],
            "actions": [{"id": "web", "title": "Open Web", "icon": "safari", "shortcut": "↵", "kind": "open", "value": "https://web.whatsapp.com"}]
        },
    ]
    print(json.dumps({"items": items}))


if __name__ == "__main__":
    main()
