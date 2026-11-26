#!/usr/bin/env python3
import json
import os
import sys


def main():
    try:
        ctx = json.loads(sys.stdin.read().strip() or "{}")
    except Exception:
        ctx = {}
    q = (ctx.get("query") or "").strip().lower()
    cfg = os.path.expanduser("~/Library/Application Support/obsidian/obsidian.json")
    vault = None
    if os.path.isfile(cfg):
        try:
            vaults = list((json.load(open(cfg)).get("vaults") or {}).values())
            vault = vaults[0].get("path") if vaults else None
        except Exception:
            pass
    if not vault or not os.path.isdir(vault):
        print("No Obsidian vault configured.")
        return
    hits = []
    for root, dirs, names in os.walk(vault):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for name in names:
            if name.endswith(".md") and (not q or q in name.lower()):
                hits.append(f"- {os.path.relpath(os.path.join(root, name), vault)}")
                if len(hits) >= 12:
                    break
        if len(hits) >= 12:
            break
    print("\n".join(hits) if hits else f"No Obsidian notes matched \"{q}\".")


if __name__ == "__main__":
    main()
