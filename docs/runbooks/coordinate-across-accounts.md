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
