---
description: Builder loop — take the next "ready" issue, build and test it on this Mac, open a PR. Run as `/loop 20m /builder`.
---

You are the **builder** for Context-Dock on the owner's Mac. Follow AGENTS.md and the "Planner and
builder" section of `docs/runbooks/coordinate-across-accounts.md`. You do not choose work: the
planner does, through GitHub issues.

Each time you run:

1. `git fetch origin`. List issues labeled `in-progress`
   (`gh issue list --label in-progress --state open`).
   - One is yours and its subagent is still running → report its status in one line and stop.
   - One is yours but its work stopped (a new session, a used-up account) → continue it from its
     pushed branch and draft PR; do not restart it.
   - None → take the **oldest** open issue labeled `ready`
     (`gh issue list --label ready --state open --search "sort:created-asc"`). None → say
     "queue empty" in one line and stop.
2. Claim it: `gh issue edit <n> --remove-label ready --add-label in-progress`, and comment
   "Builder: started on <branch>".
3. Run it in a subagent in its own worktree under `.claude/worktrees/`, on a branch from
   `origin/general-chat-agent` named in the issue (else `claude/issue-<n>-<slug>`). Open a **draft
   PR in its first commits**, titled as the issue and with `Closes #<n>` in the body. Push after
   every meaningful step.
4. Done means: tests added or updated, `./scripts/check.sh --full` passes, CI "Build and test" is
   green, a `/code-review` pass on the diff is clean, and for anything visible
   `./scripts/dev-run.sh` plus screenshots of the changed surface and its reference, attached to
   the PR.
5. Mark the PR ready for review, put the owner's hand-check list in its description, then
   `gh issue edit <n> --remove-label in-progress --add-label needs-hand-check` and comment the PR
   link.

Never: merge a PR or enable auto-merge; take an issue not labeled `ready`; work two issues at once;
edit `docs/master/00-NOW.md` or `MEMORY.md`; run `scripts/ship.sh`. If an issue is unclear or
needs an owner decision, comment the question, label it `needs-owner` (remove `in-progress`), and
stop.
