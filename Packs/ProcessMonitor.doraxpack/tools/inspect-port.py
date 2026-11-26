#!/usr/bin/env python3
import json
import os
import subprocess
import sys

def main():
    raw = sys.stdin.read().strip()
    ctx = json.loads(raw) if raw else {}
    query = str(ctx.get("query") or os.environ.get("DORAX_QUERY") or "").strip()
    digits = "".join(ch for ch in query if ch.isdigit())
    args = ["/usr/sbin/lsof", "-nP", f"-iTCP:{digits}", "-sTCP:LISTEN"] if digits else ["/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN"]
    try:
        out = subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        out = ""
    print(out if out else f"No listening TCP process found for port {digits or 'any'}.")

if __name__ == "__main__":
    main()
