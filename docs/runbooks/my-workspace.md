# Runbook — the owner's workspace: one main build, test builds beside it

One project, one rule: **the main checkout is always `general-chat-agent`, and it is the DoraX
you use every day.** Every change is built and tried somewhere else, then merged, and only then
does it reach the main build.

## Where things live on the Mac

| Path | What it is | Who changes it |
|---|---|---|
| `~/Developer/Context-Dock` | **Main.** Always `general-chat-agent`, never edited by hand or by a session | `./scripts/main.sh` only (fast-forward) |
| `~/Developer/Context-Dock-pr-<n>` | **Test build** of PR #n, for your hand check | `./scripts/try-pr.sh <n>` |
| `~/Developer/Context-Dock/.claude/worktrees/*` | **Agent worktrees**: one per session, one per issue | the session that made it |

Each folder has its own `.build`, so builds never overwrite each other. Only one DoraX runs at a
time; launching one quits the other.

## The loop

```
session builds an issue in its worktree ──► draft PR ──► CI green ──► agent-run hand check
                                                                              │
   you: ./scripts/try-pr.sh <n>   (test build launches)                       ◄┘
   you: check the PR's list ──► "N passed" to the planner ──► planner merges
   you: ./scripts/main.sh         (main build updates and launches)
```

- **Try a PR:** `./scripts/try-pr.sh 210`. Add a commit to pin one: `./scripts/try-pr.sh 210 3d3c801`.
- **Back to your daily app:** `./scripts/main.sh`.
- **Free disk:** `./scripts/clean-worktrees.sh` lists every worktree with its size;
  `./scripts/clean-worktrees.sh --pr` removes the `Context-Dock-pr-*` test builds (never one with edits).

Parallel work is several agent worktrees at once (for example one Corner UI session and one
builder). They never share a folder, and they meet only on GitHub through PRs.

## Sessions don't remember. The repo does.

A new session knows nothing from the chat. Everything it needs is in the repo:

| Question | Where |
|---|---|
| What's next, in what order; the owner's decisions | `docs/master/00-NOW.md` |
| The plans | `docs/master/DORAX-BLUEPRINT.md`, `00-AI-ENGINE-PLAN.md`, `00-APP-AGENT-PLUGIN-PLAN.md` |
| Who is working on what | open PRs (one per issue) and issue labels `ready` / `in-progress` / `needs-hand-check` |
| What each past session did | `MEMORY.md` (one line per session) |
| How sessions hand over | `coordinate-across-accounts.md` |

So a session is safe to close at any time **if its work is pushed and `00-NOW.md` says where things
stand**. Start the next one with `/planner` (cloud) or `/loop /builder` (Mac); it reads the files above.

## Keep sessions short

A long session gets more expensive every turn. Prefer one session per issue, close it when its PR is
merged, and start a fresh planner each day or two. Nothing is lost: see the table above.
