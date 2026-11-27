#!/usr/bin/env python3
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wallpaper_lib as wl


def main() -> None:
    ctx = wl.read_context()
    prefs = ctx.get("preferences") or {}
    scope = (prefs.get("apply_scope") or "all").strip() or "all"
    target = (os.environ.get("DORAX_ACTION_VALUE") or os.environ.get("DORAX_ITEM_ID") or "").strip()

    if target in ("__next__", "__random__"):
        _, entries = wl.resolve_folder_and_entries(ctx)
        if not entries:
            print("No wallpapers found", file=sys.stderr)
            sys.exit(1)
        idx = wl.pick_next_index(entries, wl.get_current_wallpaper(), random_mode=(target == "__random__"))
        target = entries[idx]["path"]

    if not target or not os.path.isfile(target):
        print(f"Wallpaper not found: {target}", file=sys.stderr)
        sys.exit(1)

    wl.apply_wallpaper(target, scope=scope)
    print(f"Wallpaper set to {os.path.basename(target)}")


if __name__ == "__main__":
    main()
