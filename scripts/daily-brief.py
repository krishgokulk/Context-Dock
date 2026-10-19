#!/usr/bin/env python3
"""daily-brief.py — the one screen to read before starting work.

Builds today's brief from what already exists, so no chat has to remember anything:
  docs/master/00-NOW.md   in progress, hand-check queue, next in order
  MEMORY.md               where the last sessions stopped
  GitHub (gh)             open PRs, hand-check labels, which PRs 00-NOW doesn't know about
  git                     worktrees left behind, how stale graphify-out is

    ./scripts/daily-brief.py            # print the brief (markdown)
    ./scripts/daily-brief.py --sizes    # also measure each worktree (slow: du over GBs)

Read-only: it never edits, commits, merges or deletes. Standard library only.
"""
import json, os, re, shutil, subprocess, sys, time
from datetime import date, datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOW_MD = os.path.join(ROOT, "docs/master/00-NOW.md")
MEMORY_MD = os.path.join(ROOT, "MEMORY.md")
GRAPH = os.path.join(ROOT, "graphify-out/graph.json")
SIZES = "--sizes" in sys.argv


def run(*cmd):
    try:
        out = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=60)
        return out.stdout if out.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def section(text, title):
    """Body of a '## <title>' section, up to the next '## '."""
    m = re.search(r"^## " + re.escape(title) + r".*?$(.*?)(?=^## |\Z)", text, re.M | re.S)
    return m.group(1).strip() if m else ""


def days_since(ts):
    return int((time.time() - ts) // 86400)


now_text = read(NOW_MD)
mem_lines = [l.strip() for l in read(MEMORY_MD).splitlines() if re.match(r"^(- )?20\d\d-\d\d-\d\d", l.strip())]
now_commit = run("git", "log", "-1", "--format=%ct", "--", "docs/master/00-NOW.md").strip()

print(f"# Today · {date.today():%a %d %b %Y}\n")

# 1. Where we stopped ----------------------------------------------------------------------
print("## Where the last sessions stopped\n")
for line in mem_lines[-4:] or ["(MEMORY.md has no entries)"]:
    print(f"- {line.lstrip('- ')[:240]}")
print()

# 2. Open PRs ------------------------------------------------------------------------------
prs = []
if shutil.which("gh"):
    raw = run("gh", "pr", "list", "--state", "open", "--limit", "50", "--json",
              "number,title,headRefName,isDraft,labels,body,statusCheckRollup")
    try:
        prs = json.loads(raw) if raw else []
    except json.JSONDecodeError:
        prs = []

needs_check, ready, other = [], [], []
if prs:
    print("## Open PRs\n")
    print("| PR | Branch | CI | Hand-check | Next |\n| --- | --- | --- | --- | --- |")
    for p in sorted(prs, key=lambda p: p["number"]):
        labels = {l["name"] for l in p.get("labels", [])}
        checks = p.get("statusCheckRollup") or []
        states = {(c.get("conclusion") or c.get("state") or "").upper() for c in checks}
        ci = "fail" if states & {"FAILURE", "ERROR", "CANCELLED"} else "pass" if states and states <= {"SUCCESS", "NEUTRAL", "SKIPPED"} else ("running" if checks else "—")
        # The repo's own convention (.claude/commands/builder.md): the PR body's first line says
        # "Hand check: required" or "Hand check: optional — why"; passes are recorded in 00-NOW.md.
        body = p.get("body") or ""
        passed = bool(re.search(r"#%d\b[^\n]*passed|\b%d passed" % (p["number"], p["number"]), now_text))
        if passed:
            hc, nxt = "passed", "mark ready → CI → merge" if p.get("isDraft") else "merge"
            ready.append(p)
        elif re.search(r"Hand check:\s*required", body, re.I):
            hc, nxt = "required", "test it: ./scripts/try-pr.sh %d" % p["number"]
            needs_check.append(p)
        elif re.search(r"Hand check:\s*optional", body, re.I):
            hc, nxt = "optional", "merge on \"merge %d\"" % p["number"] if ci == "pass" else "wait for CI"
            ready.append(p)
        else:
            hc, nxt = "—", "fix CI" if ci == "fail" else ("draft" if p.get("isDraft") else "review")
            other.append(p)
        title = p["title"].replace("|", "/")[:60]
        print(f"| #{p['number']} {title} | `{p['headRefName']}` | {ci} | {hc} | {nxt} |")
    print()
else:
    print("## Open PRs\n\n(gh not available here — run this on the Mac to see them)\n")

# 3. 00-NOW --------------------------------------------------------------------------------
queue = section(now_text, "Hand-check queue")
print("## Hand-check queue (00-NOW)\n")
print((queue.splitlines()[0] if queue else "(section missing)") + "\n")

state = section(now_text, "In progress")
nxt = [l.strip() for l in state.splitlines() if l.strip().startswith("- Next:")]
if nxt:
    print("## Next in order (00-NOW)\n")
    print(nxt[0][2:] + "\n")

# 4. Start here ----------------------------------------------------------------------------
print("## Start here\n")
if needs_check:
    print(f"1. Hand-check #{needs_check[0]['number']}: `./scripts/try-pr.sh {needs_check[0]['number']}`, then tell the planner \"{needs_check[0]['number']} passed\".")
elif ready:
    print(f"1. Say \"merge N\" to the planner for: {', '.join('#%d' % p['number'] for p in ready)}; then ./scripts/main.sh.")
elif nxt:
    print("1. " + re.sub(r"^- Next:\s*", "", nxt[0]))
else:
    print("1. Pick the first item under *Next, in order* in 00-NOW.md.")
print()

# 5. Drift: things that only live in chat, or have gone stale ------------------------------
print("## Drift and housekeeping\n")
if now_commit:
    print(f"- 00-NOW.md last updated {days_since(int(now_commit))} day(s) ago.")
if prs:
    missing = [p["number"] for p in prs if not re.search(r"#%d\b" % p["number"], now_text)]
    if missing:
        print(f"- Open PRs 00-NOW doesn't mention (their state lives only in chat): {', '.join('#%d' % n for n in missing)}.")
if os.path.exists(GRAPH):
    age = days_since(os.path.getmtime(GRAPH))
    since = datetime.fromtimestamp(os.path.getmtime(GRAPH)).strftime("%Y-%m-%d")
    behind = run("git", "rev-list", "--count", f"--since={since}", "HEAD").strip() or "?"
    snaps = [d for d in os.listdir(os.path.dirname(GRAPH)) if re.match(r"\d{4}-\d\d-\d\d$", d)]
    print(f"- graphify graph is {age} day(s) old, ~{behind} commits behind; {len(snaps)} dated snapshots kept."
          + (" Run `graphify update .`." if age > 3 else ""))
wts = [l[9:] for l in run("git", "worktree", "list", "--porcelain").splitlines() if l.startswith("worktree ")][1:]
if wts:
    merged = set()
    if shutil.which("gh"):
        try:
            merged = {p["headRefName"] for p in json.loads(run("gh", "pr", "list", "--state", "merged", "--limit", "200", "--json", "headRefName") or "[]")}
        except json.JSONDecodeError:
            pass
    stale = []
    for wt in wts:
        br = run("git", "-C", wt, "branch", "--show-current").strip()
        if br and br in merged:
            stale.append((wt, br))
    print(f"- {len(wts)} worktrees besides main" + (f"; {len(stale)} belong to merged PRs and can go (`git worktree remove <path>`)." if merged else "."))
    for wt, br in stale[:10]:
        print(f"    - `{os.path.relpath(wt, ROOT)}` ({br})")
    if SIZES:
        total = 0
        for wt in wts:
            kb = run("du", "-sk", wt).split()
            total += int(kb[0]) if kb else 0
        print(f"- Worktrees use {total / 1048576:.1f} GB.")
