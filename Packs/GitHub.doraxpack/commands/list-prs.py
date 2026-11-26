#!/usr/bin/env python3
import json
import shutil
import subprocess
import sys


def run_gh(args):
    gh = shutil.which("gh") or "/opt/homebrew/bin/gh"
    return subprocess.run([gh] + args, capture_output=True, text=True, timeout=8)


def main():
    _ = sys.stdin.read()
    try:
        proc = run_gh([
            "search", "prs", "--author=@me", "--state=open", "--limit", "25",
            "--json", "number,title,repository,url,updatedAt,isDraft"
        ])
    except Exception as exc:
        print(json.dumps({"detail": {"markdown": f"### GitHub CLI Error\n`{exc}`"}}))
        return

    if proc.returncode != 0:
        err = (proc.stderr or "Failed to query gh CLI").strip()
        hint = "Run `gh auth login` in Terminal if not authenticated." if "auth" in err.lower() or "login" in err.lower() else ""
        print(json.dumps({
            "detail": {
                "markdown": f"### GitHub PR Query Failed\n```\n{err[:500]}\n```\n{hint}"
            }
        }))
        return

    rows = json.loads(proc.stdout or "[]")
    items = []
    for pr in rows:
        num = pr.get("number", 0)
        title = pr.get("title") or f"PR #{num}"
        repo = (pr.get("repository") or {}).get("nameWithOwner") or "repo"
        url = pr.get("url") or "https://github.com"
        is_draft = bool(pr.get("isDraft"))
        cat = "Draft" if is_draft else "Ready"
        updated = (pr.get("updatedAt") or "")[:10]
        items.append({
            "id": url,
            "title": f"#{num} {title}",
            "subtitle": repo,
            "icon": "arrow.triangle.pull",
            "category": cat,
            "accessories": [
                {"kind": "tag", "text": cat, "color": "#94A3B8" if is_draft else "#34D399"},
                {"kind": "date", "text": updated}
            ],
            "detail": {
                "markdown": f"### #{num} {title}\n\n**Repository:** `{repo}`\n\n**Status:** {cat}\n\n**URL:** {url}",
                "metadata": [
                    {"label": "Repo", "value": repo},
                    {"label": "State", "value": cat, "color": "#34D399" if not is_draft else "#94A3B8"},
                    {"label": "Updated", "value": updated},
                ]
            },
            "actions": [
                {"id": "open", "title": "Open Pull Request", "icon": "safari", "shortcut": "↵", "kind": "open", "value": url},
                {"id": "copy-url", "title": "Copy PR URL", "icon": "doc.on.doc", "shortcut": "⌘C", "kind": "copy", "value": url},
                {"id": "copy-num", "title": "Copy #Number", "icon": "number", "kind": "copy", "value": f"#{num}"},
            ]
        })

    print(json.dumps({
        "items": items,
        "filter_options": ["All", "Ready", "Draft"],
        "empty_message": "No open pull requests authored by you."
    }))


if __name__ == "__main__":
    main()
