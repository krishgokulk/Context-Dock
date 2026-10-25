#!/usr/bin/env python3
"""daily-brief.py — the one screen to read before starting work.

Builds today's brief from what already exists, so no chat has to remember anything:
  git (all branches)      what moved since yesterday — every tool: Claude, Codex, OpenCode, you
  git (all worktrees)     what is still uncommitted and in-flight, per worktree
  docs/master/00-NOW.md   in progress, hand-check queue, next in order
  MEMORY.md               where the last sessions stopped
  GitHub (gh)             open PRs, hand-check labels, which PRs 00-NOW doesn't know about
  git                     worktrees left behind, how stale graphify-out is

    ./scripts/daily-brief.py                 # print the brief (markdown)
    ./scripts/daily-brief.py --since "4 days ago"   # widen the activity window (default: 2 days ago)
    ./scripts/daily-brief.py --sizes         # also measure each worktree (slow: du over GBs)

Read-only: it never edits, commits, merges or deletes. Standard library only.

Why the git layers: work happens across ~25 worktrees and many branches (Claude in
.claude/worktrees, Codex in ~/.codex/worktrees, OpenCode branches, detached heads).
Reading only the current HEAD makes a day of work on another branch look like "nothing
happened". `git log --all` + a per-worktree status scan is what makes every tool's work show.
CHANGES.md is deliberately NOT read: its auto-journal has stalled and lies about recency.
"""
import json, os, re, shutil, subprocess, sys, time
from datetime import date, datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOW_MD = os.path.join(ROOT, "docs/master/00-NOW.md")
MEMORY_MD = os.path.join(ROOT, "MEMORY.md")
GRAPH = os.path.join(ROOT, "graphify-out/graph.json")
SIZES = "--sizes" in sys.argv
HOME = os.path.expanduser("~")


def arg_value(flag, default):
    for i, a in enumerate(sys.argv):
        if a == flag and i + 1 < len(sys.argv):
            return sys.argv[i + 1]
        if a.startswith(flag + "="):
            return a.split("=", 1)[1]
    return default


SINCE = arg_value("--since", "2 days ago")


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


def lines(text):
    return [l for l in text.splitlines() if l.strip()]


def section(text, title):
    """Body of a '## <title>' section, up to the next '## '."""
    m = re.search(r"^## " + re.escape(title) + r".*?$(.*?)(?=^## |\Z)", text, re.M | re.S)
    return m.group(1).strip() if m else ""


def days_since(ts):
    return int((time.time() - ts) // 86400)


def short(p):
    return p.replace(HOME, "~")


def who_of(author):
    return "you" if author.upper().startswith("GOKULA") else author


now_text = read(NOW_MD)
mem_lines = [l.strip() for l in read(MEMORY_MD).splitlines() if re.match(r"^(- )?20\d\d-\d\d-\d\d", l.strip())]
now_commit = run("git", "log", "-1", "--format=%ct", "--", "docs/master/00-NOW.md").strip()

print(f"# Today · {date.today():%a %d %b %Y}\n")

# 0. What moved since <since> — every branch, every tool ----------------------------------
print(f"## What moved since {SINCE} — every branch, every tool\n")
raw = run("git", "log", "--all", "--no-merges", f"--since={SINCE}",
          "--pretty=format:%h\x1f%an\x1f%cd\x1f%s", "--date=format:%Y-%m-%d %H:%M")
rows = [l.split("\x1f") for l in raw.splitlines() if l.count("\x1f") == 3]
if rows:
    for h, an, cd, s in rows:
        print(f"- `{h}` {cd} · {who_of(an)} · {s[:110]}")
    print()
    tally = []
    for b in run("git", "for-each-ref", "--format=%(refname:short)", "refs/heads").split():
        n = len(lines(run("git", "log", b, "--no-merges", f"--since={SINCE}", "--oneline")))
        if n:
            tally.append((n, b))
    if tally:
        print("By branch (lane):")
        for n, b in sorted(tally, reverse=True):
            print(f"- {n} on `{b}`")
    print()
else:
    print("No commits on any branch in this window — nothing committed anywhere.\n")

# 1. In flight right now — uncommitted work in every worktree -----------------------------
print("## In flight right now — uncommitted work, every worktree\n")
wts = [l[9:] for l in run("git", "worktree", "list", "--porcelain").splitlines() if l.startswith("worktree ")]
dirty = []
for wt in wts:
    n = len(lines(run("git", "-C", wt, "status", "--porcelain")))
    if n:
        br = run("git", "-C", wt, "branch", "--show-current").strip() or "detached"
        dirty.append((n, br, wt))
if dirty:
    for n, br, wt in sorted(dirty, reverse=True):
        print(f"- {n} changes · `{br}` · {short(wt)}")
    print()
else:
    print("All worktrees clean.\n")

# 2. Where we stopped ---------------------------------------------------------------------
print("## Where the last sessions stopped\n")
for line in mem_lines[-4:] or ["(MEMORY.md has no entries)"]:
    print(f"- {line.lstrip('- ')[:240]}")
print()

# 3. Open PRs -----------------------------------------------------------------------------
prs = []
if shutil.which("gh"):
    r = run("gh", "pr", "list", "--state", "open", "--limit", "50", "--json",
            "number,title,headRefName,isDraft,labels,body,statusCheckRollup")
    try:
        prs = json.loads(r) if r else []
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

# 4. 00-NOW -------------------------------------------------------------------------------
queue = section(now_text, "Hand-check queue")
print("## Hand-check queue (00-NOW)\n")
print((queue.splitlines()[0] if queue else "(section missing)") + "\n")

state = section(now_text, "In progress")
# 00-NOW stacks a dated "State (YYYY-MM-DD)" block per day, each ending in a
# "- Next:" / "- **Next:**" line. Take the LAST one (newest), not the first (stale),
# and strip any leading markdown bullet/bold so the line reads cleanly.
nxt = [l.strip() for l in state.splitlines() if re.match(r"-\s*\*{0,2}Next:", l.strip())]
nxt_line = re.sub(r"^-\s*\*{0,2}Next:\**\s*", "", nxt[-1]).replace("**", "").strip() if nxt else ""
if nxt:
    print("## Next in order (00-NOW)\n")
    print(nxt_line + "\n")

# 5. Start here ---------------------------------------------------------------------------
print("## Start here\n")
if needs_check:
    print(f"1. Hand-check #{needs_check[0]['number']}: `./scripts/try-pr.sh {needs_check[0]['number']}`, then tell the planner \"{needs_check[0]['number']} passed\".")
elif ready:
    print(f"1. Say \"merge N\" to the planner for: {', '.join('#%d' % p['number'] for p in ready)}; then ./scripts/main.sh.")
elif nxt_line:
    print("1. " + nxt_line)
else:
    print("1. Pick the first item under *Next, in order* in 00-NOW.md.")
print()

# 6. Drift and housekeeping ---------------------------------------------------------------
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
wtlist = [l[9:] for l in run("git", "worktree", "list", "--porcelain").splitlines() if l.startswith("worktree ")][1:]
if wtlist:
    merged = set()
    if shutil.which("gh"):
        try:
            merged = {p["headRefName"] for p in json.loads(run("gh", "pr", "list", "--state", "merged", "--limit", "200", "--json", "headRefName") or "[]")}
        except json.JSONDecodeError:
            pass
    stale = []
    for wt in wtlist:
        br = run("git", "-C", wt, "branch", "--show-current").strip()
        if br and br in merged:
            stale.append((wt, br))
    print(f"- {len(wtlist)} worktrees besides main" + (f"; {len(stale)} belong to merged PRs and can go (`git worktree remove <path>`)." if merged else "."))
    for wt, br in stale[:10]:
        print(f"    - `{os.path.relpath(wt, ROOT)}` ({br})")
    if SIZES:
        total = 0
        for wt in wtlist:
            kb = run("du", "-sk", wt).split()
            total += int(kb[0]) if kb else 0
        print(f"- Worktrees use {total / 1048576:.1f} GB.")
