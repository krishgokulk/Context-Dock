#!/usr/bin/env python3
import json
import re
import subprocess
import sys
import urllib.parse


def main():
    try:
        ctx = json.loads(sys.stdin.read().strip() or "{}")
    except Exception:
        ctx = {}
    form = ctx.get("formValues") or {}
    phone_raw = (form.get("phone") or "").strip()
    digits = re.sub(r"[^0-9]", "", phone_raw)
    msg = (form.get("message") or "").strip()

    if not digits:
        print(json.dumps({"empty_message": "Enter a phone number with country code (e.g. +15551234567)."}))
        return

    uri = f"whatsapp://send?phone={digits}"
    if msg:
        uri += "&text=" + urllib.parse.quote(msg)
    wa_link = f"https://wa.me/{digits}" + (f"?text={urllib.parse.quote(msg)}" if msg else "")
    subprocess.run(["/usr/bin/open", uri], check=False, timeout=4)

    print(json.dumps({
        "items": [{
            "id": digits,
            "title": f"Draft in WhatsApp (+{digits})",
            "subtitle": msg or "Chat opened — confirm before sending",
            "icon": "message.fill",
            "app_icon_bundle_id": "net.whatsapp.WhatsApp",
            "actions": [
                {"id": "copy-link", "title": "Copy wa.me Link", "icon": "link", "shortcut": "↵", "kind": "copy", "value": wa_link},
                {"id": "open-uri", "title": "Re-open in WhatsApp", "icon": "message", "kind": "open", "value": uri},
            ]
        }],
        "detail": {
            "markdown": f"### Opened WhatsApp Chat\n\n**Number:** `+{digits}`\n\n**Draft:** {msg or '(none)'}\n\n**Shareable Link:** {wa_link}",
            "metadata": [{"label": "App", "value": "WhatsApp", "color": "#25D366"}]
        },
        "toast": f"Opened WhatsApp chat for +{digits}"
    }))


if __name__ == "__main__":
    main()
