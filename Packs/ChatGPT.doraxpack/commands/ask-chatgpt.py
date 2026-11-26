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
    target = (form.get("target") or "ChatGPT Web (chatgpt.com)").strip()

    if not prompt:
        print(json.dumps({"empty_message": "Type a prompt or copy text to the clipboard first."}))
        return

    q_enc = urllib.parse.quote(prompt)
    web_url = f"https://chatgpt.com/?q={q_enc}"
    if "Temporary" in target:
        web_url += "&temporary-chat=true"

    if "Desktop" in target:
        subprocess.run(["/usr/bin/pbcopy"], input=prompt, text=True, check=False, timeout=3)
        subprocess.run(["/usr/bin/open", "-a", "ChatGPT"], check=False, timeout=4)
        summary = "Copied prompt to clipboard and activated **ChatGPT Desktop**."
    else:
        subprocess.run(["/usr/bin/open", web_url], check=False, timeout=4)
        summary = f"Opened **{target}**."

    print(json.dumps({
        "items": [{
            "id": "chatgpt-prompt",
            "title": prompt[:72],
            "subtitle": target,
            "icon": "bubble.left.and.text.bubble.right.fill",
            "app_icon_bundle_id": "com.openai.codex",
            "actions": [
                {"id": "open-web", "title": "Open in chatgpt.com", "icon": "safari", "shortcut": "↵", "kind": "open", "value": web_url},
                {"id": "copy-prompt", "title": "Copy Prompt", "icon": "doc.on.doc", "kind": "copy", "value": prompt},
            ]
        }],
        "detail": {
            "markdown": f"### {target}\n\n{summary}\n\n> {prompt[:400]}",
            "metadata": [{"label": "Target", "value": target, "color": "#10A37F"}]
        },
        "toast": f"Sent to {target}"
    }))


if __name__ == "__main__":
    main()
