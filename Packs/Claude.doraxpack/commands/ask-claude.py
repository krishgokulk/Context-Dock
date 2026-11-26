#!/usr/bin/env python3
import json
import subprocess
import sys
import urllib.parse


def main():
    try:
        ctx = json.loads(sys.stdin.read().strip() or "{}")
    except Exception:
        ctx = {}
    form = ctx.get("formValues") or {}
    prompt = (form.get("prompt") or "").strip()
    if not prompt:
        prompt = ((ctx.get("clipboard") or {}).get("text") or "").strip()
    target = (form.get("target") or "Claude Web (claude.ai)").strip()

    if not prompt:
        print(json.dumps({"empty_message": "Type a prompt or copy text to the clipboard first."}))
        return

    web_url = "https://claude.ai/new?q=" + urllib.parse.quote(prompt)
    if "Desktop" in target:
        subprocess.run(["/usr/bin/pbcopy"], input=prompt, text=True, check=False, timeout=3)
        subprocess.run(["/usr/bin/open", "-a", "Claude"], check=False, timeout=4)
        summary = "Copied prompt to clipboard and activated **Claude Desktop**."
    else:
        subprocess.run(["/usr/bin/open", web_url], check=False, timeout=4)
        summary = f"Opened new chat on **claude.ai**."

    print(json.dumps({
        "items": [{
            "id": "claude-prompt",
            "title": prompt[:72],
            "subtitle": target,
            "icon": "sparkles",
            "app_icon_bundle_id": "com.anthropic.claudefordesktop",
            "actions": [
                {"id": "open-web", "title": "Open in claude.ai", "icon": "safari", "shortcut": "↵", "kind": "open", "value": web_url},
                {"id": "copy-prompt", "title": "Copy Prompt", "icon": "doc.on.doc", "kind": "copy", "value": prompt},
            ]
        }],
        "detail": {
            "markdown": f"### {target}\n\n{summary}\n\n> {prompt[:400]}",
            "metadata": [{"label": "Target", "value": target, "color": "#D97757"}]
        },
        "toast": f"Sent to {target}"
    }))


if __name__ == "__main__":
    main()
