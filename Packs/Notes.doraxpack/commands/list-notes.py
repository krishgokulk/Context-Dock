#!/usr/bin/env python3
import json
import subprocess
import sys


AS = '''
tell application "Notes"
    set totalCount to count of notes
    if totalCount is 0 then return ""
    set maxCount to 20
    if totalCount < maxCount then set maxCount to totalCount
    set allIDs to id of (notes 1 thru maxCount)
    set allNames to name of (notes 1 thru maxCount)
    set allDates to modification date of (notes 1 thru maxCount)
    set allBodies to plaintext of (notes 1 thru maxCount)

    set outList to {}
    repeat with i from 1 to count of allIDs
        set nid to ""
        try
            set nid to (item i of allIDs) as string
        end try
        set ntitle to "Untitled Note"
        try
            set t to item i of allNames
            if t is not missing value then set ntitle to (t as string)
        end try
        set ndate to ""
        try
            set d to item i of allDates
            if d is not missing value then set ndate to (d as string)
        end try
        set nbody to ""
        try
            set b to item i of allBodies
            if b is not missing value then set nbody to (b as string)
        end try
        if length of nbody > 900 then set nbody to text 1 thru 900 of nbody
        set ntitle to my replaceText(ntitle, "|||", " ")
        set nbody to my replaceText(nbody, return, "\\n")
        set nbody to my replaceText(nbody, linefeed, " ")
        set nbody to my replaceText(nbody, "|||", " ")
        set nbody to my replaceText(nbody, "\\n", " ")
        set end of outList to (nid & "|||" & ntitle & "|||" & ndate & "|||" & nbody)
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
        proc = subprocess.run(["/usr/bin/osascript", "-e", AS], capture_output=True, text=True, timeout=9)
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
        if len(parts) < 4:
            continue
        nid, title, mod_date, plain = [p.strip() for p in parts[:4]]
        if not nid:
            continue
        if q and q not in title.lower() and q not in plain.lower():
            continue
        snippet = plain
        if snippet.lower().startswith(title.lower()):
            snippet = snippet[len(title):].strip(" :-•")
        items.append({
            "id": nid,
            "title": title or "Untitled Note",
            "subtitle": snippet[:95] if snippet else (mod_date[:22] or "Apple Notes"),
            "icon": "note.text",
            "app_icon_bundle_id": "com.apple.Notes",
            "category": "Notes",
            "accessories": [
                {"kind": "tag", "text": "Notes", "color": "#FACC15"}
            ],
            "detail": {
                "markdown": f"### {title}\n\n{plain or '(Empty note)'}",
                "metadata": [
                    {"label": "App", "value": "Apple Notes", "color": "#FACC15"},
                    {"label": "Modified", "value": mod_date[:22] or "-"},
                ]
            },
            "actions": [
                {"id": "open-note", "title": "Open in Apple Notes", "icon": "note.text", "shortcut": "↵", "kind": "script", "script": "commands/open-note.py", "value": nid},
                {"id": "copy-body", "title": "Copy Note Text", "icon": "doc.on.doc", "shortcut": "⌘C", "kind": "copy", "value": f"{title}\n\n{plain}"},
                {"id": "copy-title", "title": "Copy Title", "icon": "textformat", "kind": "copy", "value": title},
            ]
        })

    print(json.dumps({
        "items": items,
        "empty_message": "No Apple Notes matched your query."
    }))


if __name__ == "__main__":
    main()
