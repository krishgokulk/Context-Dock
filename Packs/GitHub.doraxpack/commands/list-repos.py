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
            gh, "repo", "list", "--limit", "30",
            "--json", "nameWithOwner,description,url,isPrivate,stargazerCount,updatedAt"
        ], capture_output=True, text=True, timeout=8)
    except Exception as exc:
        print(json.dumps({"detail": {"markdown": f"### GitHub Repo Error\n`{exc}`"}}))
        return

    if proc.returncode != 0:
        err = (proc.stderr or "gh repo list failed").strip()
        print(json.dumps({"detail": {"markdown": f"### GitHub Repos Error\n```\n{err[:500]}\n```"}}))
        return

    rows = json.loads(proc.stdout or "[]")
    items = []
    for repo in rows:
        name = repo.get("nameWithOwner") or "repo"
        desc = repo.get("description") or "No description"
        url = repo.get("url") or f"https://github.com/{name}"
        priv = bool(repo.get("isPrivate"))
        vis = "Private" if priv else "Public"
        stars = repo.get("stargazerCount", 0)
        ssh_url = f"git@github.com:{name}.git"
        https_url = f"https://github.com/{name}.git"
        items.append({
            "id": name,
            "title": name,
            "subtitle": desc,
            "icon": "lock.fill" if priv else "folder.badge.gearshape",
            "category": vis,
            "accessories": [
                {"kind": "tag", "text": vis, "color": "#F59E0B" if priv else "#34D399"},
                {"kind": "metric", "text": f"★ {stars}"}
            ],
            "detail": {
                "markdown": f"### {name}\n\n{desc}\n\n**Clone HTTPS:** `{https_url}`\n\n**Clone SSH:** `{ssh_url}`",
                "metadata": [
                    {"label": "Visibility", "value": vis},
                    {"label": "Stars", "value": str(stars)},
                    {"label": "Updated", "value": (repo.get("updatedAt") or "")[:10]},
                ]
            },
            "actions": [
                {"id": "open", "title": "Open in GitHub", "icon": "safari", "shortcut": "↵", "kind": "open", "value": url},
                {"id": "copy-https", "title": "Copy HTTPS Clone URL", "icon": "doc.on.doc", "shortcut": "⌘C", "kind": "copy", "value": https_url},
                {"id": "copy-ssh", "title": "Copy SSH Clone URL", "icon": "key", "kind": "copy", "value": ssh_url},
            ]
        })

    print(json.dumps({
        "items": items,
        "filter_options": ["All", "Public", "Private"],
        "empty_message": "No repositories found for this gh account."
    }))


if __name__ == "__main__":
    main()
