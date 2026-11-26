#!/usr/bin/env python3
import json
import os
import re
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
    icloud = os.path.expanduser("~/Library/Mobile Documents/iCloud~md~obsidian/Documents")
    return icloud if os.path.isdir(icloud) else None


def main():
    try:
        ctx = json.loads(sys.stdin.read().strip() or "{}")
    except Exception:
        ctx = {}
    form = ctx.get("formValues") or {}
    title = (form.get("title") or "").strip()
    folder = (form.get("folder") or "").strip().strip("/")
    content = (form.get("content") or "").strip()

    vault = discover_vault(ctx.get("preferences") or {})
    if not vault:
        print(json.dumps({"detail": {"markdown": "### Obsidian Vault Not Found\nSet Vault Path Override in Pack Preferences."}}))
        return
    if not title:
        print(json.dumps({"empty_message": "Enter a Note Title to save into your Obsidian vault."}))
        return

    safe_name = re.sub(r'[/:\\]+', '-', title).strip() + ".md"
    target_dir = os.path.join(vault, folder) if folder else vault
    # Ensure path stays inside vault
    real_vault = os.path.realpath(vault)
    real_dir = os.path.realpath(target_dir)
    if not real_dir.startswith(real_vault):
        print(json.dumps({"detail": {"markdown": "### Invalid Folder\nTarget folder must stay inside the vault."}}))
        return

    os.makedirs(real_dir, exist_ok=True)
    note_path = os.path.join(real_dir, safe_name)
    existed = os.path.exists(note_path)
    with open(note_path, "a" if existed else "w", encoding="utf-8") as fh:
        if existed and content:
            fh.write("\n\n" + content)
        elif not existed:
            fh.write(f"# {title}\n\n{content}\n" if content else f"# {title}\n")

    obsidian_url = "obsidian://open?path=" + urllib.parse.quote(note_path)
    rel = os.path.relpath(note_path, real_vault)
    print(json.dumps({
        "items": [{
            "id": note_path,
            "title": f"{'Appended to' if existed else 'Created'}: {safe_name}",
            "subtitle": rel,
            "icon": "checkmark.circle.fill",
            "actions": [
                {"id": "open", "title": "Open in Obsidian", "icon": "book.closed.fill", "shortcut": "↵", "kind": "open", "value": obsidian_url},
                {"id": "reveal", "title": "Reveal in Finder", "icon": "folder", "kind": "reveal", "value": note_path},
            ]
        }],
        "detail": {
            "markdown": f"### {'Appended' if existed else 'Created'} Obsidian Note\n\n**Path:** `{rel}`\n\n{content}",
            "metadata": [{"label": "Vault", "value": os.path.basename(real_vault), "color": "#A855F7"}]
        },
        "toast": f"Saved {safe_name} to Obsidian"
    }))


if __name__ == "__main__":
    main()
