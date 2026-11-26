#!/usr/bin/env python3
import json
import sys


def main():
    _ = sys.stdin.read()
    items = [
        {
            "id": "desktop",
            "title": "Open ChatGPT Desktop",
            "subtitle": "Activate native ChatGPT app",
            "icon": "bubble.left.and.text.bubble.right.fill",
            "app_icon_bundle_id": "com.openai.codex",
            "accessories": [{"kind": "tag", "text": "Desktop", "color": "#10A37F"}],
            "actions": [{"id": "open", "title": "Open ChatGPT", "icon": "bolt", "shortcut": "↵", "kind": "cli", "binary": "/usr/bin/open", "args": ["-a", "ChatGPT"]}]
        },
        {
            "id": "new-web",
            "title": "New Chat (chatgpt.com)",
            "subtitle": "Open fresh ChatGPT thread",
            "icon": "plus.bubble.fill",
            "accessories": [{"kind": "tag", "text": "Web", "color": "#10A37F"}],
            "actions": [{"id": "open", "title": "Open chatgpt.com", "icon": "safari", "shortcut": "↵", "kind": "open", "value": "https://chatgpt.com/"}]
        },
        {
            "id": "temp-chat",
            "title": "Temporary Chat",
            "subtitle": "Incognito chatgpt.com session",
            "icon": "eye.slash.fill",
            "accessories": [{"kind": "tag", "text": "Private", "color": "#38BDF8"}],
            "actions": [{"id": "open", "title": "Open Temporary Chat", "icon": "safari", "shortcut": "↵", "kind": "open", "value": "https://chatgpt.com/?temporary-chat=true"}]
        },
        {
            "id": "codex",
            "title": "ChatGPT Codex Web",
            "subtitle": "chatgpt.com/codex",
            "icon": "terminal",
            "accessories": [{"kind": "tag", "text": "Code", "color": "#94A3B8"}],
            "actions": [{"id": "open", "title": "Open Codex", "icon": "safari", "shortcut": "↵", "kind": "open", "value": "https://chatgpt.com/codex"}]
        },
    ]
    print(json.dumps({"items": items}))


if __name__ == "__main__":
    main()
