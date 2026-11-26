#!/usr/bin/env python3
import json
import subprocess
import sys
import urllib.parse


AS = '''
tell application "Messages"
    set outLines to {}
    set cList to chats
    set n to count of cList
    if n > 25 then set n to 25
    repeat with i from 1 to n
        set c to item i of cList
        set cname to ""
        try
            set cname to name of c
        end try
        set cid to ""
        try
            set cid to id of c
        end try
        if cname is "" then set cname to cid
        set end of outLines to (cname & "|||" & cid)
    end repeat
    set AppleScript's text item delimiters to "\\n"
    return outLines as text
end tell
'''


def main():
    _ = sys.stdin.read()
    try:
        proc = subprocess.run(["/usr/bin/osascript", "-e", AS], capture_output=True, text=True, timeout=4.5)
    except Exception as exc:
        print(json.dumps({
            "detail": {"markdown": f"### Messages Query Timed Out or Unavailable\n`{exc}`"}
        }))
        return

    if proc.returncode != 0:
        err = (proc.stderr or "Messages scripting permission needed").strip()
        print(json.dumps({
            "items": [{
                "id": "open-messages",
                "title": "Open Messages",
                "subtitle": "Grant Automation permission in System Settings if thread list is blocked",
                "icon": "message.fill",
                "app_icon_bundle_id": "com.apple.MobileSMS",
                "actions": [{"id": "open", "title": "Open Messages", "icon": "message", "shortcut": "↵", "kind": "cli", "binary": "/usr/bin/open", "args": ["-a", "Messages"]}]
            }],
            "detail": {"markdown": f"### Messages Automation Info\n```\n{err[:400]}\n```"}
        }))
        return

    items = []
    for idx, line in enumerate((proc.stdout or "").splitlines()):
        if "|||" not in line:
            continue
        name, cid = line.split("|||", 1)
        handle = cid.split(";-;")[-1] if ";-;" in cid else cid
        uri = f"imessage://{urllib.parse.quote(handle)}" if handle else "imessage://"
        items.append({
            "id": cid or str(idx),
            "title": name.strip() or handle or f"Chat {idx+1}",
            "subtitle": handle or cid,
            "icon": "message.fill",
            "app_icon_bundle_id": "com.apple.MobileSMS",
            "accessories": [{"kind": "tag", "text": "Thread", "color": "#34C759"}],
            "actions": [
                {"id": "open-thread", "title": "Open Chat in Messages", "icon": "message", "shortcut": "↵", "kind": "open", "value": uri},
                {"id": "copy-handle", "title": "Copy Handle / ID", "icon": "doc.on.doc", "shortcut": "⌘C", "kind": "copy", "value": handle or cid},
            ]
        })

    print(json.dumps({
        "items": items,
        "empty_message": "No Messages chats returned."
    }))


if __name__ == "__main__":
    main()
