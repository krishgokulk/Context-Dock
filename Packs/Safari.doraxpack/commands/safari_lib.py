#!/usr/bin/env python3
"""Shared Python 3.9 helpers for Packs/Safari.doraxpack commands."""

from __future__ import annotations

import datetime
import json
import os
import plistlib
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import urllib.parse


def read_context() -> dict:
    try:
        raw = sys.stdin.read().strip()
        return json.loads(raw) if raw else {}
    except Exception:
        return {}


def get_query_and_filter(ctx: dict) -> tuple[str, str]:
    q = (os.environ.get("DORAX_QUERY") or ctx.get("query") or "").strip().lower()
    flt = (os.environ.get("DORAX_FILTER") or ctx.get("filter") or "").strip()
    return q, flt


def domain_of(url: str) -> str:
    try:
        host = urllib.parse.urlparse(url).netloc
        return host.removeprefix("www.") if hasattr(host, "removeprefix") else host.replace("www.", "", 1)
    except Exception:
        return ""


def standard_url_actions(url: str, title: str) -> list[dict]:
    md_link = f"[{title or url}]({url})"
    return [
        {
            "id": "open-safari",
            "title": "Open in Safari",
            "icon": "safari",
            "shortcut": "↵",
            "kind": "script",
            "script": "commands/tab-action.py",
            "value": f"open:{url}",
        },
        {
            "id": "copy-url",
            "title": "Copy URL",
            "icon": "link",
            "shortcut": "⌘C",
            "kind": "copy",
            "value": url,
        },
        {
            "id": "copy-md",
            "title": "Copy Markdown Link",
            "icon": "doc.on.clipboard",
            "shortcut": "⌘⇧C",
            "kind": "copy",
            "value": md_link,
        },
        {
            "id": "add-rl",
            "title": "Add to Reading List",
            "icon": "eyeglasses",
            "shortcut": "⌘R",
            "kind": "script",
            "script": "commands/tab-action.py",
            "value": f"reading-list:{url}",
        },
    ]


def permission_action_item(message: str) -> dict:
    url = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    return {
        "id": "grant-fda",
        "title": "Grant Full Disk Access for Safari Data",
        "subtitle": message,
        "icon": "lock.shield",
        "accessories": [{"kind": "badge", "text": "Settings", "color": "#F59E0B"}],
        "detail": {
            "markdown": f"### Full Disk Access Required\n\n{message}\n\nPress `↵` to open **System Settings -> Privacy & Security -> Full Disk Access**, enable **Context-Dock**, then click Refresh (`↻`).",
            "metadata": [{"label": "Privacy", "value": "Full Disk Access", "color": "#F59E0B"}],
        },
        "actions": [
            {
                "id": "open-fda",
                "title": "Open Full Disk Access Settings",
                "icon": "gearshape.fill",
                "shortcut": "↵",
                "kind": "open",
                "value": url,
            }
        ],
    }


def frontmost_safari_tab() -> tuple[str, str]:
    script = """
    if application "Safari" is running then
        tell application "Safari"
            if (count of windows) > 0 then
                set t to current tab of front window
                return (name of t) & "\t" & (URL of t)
            end if
        end tell
    end if
    return ""
    """
    try:
        res = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=4)
        line = res.stdout.strip()
        if "\t" in line:
            title, url = line.split("\t", 1)
            return title.strip(), url.strip()
    except Exception:
        pass
    return "", ""


def list_open_tabs() -> list[dict]:
    script = """
    if application "Safari" is not running then return ""
    tell application "Safari"
        set outLines to {}
        set winCount to count of windows
        repeat with wIdx from 1 to winCount
            try
                set w to window wIdx
                set activeIdx to index of current tab of w
                set tabCount to count of tabs of w
                repeat with tIdx from 1 to tabCount
                    set t to tab tIdx of w
                    set tURL to ""
                    set tName to ""
                    try
                        set tURL to (URL of t) as string
                    end try
                    try
                        set tName to (name of t) as string
                    end try
                    if tURL is not "" then
                        set end of outLines to (wIdx as string) & "\t" & (tIdx as string) & "\t" & ((tIdx is activeIdx) as string) & "\t" & tName & "\t" & tURL
                    end if
                end repeat
            end try
        end repeat
        set AppleScript's text item delimiters to "\n"
        return outLines as string
    end tell
    """
    try:
        res = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=5)
        if res.returncode != 0:
            return []
        tabs = []
        for row in res.stdout.splitlines():
            parts = row.split("\t")
            if len(parts) < 5:
                continue
            w_idx, t_idx, is_active, title, url = parts[0], parts[1], parts[2] == "true", parts[3], parts[4]
            tabs.append({
                "window": int(w_idx),
                "tab": int(t_idx),
                "is_current_window": w_idx == "1",
                "is_active": is_active and w_idx == "1",
                "title": title.strip() or domain_of(url) or url,
                "url": url.strip(),
            })
        return tabs
    except Exception:
        return []


def _bookmarks_plist() -> dict | None:
    path = os.path.expanduser("~/Library/Safari/Bookmarks.plist")
    with open(path, "rb") as f:
        return plistlib.load(f)


def list_bookmarks() -> tuple[list[dict], str | None]:
    try:
        root = _bookmarks_plist()
    except PermissionError:
        return [], "Full Disk Access required in System Settings to read Safari Bookmarks."
    except Exception as exc:
        return [], str(exc)

    results: list[dict] = []

    def walk(node: dict, folder_path: str) -> None:
        title = (node.get("Title") or "").strip()
        if title == "com.apple.ReadingList":
            return
        wtype = node.get("WebBookmarkType")
        if wtype == "WebBookmarkTypeLeaf":
            url = (node.get("URLString") or "").strip()
            leaf_title = ((node.get("URIDictionary") or {}).get("title") or title or url).strip()
            if url:
                results.append({
                    "title": leaf_title,
                    "url": url,
                    "folder": folder_path or "Bookmarks",
                })
        next_folder = folder_path
        if wtype == "WebBookmarkTypeList" and title and title not in ("BookmarksBar", "BookmarksMenu"):
            nice = title.replace("BookmarksBar", "Favorites").replace("BookmarksMenu", "Menu")
            next_folder = f"{folder_path}/{nice}" if folder_path else nice
        elif title == "BookmarksBar":
            next_folder = "Favorites"
        for child in node.get("Children") or []:
            if isinstance(child, dict):
                walk(child, next_folder)

    if isinstance(root, dict):
        walk(root, "")
    return results, None


def list_reading_list() -> tuple[list[dict], str | None]:
    try:
        root = _bookmarks_plist()
    except PermissionError:
        return [], "Full Disk Access required in System Settings to read Safari Reading List."
    except Exception as exc:
        return [], str(exc)

    items: list[dict] = []

    def find_rl(node: dict) -> dict | None:
        if (node.get("Title") or "") == "com.apple.ReadingList":
            return node
        for child in node.get("Children") or []:
            if isinstance(child, dict):
                found = find_rl(child)
                if found:
                    return found
        return None

    rl_node = find_rl(root) if isinstance(root, dict) else None
    if rl_node:
        for child in rl_node.get("Children") or []:
            if not isinstance(child, dict):
                continue
            url = (child.get("URLString") or "").strip()
            if not url:
                continue
            title = ((child.get("URIDictionary") or {}).get("title") or child.get("Title") or url).strip()
            rl_meta = child.get("ReadingList") or {}
            preview = (rl_meta.get("PreviewText") or "").strip()
            date_last_viewed = rl_meta.get("DateLastViewed")
            is_read = date_last_viewed is not None
            date_added = rl_meta.get("DateAdded")
            added_str = date_added.strftime("%Y-%m-%d") if isinstance(date_added, datetime.datetime) else ""
            items.append({
                "title": title,
                "url": url,
                "preview": preview,
                "is_read": is_read,
                "added": added_str,
            })
    return items, None


def list_history(limit: int = 250) -> tuple[list[dict], str | None]:
    db_path = os.path.expanduser("~/Library/Safari/History.db")
    if not os.path.isfile(db_path):
        return [], "Safari History.db not found."
    tmp_path = ""
    try:
        fd, tmp_path = tempfile.mkstemp(prefix="dorax-safari-hist-", suffix=".db")
        os.close(fd)
        shutil.copy2(db_path, tmp_path)
        for suffix in ("-wal", "-shm"):
            side = db_path + suffix
            if os.path.exists(side):
                shutil.copy2(side, tmp_path + suffix)
        con = sqlite3.connect(tmp_path)
        sql = """
            SELECT hi.url,
                   COALESCE(NULLIF(hv.title, ''), hi.url) AS title,
                   MAX(hv.visit_time) AS last_visit,
                   COUNT(*) AS visits
            FROM history_items hi
            JOIN history_visits hv ON hv.history_item = hi.id
            GROUP BY hi.id
            ORDER BY last_visit DESC
            LIMIT ?
        """
        rows = con.execute(sql, (limit,)).fetchall()
        con.close()
        out = []
        cocoa_epoch = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)
        for url, title, last_visit, visits in rows:
            ts = cocoa_epoch + datetime.timedelta(seconds=float(last_visit or 0))
            out.append({
                "url": url,
                "title": (title or url).strip(),
                "visited": ts.astimezone().strftime("%b %d · %H:%M"),
                "visits": int(visits or 1),
            })
        return out, None
    except PermissionError:
        return [], "Full Disk Access required in System Settings to read Safari History."
    except Exception as exc:
        return [], str(exc)
    finally:
        for p in (tmp_path, tmp_path + "-wal", tmp_path + "-shm"):
            if p and os.path.exists(p):
                try:
                    os.unlink(p)
                except Exception:
                    pass
