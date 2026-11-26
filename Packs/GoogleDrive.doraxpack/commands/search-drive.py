#!/usr/bin/env python3
import datetime
import glob
import json
import os
import sys
import urllib.parse


def format_size(num):
    if num < 1024:
        return f"{num} B"
    if num < 1024 * 1024:
        return f"{num // 1024} KB"
    return f"{num / (1024 * 1024):.1f} MB"


def main():
    try:
        ctx = json.loads(sys.stdin.read().strip() or "{}")
    except Exception:
        ctx = {}
    q = (ctx.get("query") or "").strip().lower()

    roots = sorted(glob.glob(os.path.expanduser("~/Library/CloudStorage/GoogleDrive-*")))
    if not roots:
        print(json.dumps({
            "detail": {"markdown": "### Google Drive Local Sync Not Found\nNo `~/Library/CloudStorage/GoogleDrive-*` folders were detected. Open **Google Drive** to sign in or use **Google Drive Quick Actions** for web access."}
        }))
        return

    found = []
    max_scanned = 450
    for account_root in roots:
        account = os.path.basename(account_root).replace("GoogleDrive-", "")
        base_depth = account_root.rstrip(os.sep).count(os.sep)
        for cur_root, dirs, names in os.walk(account_root):
            depth = cur_root.rstrip(os.sep).count(os.sep) - base_depth
            dirs[:] = [d for d in dirs if not d.startswith(".") and depth < 4]
            for name in names:
                if name.startswith("."):
                    continue
                if q and q not in name.lower():
                    continue
                full = os.path.join(cur_root, name)
                try:
                    st = os.stat(full)
                except Exception:
                    continue
                found.append((st.st_mtime, st.st_size, account, full, name))
                if len(found) >= max_scanned:
                    break
            if len(found) >= max_scanned:
                break

    found.sort(key=lambda x: x[0], reverse=True)
    items = []
    accounts = sorted({r[2] for r in found})
    for mtime, size, account, full, name in found[:40]:
        ext = os.path.splitext(name)[1].lstrip(".").upper() or "FILE"
        date_str = datetime.datetime.fromtimestamp(mtime).strftime("%Y-%m-%d")
        file_url = "file://" + urllib.parse.quote(full)
        rel = os.path.dirname(full).split(f"GoogleDrive-{account}")[-1].strip("/") or "Root"
        items.append({
            "id": full,
            "title": name,
            "subtitle": f"{account} · {rel}",
            "icon": "doc.fill",
            "app_icon_bundle_id": "com.google.drivefs",
            "category": account,
            "accessories": [
                {"kind": "tag", "text": ext[:8], "color": "#4285F4"},
                {"kind": "metric", "text": format_size(size)}
            ],
            "detail": {
                "markdown": f"### {name}\n\n**Account:** `{account}`\n\n**Folder:** `{rel}`\n\n**Path:** `{full}`",
                "metadata": [
                    {"label": "Account", "value": account, "color": "#4285F4"},
                    {"label": "Size", "value": format_size(size)},
                    {"label": "Modified", "value": date_str},
                ]
            },
            "actions": [
                {"id": "open", "title": "Open File", "icon": "arrow.up.right.square", "shortcut": "↵", "kind": "open", "value": file_url},
                {"id": "reveal", "title": "Reveal in Finder", "icon": "folder", "shortcut": "⌘R", "kind": "reveal", "value": full},
                {"id": "copy-path", "title": "Copy Path", "icon": "doc.on.doc", "shortcut": "⌘C", "kind": "copy", "value": full},
                {"id": "web-search", "title": "Search on Drive Web", "icon": "safari", "kind": "open", "value": "https://drive.google.com/drive/search?q=" + urllib.parse.quote(name)},
            ]
        })

    print(json.dumps({
        "items": items,
        "filter_options": (["All"] + accounts) if len(accounts) > 1 else None,
        "empty_message": "No synced Google Drive files matched."
    }))


if __name__ == "__main__":
    main()
