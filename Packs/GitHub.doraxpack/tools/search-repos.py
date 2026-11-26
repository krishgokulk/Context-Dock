#!/usr/bin/env python3
import json
import shutil
import subprocess
import sys


def main():
    try:
        ctx = json.loads(sys.stdin.read().strip() or "{}")
    except Exception:
        ctx = {}
    q = (ctx.get("query") or "").strip()
    if not q:
        print("Pass a repository query, e.g. @github.search-repos swiftui")
        return
    gh = shutil.which("gh") or "/opt/homebrew/bin/gh"
    proc = subprocess.run(
        [gh, "search", "repos", q, "--limit", "8", "--json", "fullName,description,url,stargazersCount"],
        capture_output=True, text=True, timeout=8
    )
    if proc.returncode != 0:
        print((proc.stderr or "gh search repos failed").strip()[:400])
        return
    rows = json.loads(proc.stdout or "[]")
    lines = [f"- {r.get('fullName')} (★ {r.get('stargazersCount', 0)}) — {r.get('url')}" for r in rows]
    print("\n".join(lines) if lines else f"No GitHub repos matched \"{q}\".")


if __name__ == "__main__":
    main()
