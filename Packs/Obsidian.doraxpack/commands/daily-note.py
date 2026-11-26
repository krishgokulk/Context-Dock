#!/usr/bin/env python3
import datetime
import json
import os
import sys
import urllib.parse


def discover_vault(prefs):
    override = (prefs.get("vault_path") or "").strip()
    if override and os.path.isdir(os.path.expanduser(override)):
        return os.path.expanduser(override)
    cfg = os.path.expanduser("~/Library/Application Support/obsidian/obsidian.json")
    if os.path.isfile(cfg):
        try:
            data = json.load(open(cfg, "r", encoding="utf-8"))
            vaults = list((data.get("vaults") or {}).values())
            vaults.sort(key=lambda v: (bool(v.get("open")), v.get("ts", 0)), reverse=True)
            for v in vaults:
                p = v.get("path")
                if p and os.path.isdir(p):
                    return p
        except Exception:
            pass
    return None


def main():
    try:
        ctx = json.loads(sys.stdin.read().strip() or "{}")
    except Exception:
        ctx = {}
    vault = discover_vault(ctx.get("preferences") or {})
    today = datetime.date.today().strftime("%Y-%m-%d")
    if not vault:
        print(json.dumps({"detail": {"markdown": f"### Daily Note ({today})\nConfigure your vault path in Pack Preferences."}}))
        return

    found = None
    for root, dirs, names in os.walk(vault):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        if f"{today}.md" in names:
            found = os.path.join(root, f"{today}.md")
            break

    obsidian_url = "obsidian://daily" if not found else "obsidian://open?path=" + urllib.parse.quote(found)
    content = open(found, "r", encoding="utf-8", errors="replace").read(4000) if found else f"Daily note `{today}.md` not created yet. Press `↵` to open Daily Note in Obsidian."
    print(json.dumps({
        "items": [{
            "id": today,
            "title": f"Daily Note — {today}",
            "subtitle": found or "Open or create in Obsidian",
            "icon": "calendar",
            "actions": [
                {"id": "open-daily", "title": "Open Daily Note in Obsidian", "icon": "book.closed.fill", "shortcut": "↵", "kind": "open", "value": obsidian_url}
            ]
        }],
        "detail": {
            "markdown": content,
            "metadata": [
                {"label": "Date", "value": today, "color": "#A855F7"},
                {"label": "Vault", "value": os.path.basename(vault)},
            ]
        }
    }))


if __name__ == "__main__":
    main()
