#!/usr/bin/env python3
import json
import sys


def main():
    _ = sys.stdin.read()
    items = [
        {
            "id": "desktop",
            "title": "Open Claude Desktop",
            "subtitle": "Activate native Claude app",
            "icon": "sparkles",
            "app_icon_bundle_id": "com.anthropic.claudefordesktop",
            "accessories": [{"kind": "tag", "text": "Desktop", "color": "#D97757"}],
            "actions": [{"id": "open", "title": "Open Claude", "icon": "sparkles", "shortcut": "↵", "kind": "cli", "binary": "/usr/bin/open", "args": ["-a", "Claude"]}]
        },
        {
            "id": "new-web",
            "title": "New Chat (claude.ai)",
            "subtitle": "Start fresh thread on claude.ai/new",
            "icon": "plus.bubble.fill",
            "accessories": [{"kind": "tag", "text": "Web", "color": "#D97757"}],
            "actions": [{"id": "open", "title": "New Web Chat", "icon": "safari", "shortcut": "↵", "kind": "open", "value": "https://claude.ai/new"}]
        },
        {
            "id": "projects",
            "title": "Claude Projects",
            "subtitle": "Open claude.ai/projects",
            "icon": "folder.fill",
            "accessories": [{"kind": "tag", "text": "Web", "color": "#38BDF8"}],
            "actions": [{"id": "open", "title": "Open Projects", "icon": "safari", "shortcut": "↵", "kind": "open", "value": "https://claude.ai/projects"}]
        },
        {
            "id": "console",
            "title": "Anthropic Console",
            "subtitle": "console.anthropic.com",
            "icon": "slider.horizontal.3",
            "accessories": [{"kind": "tag", "text": "API", "color": "#94A3B8"}],
            "actions": [{"id": "open", "title": "Open Console", "icon": "safari", "shortcut": "↵", "kind": "open", "value": "https://console.anthropic.com"}]
        },
    ]
    print(json.dumps({"items": items}))


if __name__ == "__main__":
    main()
