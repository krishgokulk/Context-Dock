# Runbook — coordinate the work from any Claude account

The owner works from more than one Claude account: whichever has usage left. A session on any
account must pick the work up exactly where the last one stopped, with nothing lost. **The repo is
the handoff, never the chat.** A session can hit its usage limit mid-sentence, so nothing may depend
on it saying goodbye.

## The lock: one coordinator at a time

`docs/master/00-NOW.md` carries one line under *In progress*:

```
Coordinator: <account or surface, e.g. "Desktop app (Mac)" / "cloud, 5-hour account"> — since <YYYY-MM-DD HH:MM UTC>
```

- Only the session named there edits `00-NOW.md` and `MEMORY.md` and starts queue tasks.
- **The owner telling a session "continue" or "take over" moves the lock.** That session rewrites
  the line and carries on. The previous coordinator is presumed stopped (its account ran out); it
  does not need to release anything, because of the next rule.

## Always handoff-ready (every coordinator, every task session)

Assume you can stop at any moment:

1. Every task works on its own pushed branch with a **draft PR opened in its first commits**.
   Push after each meaningful step — work that exists only on one machine is lost at the limit.
2. `00-NOW.md` is updated the moment state changes: task started (branch + PR), CI green, ready
   for hand test, merged. Never batch these for later.
3. The PR description always says: what is done, what is left, and the owner's hand-check list.

## Taking over (the first five minutes of any session told "continue" / "take over")

1. `git fetch origin`, then read `00-NOW.md` on `general-chat-agent` **and** on the coordinator
   branch named in it (the newer one wins).
2. List open PRs and `claude/task-*` / `claude/fix-*` branches. An open PR is a claim: continue it
   from its pushed branch; never restart a task that already has one.
3. Rewrite the `Coordinator:` line, push, then continue the first unfinished task.

## The loop (runs without asking the owner)

For each task in `00-NOW.md` order:

1. One session or subagent, one worktree, one branch from `general-chat-agent`, draft PR titled
   `Task <n>: …` (queue) or `Fix: …` (owner-reported bug).
2. It writes tests, gets CI "Build and test" green, and runs a `/code-review` pass on its diff.
3. **If the session is on the Mac** (Desktop app, local CLI): `./scripts/dev-run.sh`, screenshot the
   changed surface and its reference, and fix what the screenshots show. Cloud sessions cannot
   see the screen; they say so and leave the visual checks to the owner.
4. The coordinator sends the owner **one message**: PR link, a short hand-check list, the launcher
   line (`relaunch PR <n>`), and the next task. Then it starts the next task that does not depend
   on this one.
5. Merge only on the owner's words "merge <n>". Then move the task to *Done* and remove its
   entry from the hand-check queue once the owner confirms the check.

## The hand-check queue

`00-NOW.md` keeps a *Hand-check queue*: every merged PR the owner has not checked by hand yet,
with its checklist. A failed check becomes a `Fix:` task at the top of the queue, and the failing
sentence or step is added to the matching test (for routing: `RoutingPhrasebookTests`).

## Lanes when two accounts run at the same time

- **Queue lane** — holds the lock; works `00-NOW.md` in order.
- **Fixes lane** — owner-reported bugs only, on `claude/fix-*` branches with `Fix:` PRs. It never
  edits `00-NOW.md` or `MEMORY.md`; the queue lane records its merges.

## Planner and builder (the default setup)

Roles belong to **where a session runs**, not to which account is logged in.

| Where | Role | Start it with |
|---|---|---|
| Claude Desktop on the owner's Mac, any account | **Builder** — builds, tests and screenshots one issue at a time | `/loop 20m /builder` |
| A cloud session (claude.ai/code), any account | **Planner** — holds the Coordinator line, queues issues, reviews PRs | `/planner` |

The two never message each other; **GitHub issues are the queue** between them:

- `ready` — the planner queued it; the builder may take it (oldest first).
- `in-progress` — the builder is on it. Never more than one.
- `needs-hand-check` — PR open with CI green; waiting on the owner's check and "merge <n>".
- `needs-owner` — blocked on an owner decision; nobody builds it.

Rules that keep it safe when accounts change:

- **One builder at a time.** Switching accounts on the Mac: close the old session first, then
  `/loop 20m /builder` in the new one. A new builder continues an `in-progress` issue from its
  pushed branch; it never restarts it.
- **One planner at a time** — the session holding the `Coordinator:` line.
- The builder never edits `00-NOW.md` or `MEMORY.md`; the planner records merges there.
- When the Mac sleeps, the app closes or the account runs out, the loop stops. Nothing is lost:
  the issue label and the pushed branch say exactly where it was.

## Pausing and skipping (how the loop behaves)

- **Usage limit reached:** the builder's session stops mid-step; nothing is lost (pushed branch,
  issue label). When the account has usage again the loop's next run continues the `in-progress`
  issue. If the session was closed, start `/loop 20m /builder` again.
- **Hand checks:** the builder keeps building past PRs whose check is optional; after **one PR marked
  `Hand check: required`** it pauses until the owner checks it or says "merge N without hand check". Optional checks
  never pause it.
- **Skipping a hand check:** the owner may say "merge N without hand check" for any PR. The planner
  merges, records it under *Skipped hand checks* in `00-NOW.md`, and all skipped checks are done in
  one pass before `ship it`. Merging still needs the owner's words; nothing merges itself.
- **Next task:** the planner keeps two issues `ready` ahead of the builder, so a finished task is
  followed by the next one on the builder's next run without anyone sending it.

