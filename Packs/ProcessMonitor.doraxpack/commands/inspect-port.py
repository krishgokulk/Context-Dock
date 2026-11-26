#!/usr/bin/env python3
import json
import os
import subprocess
import sys

def main():
    ctx_raw = sys.stdin.read().strip()
    ctx = {}
    if ctx_raw:
        try:
            ctx = json.loads(ctx_raw)
        except Exception:
            ctx = {}

    form = ctx.get("formValues") or {}
    port = str(form.get("port") or os.environ.get("DORAX_FORM_PORT") or ctx.get("query") or "").strip()
    if not port.isdigit():
        print(json.dumps({
            "detail": {
                "markdown": "### Enter a valid numeric TCP port\nFor example: `3000`, `5173`, `8000`, or `8080`.",
                "metadata": [{"label": "Input", "value": port or "(empty)"}],
            }
        }))
        return

    try:
        out = subprocess.check_output(
            ["/usr/sbin/lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except Exception:
        out = ""

    if not out or len(out.splitlines()) <= 1:
        print(json.dumps({
            "detail": {
                "markdown": f"### Port `{port}` is free\nNo process is currently listening on TCP port `{port}`.",
                "metadata": [
                    {"label": "Port", "value": port, "color": "#34D399"},
                    {"label": "Status", "value": "Available", "color": "#34D399"},
                ],
            }
        }))
        return

    lines = out.splitlines()
    parts = lines[1].split()
    proc = parts[0] if len(parts) > 0 else "unknown"
    pid = parts[1] if len(parts) > 1 else "?"
    user = parts[2] if len(parts) > 2 else "?"
    print(json.dumps({
        "detail": {
            "markdown": f"### Port `{port}` is in use by **{proc}**\n\n```\n{out}\n```",
            "metadata": [
                {"label": "Process", "value": proc},
                {"label": "PID", "value": pid},
                {"label": "User", "value": user},
                {"label": "Port", "value": port, "color": "#F59E0B"},
            ],
        }
    }))

if __name__ == "__main__":
    main()
