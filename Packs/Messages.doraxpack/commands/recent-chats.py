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
            set rawName to name of c
            if rawName is not missing value then set cname to (rawName as string)
        end try
        set cid to ""
        try
            set rawID to id of c
            if rawID is not missing value then set cid to (rawID as string)
        end try
        set pNames to {}
        set primaryHandle to ""
        set pCount to 0
        try
            set plist to participants of c
            set pCount to count of plist
            set maxP to pCount
            if maxP > 3 then set maxP to 3
            repeat with j from 1 to maxP
                set p to item j of plist
                set h to ""
                try
                    set rawH to handle of p
                    if rawH is not missing value then set h to (rawH as string)
                end try
                if primaryHandle is "" and h is not "" then set primaryHandle to h
                set fn to ""
                try
                    set rawFN to full name of p
                    if rawFN is not missing value then set fn to (rawFN as string)
                end try
                if fn is "" then
                    try
                        set rawN to name of p
                        if rawN is not missing value then set fn to (rawN as string)
                    end try
                end if
                if fn is "" then set fn to h
                if fn is not "" then set end of pNames to fn
            end repeat
        end try
        set AppleScript's text item delimiters to ", "
        set pJoined to pNames as text
        set AppleScript's text item delimiters to ""
        if cname is "" then set cname to pJoined
        set end of outLines to (cname & "|||" & cid & "|||" & primaryHandle & "|||" & (pCount as string) & "|||" & pJoined)
    end repeat
    set AppleScript's text item delimiters to "\\n"
    return outLines as text
end tell
'''


def main():
    _ = sys.stdin.read()
    try:
        proc = subprocess.run(["/usr/bin/osascript", "-e", AS], capture_output=True, text=True, timeout=5.5)
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
        parts = line.split("|||")
        if len(parts) < 2:
            continue
        cname = parts[0].strip()
        cid = parts[1].strip()
        primary_handle = parts[2].strip() if len(parts) > 2 else ""
        p_count = int(parts[3].strip()) if len(parts) > 3 and parts[3].strip().isdigit() else 0
        p_joined = parts[4].strip() if len(parts) > 4 else ""

        fallback_handle = cid.split(";-;")[-1] if ";-;" in cid else ""
        handle = primary_handle or fallback_handle
        title = cname or handle
        if not title:
            continue

        is_group = ";+;" in cid or p_count > 1
        tag_text = "Group" if is_group else "Direct"
        subtitle = f"Group · {p_count} participants" if is_group and p_count > 0 else (handle or p_joined or "iMessage / SMS")
        uri = f"imessage://{urllib.parse.quote(handle)}" if handle else "imessage://"
        copy_val = handle or cname or cid

        items.append({
            "id": cid or f"{title}-{idx}",
            "title": title,
            "subtitle": subtitle,
            "icon": "person.2.fill" if is_group else "message.fill",
            "app_icon_bundle_id": "com.apple.MobileSMS",
            "category": tag_text,
            "accessories": [{"kind": "tag", "text": tag_text, "color": "#34C759"}],
            "detail": {
                "markdown": f"### {title}\n\n**Type:** {tag_text}\n\n**Participants:** {p_joined or title}",
                "metadata": [
                    {"label": "Kind", "value": tag_text, "color": "#34C759"},
                    {"label": "Handle", "value": handle or "-"},
                ]
            },
            "actions": [
                {"id": "open-thread", "title": "Open Chat in Messages", "icon": "message", "shortcut": "↵", "kind": "open", "value": uri},
                {"id": "copy-handle", "title": "Copy Handle / Name", "icon": "doc.on.doc", "shortcut": "⌘C", "kind": "copy", "value": copy_val},
            ]
        })

    print(json.dumps({
        "items": items[:25],
        "filter_options": ["All", "Direct", "Group"],
        "empty_message": "No Messages chats returned."
    }))


if __name__ == "__main__":
    main()
