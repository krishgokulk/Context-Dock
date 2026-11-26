#!/usr/bin/env python3
import datetime
import json
import os
import sys
import time
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
    icloud = os.path.expanduser("~/Library/Mobile Documents/iCloud~md~obsidian/Documents")
    return icloud if os.path.isdir(icloud) else None


def main():
    try:
        ctx = json.loads(sys.stdin.read().strip() or "{}")
    except Exception:
        ctx = {}
    vault = discover_vault(ctx.get("preferences") or {})
    if not vault:
        print(json.dumps({
            "detail": {"markdown": "### Obsidian Vault Not Found\nConfigure **Vault Path Override** in Pack Preferences (`⌘K → Configure Command & Pack`)."}
        }))
        return

    q = (ctx.get("query") or "").strip().lower()
    files = []
    started = time.monotonic()
    for root, dirs, names in os.walk(vault):
        dirs[:] = [d for d in dirs if not d.startswith(".") and d not in ("node_modules", "attachments", "Assets")]
        for name in names:
            if name.startswith(".") or not name.lower().endswith(".md"):
                continue
            full = os.path.join(root, name)
            try:
                st = os.stat(full)
                # Skip iCloud dataless / evicted placeholders so listing stays instant
                if getattr(st, "st_blocks", 1) == 0 and st.st_size > 0:
                    continue
            except Exception:
                continue
            files.append((st.st_mtime, full, name))
            if len(files) >= 200 or (time.monotonic() - started) > 0.9:
                break
        if len(files) >= 200 or (time.monotonic() - started) > 0.9:
            break

    files.sort(key=lambda x: x[0], reverse=True)
    items = []
    for mtime, full, name in files[:25]:
        rel = os.path.relpath(full, vault)
        folder = os.path.dirname(rel) or "Root"
        stem = os.path.splitext(name)[0]
        if q and q not in stem.lower() and q not in rel.lower():
            continue
        try:
            body = open(full, "r", encoding="utf-8", errors="replace").read(1500)
        except Exception:
            body = ""
        words = len(body.split())
        date_str = datetime.datetime.fromtimestamp(mtime).strftime("%Y-%m-%d")
        obsidian_url = "obsidian://open?path=" + urllib.parse.quote(full)
        items.append({
            "id": rel,
            "title": stem,
            "subtitle": rel,
            "icon": "doc.text.fill",
            "category": folder,
            "accessories": [
                {"kind": "tag", "text": folder[:14], "color": "#A855F7"},
                {"kind": "metric", "text": f"{words}w"}
            ],
            "detail": {
                "markdown": body.strip() or f"*Empty note:* `{rel}`",
                "metadata": [
                    {"label": "Folder", "value": folder, "color": "#A855F7"},
                    {"label": "Modified", "value": date_str},
                    {"label": "Words", "value": str(words)},
                ]
            },
            "actions": [
                {"id": "open-obsidian", "title": "Open in Obsidian", "icon": "book.closed.fill", "shortcut": "↵", "kind": "open", "value": obsidian_url},
                {"id": "reveal", "title": "Reveal in Finder", "icon": "folder", "shortcut": "⌘R", "kind": "reveal", "value": full},
                {"id": "copy-wiki", "title": "Copy [[Wikilink]]", "icon": "link", "shortcut": "⌘C", "kind": "copy", "value": f"[[{stem}]]"},
                {"id": "copy-md", "title": "Copy Note Content", "icon": "doc.on.doc", "kind": "copy", "value": body},
            ]
        })

    print(json.dumps({
        "items": items[:35],
        "empty_message": f"No Markdown notes found in {os.path.basename(vault)}."
    }))


if __name__ == "__main__":
    main()
