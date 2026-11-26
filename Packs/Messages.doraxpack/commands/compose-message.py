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
    recipient = (form.get("recipient") or "").strip()
    body = (form.get("body") or "").strip()

    if not recipient:
        print(json.dumps({"empty_message": "Enter a recipient phone number or iCloud email."}))
        return

    uri = f"sms:{urllib.parse.quote(recipient)}"
    if body:
        uri += f"&body={urllib.parse.quote(body)}"
    subprocess.run(["/usr/bin/open", uri], check=False, timeout=4)

    print(json.dumps({
        "items": [{
            "id": recipient,
            "title": f"Draft to {recipient}",
            "subtitle": body or "Messages composer opened — press Return inside Messages to send",
            "icon": "message.fill",
            "app_icon_bundle_id": "com.apple.MobileSMS",
            "actions": [
                {"id": "reopen", "title": "Open Draft in Messages", "icon": "message", "shortcut": "↵", "kind": "open", "value": uri},
                {"id": "copy", "title": "Copy Draft Text", "icon": "doc.on.doc", "kind": "copy", "value": body or recipient},
            ]
        }],
        "detail": {
            "markdown": f"### Opened Messages Draft\n\n**Recipient:** `{recipient}`\n\n**Draft:** {body or '(empty)'}\n\n*Not sent automatically — confirm inside Messages.*",
            "metadata": [{"label": "App", "value": "Messages", "color": "#34C759"}]
        },
        "toast": f"Draft opened for {recipient}"
    }))


if __name__ == "__main__":
    main()
