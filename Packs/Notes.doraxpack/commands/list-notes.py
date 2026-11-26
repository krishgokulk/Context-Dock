#!/usr/bin/env python3
import json
import subprocess
import sys


AS = '''
tell application "Notes"
    set outList to {}
    set allNotes to every note
    set maxCount to count of allNotes
    if maxCount > 35 then set maxCount to 35
    repeat with i from 1 to maxCount
        set n to item i of allNotes
        set nid to id of n
        set ntitle to name of n
        set nfolder to name of container of n
        set nbody to plaintext of n
        if length of nbody > 900 then set nbody to text 1 thru 900 of nbody
        set ndate to (modification date of n) as string
        set nbody to my replaceText(nbody, return, " ")
        set nbody to my replaceText(nbody, linefeed, " ")
        set nbody to my replaceText(nbody, "|||", " ")
        set end of outList to (nid & "|||" & ntitle & "|||" & nfolder & "|||" & ndate & "|||" & nbody)
    end repeat
    set AppleScript's text item delimiters to "\\n"
    return outList as text
end tell

on replaceText(theText, searchStr, replaceStr)
    set AppleScript's text item delimiters to searchStr
    set parts to every text item of theText
    set AppleScript's text item delimiters to replaceStr
    set res to parts as text
    set AppleScript's text item delimiters to ""
    return res
end replaceText
'''


def main():
    try:
        ctx = json.loads(sys.stdin.read().strip() or "{}")
    except Exception:
        ctx = {}
    q = (ctx.get("query") or "").strip().lower()

    try:
        proc = subprocess.run(["/usr/bin/osascript", "-e", AS], capture_output=True, text=True, timeout=6.5)
    except Exception as exc:
        print(json.dumps({"detail": {"markdown": f"### Apple Notes Timed Out\n`{exc}`"}}))
        return

    if proc.returncode != 0:
        err = (proc.stderr or "Automation permission required for Notes").strip()
        print(json.dumps({
            "items": [{
                "id": "open-notes",
                "title": "Open Apple Notes",
                "subtitle": "Grant Automation access to Notes in System Settings if reading notes is blocked",
                "icon": "note.text",
                "app_icon_bundle_id": "com.apple.Notes",
                "actions": [{"id": "open", "title": "Open Apple Notes", "icon": "note.text", "shortcut": "↵", "kind": "cli", "binary": "/usr/bin/open", "args": ["-a", "Notes"]}]
            }],
            "detail": {"markdown": f"### Apple Notes Error\n```\n{err[:400]}\n```"}
        }))
        return

    items = []
    for line in (proc.stdout or "").splitlines():
        parts = line.split("|||")
        if len(parts) < 5:
            continue
        nid, title, folder, mod_date, snippet = [p.strip() for p in parts[:5]]
        if q and q not in title.lower() and q not in folder.lower() and q not in snippet.lower():
            continue
        items.append({
            "id": nid,
            "title": title or "Untitled Note",
            "subtitle": f"{folder} · {snippet[:90]}",
            "icon": "note.text",
            "app_icon_bundle_id": "com.apple.Notes",
            "category": folder,
            "accessories": [
                {"kind": "tag", "text": folder[:16], "color": "#FACC15"}
            ],
            "detail": {
                "markdown": f"### {title}\n\n{snippet}",
                "metadata": [
                    {"label": "Folder", "value": folder, "color": "#FACC15"},
                    {"label": "Modified", "value": mod_date[:22]},
                ]
            },
            "actions": [
                {"id": "open-note", "title": "Open in Apple Notes", "icon": "note.text", "shortcut": "↵", "kind": "script", "script": "commands/open-note.py", "value": nid},
                {"id": "copy-body", "title": "Copy Note Text", "icon": "doc.on.doc", "shortcut": "⌘C", "kind": "copy", "value": f"{title}\n\n{snippet}"},
                {"id": "copy-title", "title": "Copy Title", "icon": "textformat", "kind": "copy", "value": title},
            ]
        })

    print(json.dumps({
        "items": items,
        "empty_message": "No Apple Notes matched your query."
    }))


if __name__ == "__main__":
    main()
