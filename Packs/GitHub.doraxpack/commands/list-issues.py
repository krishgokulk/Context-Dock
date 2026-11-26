#!/usr/bin/env python3
import json
import shutil
import subprocess
import sys


def main():
    _ = sys.stdin.read()
    gh = shutil.which("gh") or "/opt/homebrew/bin/gh"
    try:
        proc = subprocess.run([
            gh, "search", "issues", "--assignee=@me", "--state=open", "--limit", "25",
            "--json", "number,title,repository,url,updatedAt"
        ], capture_output=True, text=True, timeout=8)
    except Exception as exc:
        print(json.dumps({"detail": {"markdown": f"### GitHub Issues Error\n`{exc}`"}}))
        return

    if proc.returncode != 0:
        err = (proc.stderr or "gh search issues failed").strip()
        print(json.dumps({"detail": {"markdown": f"### GitHub Issues Error\n```\n{err[:500]}\n```"}}))
        return

    rows = json.loads(proc.stdout or "[]")
    items = []
    for issue in rows:
        num = issue.get("number", 0)
        title = issue.get("title") or f"Issue #{num}"
        repo = (issue.get("repository") or {}).get("nameWithOwner") or "repo"
        url = issue.get("url") or "https://github.com"
        updated = (issue.get("updatedAt") or "")[:10]
        items.append({
            "id": url,
            "title": f"#{num} {title}",
            "subtitle": repo,
            "icon": "exclamationmark.circle.fill",
            "category": "Open",
            "accessories": [
                {"kind": "tag", "text": "Open", "color": "#6366F1"},
                {"kind": "date", "text": updated}
            ],
            "detail": {
                "markdown": f"### #{num} {title}\n\n**Repository:** `{repo}`\n\n**URL:** {url}",
                "metadata": [
                    {"label": "Repository", "value": repo},
                    {"label": "Updated", "value": updated},
                ]
            },
            "actions": [
                {"id": "open", "title": "Open Issue", "icon": "safari", "shortcut": "↵", "kind": "open", "value": url},
                {"id": "copy-url", "title": "Copy Issue URL", "icon": "doc.on.doc", "shortcut": "⌘C", "kind": "copy", "value": url},
            ]
        })

    print(json.dumps({
        "items": items,
        "empty_message": "No open GitHub issues assigned to you."
    }))


if __name__ == "__main__":
    main()
