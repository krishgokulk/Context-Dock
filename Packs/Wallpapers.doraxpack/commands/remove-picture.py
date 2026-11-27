#!/usr/bin/env python3
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wallpaper_lib as wl


def main() -> None:
    target = (os.environ.get("DORAX_ACTION_VALUE") or os.environ.get("DORAX_ITEM_ID") or "").strip()
    if not target:
        print("Missing image path", file=sys.stderr)
        sys.exit(1)

    col_real = os.path.realpath(wl.COLLECTION_DIR)
    tgt_real = os.path.realpath(target)
    if not (tgt_real.startswith(col_real + os.sep) and os.path.isfile(tgt_real)):
        print("Only pictures in your Added Pictures collection can be removed here.", file=sys.stderr)
        sys.exit(1)

    name = os.path.basename(tgt_real)
    os.remove(tgt_real)
    print(f"Removed {name}")


if __name__ == "__main__":
    main()
