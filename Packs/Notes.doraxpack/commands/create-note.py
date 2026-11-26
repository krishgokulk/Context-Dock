#!/usr/bin/env python3
import html
import json
import subprocess
import sys


def main():
    try:
        ctx = json.loads(sys.stdin.read().strip() or "{}")
    except Exception:
        ctx = {}
    form = ctx.get("formValues") or {}
    title = (form.get("title") or "").strip()
    folder = (form.get("folder") or "Notes").strip() or "Notes"
    body = (form.get("body") or "").strip()

    if not title:
        print(json.dumps({"empty_message": "Enter a Note Title to create a note in Apple Notes."}))
        return

    body_html = f"<h1>{html.escape(title)}</h1>"
    if body:
        body_html += "<p>" + html.escape(body).replace("\n", "<br>") + "</p>"

    as_code = '''
on run argv
    set fName to item 1 of argv
    set hBody to item 2 of argv
    tell application "Notes"
        if not (exists folder fName) then
            set targetFolder to default folder of default account
        else
            set targetFolder to folder fName
        end if
        set createdNote to make new note at targetFolder with properties {body: hBody}
        return id of createdNote
    end tell
end run
'''
    proc = subprocess.run(["/usr/bin/osascript", "-e", as_code, "--", folder, body_html], capture_output=True, text=True, timeout=6)
    if proc.returncode != 0:
        err = (proc.stderr or "Failed to create Apple Note").strip()
        print(json.dumps({"detail": {"markdown": f"### Failed to Create Note\n```\n{err[:400]}\n```"}}))
        return

    nid = (proc.stdout or "").strip()
    print(json.dumps({
        "items": [{
            "id": nid or title,
            "title": title,
            "subtitle": f"Created in Apple Notes · {folder}",
            "icon": "checkmark.circle.fill",
            "app_icon_bundle_id": "com.apple.Notes",
            "actions": [
                {"id": "open-note", "title": "Show in Apple Notes", "icon": "note.text", "shortcut": "↵", "kind": "script", "script": "commands/open-note.py", "value": nid}
            ]
        }],
        "detail": {
            "markdown": f"### Created Apple Note\n\n**Title:** {title}\n\n**Folder:** {folder}\n\n{body}",
            "metadata": [{"label": "Folder", "value": folder, "color": "#FACC15"}]
        },
        "toast": f"Created \"{title}\" in Notes"
    }))


if __name__ == "__main__":
    main()
