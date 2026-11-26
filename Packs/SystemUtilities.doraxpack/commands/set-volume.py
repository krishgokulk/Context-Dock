#!/usr/bin/env python3
import os
import subprocess
import sys


def main():
    val = os.environ.get("DORAX_ACTION_VALUE", "").strip()
    if val == "mute-toggle":
        script = "set cur to output muted of (get volume settings)\nset volume output muted (not cur)"
    elif val.startswith("+"):
        step = int(val[1:])
        script = f"set cur to output volume of (get volume settings)\nset volume output volume (min of {{100, cur + {step}}}) output muted false"
    elif val.startswith("-"):
        step = int(val[1:])
        script = f"set cur to output volume of (get volume settings)\nset volume output volume (max of {{0, cur - {step}}})"
    else:
        pct = max(0, min(100, int(val)))
        script = f"set volume output volume {pct} output muted false"
    subprocess.run(["/usr/bin/osascript", "-e", script], check=True, timeout=4)
    print(f"Volume updated ({val})")


if __name__ == "__main__":
    main()
