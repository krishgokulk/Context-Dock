# 00 — Engineering Operating Model: how DoraX is built, checked and shipped

> **Status: PROPOSAL — how I would run engineering if DoraX were mine.** Not about *what* to
> build (see [`00-COMPLETE-APP-PLAN.md`](00-COMPLETE-APP-PLAN.md)) — about **how the work
> happens**: codebase upkeep, structure, the daily workflow, and how AI agents take part.
> Tags: `[code]` found in this repo · `[ext]` public info · `[judgment]` my call · `[guess]` estimate.
> Written 2026-09-24 against `main` @ `341494a`.

---

## 0. The lesson from teams that maintain apps well

Well-maintained apps are not maintained by more people. They are maintained by **three things
that do not depend on anyone remembering a rule**:

1. **A narrow core with a hard boundary.** Raycast runs a native host app per platform, and
   most product work happens in a shared TypeScript/React front end and Node back end — so a
   feature ships to macOS and Windows at once, and UI changes hot-reload in under a second.
   Extensions talk to the core through one public API. `[ext — Raycast technical deep dive]`
2. **Automation on every change.** Raycast's public extensions monorepo runs lint and style
   checks on every PR, assigns reviewers automatically from each extension's manifest, and
   publishes to the store automatically on merge; the internal repo is synced before each
   release. `[ext — raycast/extensions docs]`
3. **A release rhythm.** Changes flow through a beta and a public changelog on a steady
   cadence, so no single release is scary. `[ext — Raycast changelog, Alfred "What's New"]`

Teams using coding agents well add a fourth: **conventions live in repo files, agents start
with low-risk work (tests, small fixes, docs), run in parallel worktrees, an agent does the
first review, and a human owns the merge.** `[ext — agentic coding guides 2026]`

DoraX already has pieces of all four. What it lacks is the **automation that makes them
non-optional**.

---

## 1. How DoraX engineering works today (audit) `[code]`

| Area | Today | Risk |
|---|---|---|
| Agent instructions | `CLAUDE.md` (310 lines) + `AGENTS.md` (285 lines), kept in sync by hand with `sync-agents.sh` | They have **drifted by 131 lines** — Claude and Codex follow different rules |
| Agent permissions | `.claude/settings.json` is **committed** with **150** one-off allow rules, 25 with a hard-coded `/Users/gokulakannan/…` path | Includes `Bash(./scripts/ship.sh)` and `Bash(rm -rf ~/Library/Caches/*)` — **an agent can publish a release to `main` without asking** |
| Hooks | `PreToolUse` hooks call `/Users/gokulakannan/.local/bin/graphify` | Breaks for anyone else, and in cloud sessions |
| Parallel agents | 2–4 sessions on one shared tree; rules in prose ("never `git add -A`", "never `stash`") | Rules only work if every agent reads and obeys them |
| Planning | `superpowers` spec → plan → subagent execution; 10 specs + 13 plans in 3 weeks | Many parallel plans; "current sequence" lives in CLAUDE.md |
| Work queue | Markdown plans + "brain issues" (#24, #25) | Two queues; no milestone per release |
| CI | `build.yml` builds Debug only | The 148 test files never run on a PR |
| PR template | Exists — build + manual QA boxes, "Areas" list | No test box; areas list predates chat surfaces |
| Release | `ship.sh` bumps, builds, DMG, **merges the work branch into `main` and pushes**, publishes a Release | No PR, no CI gate between a work branch and every user |
| Diagnosis | App's own `turns.log` (OSLog unreliable on the dev Mac) | Good — keep |

The strongest parts: the `superpowers` discipline (spec before plan before code), the
evidence-first docs (`FOUND.md`, `DECISIONS.md`, `docs/master` tags), and `turns.log`.

---

## 2. The operating model

### 2.1 Roles — one human, several agents, clear lanes `[judgment]`

| Role | Who | May do | May NOT do |
|---|---|---|---|
| **Owner** | you | product decisions, approve plans, merge PRs, release | — |
| **Planner** | agent | turn an issue into a spec + plan with acceptance tests | write app code |
| **Builder** | agent (Claude Code / Codex) | implement **one issue** in **one worktree**, in the lane the issue names | touch files outside its lane; push to `main`; release |
| **Reviewer** | agent, fresh session | review the PR diff (`/code-review`), check it against the issue's acceptance test | fix what it reviews (it reports; the Builder fixes) |
| **Verifier** | agent + owner | run the app, exercise the acceptance test, attach a screenshot/turn-log excerpt | merge |

Separating Builder from Reviewer matters: an agent reviewing its own work misses its own
assumptions.

### 2.2 The life of one change

```
 Issue (feature id, acceptance test, lane)          ← GitHub Issues, milestone = release
   │
   ▼  Planner (only for work > 1 day)
 Spec + plan in docs/superpowers/  (links the issue)
   │
   ▼  Builder, in .claude/worktrees/<issue>/
 Branch  feat/<issue>-<slug>  →  code + tests  →  ./scripts/check.sh  (build · tests · file size)
   │
   ▼
 Pull request  (template: issue link, feature id, test added, doc updated, screenshots)
   │
   ▼  CI  (required)
 build · all tests · golden-corpus pass-rate · file-size · dependency-direction
   │
   ▼  Reviewer agent → comments;  Builder fixes
   ▼  Owner: read diff, run the app, try the acceptance test
 Squash-merge to main   ← main is always releasable
   │
   ▼  Release train (§2.7)
 Beta → Stable
```

### 2.3 One queue: GitHub Issues + milestones

- Every piece of work is an **issue** with: feature id (F1…B8 from the complete plan), the
  acceptance test, the **lane** (folder or package it may touch), and a size (S ≤ ½ day, M ≤ 2 days,
  L = must be split).
- **Milestones = releases** (`1.0`, `1.1`…). The milestone *is* the current sequence — it
  replaces the hand-edited list in CLAUDE.md.
- Labels: `bug`, `feature`, `chore`, `docs`, `security`, `labs`, `agent-ok` (safe to hand an agent unsupervised).
- "Brain issues" and markdown TODO lists fold into this one queue.

### 2.4 Agent instructions: one source of truth

- **`AGENTS.md` is the single file.** `CLAUDE.md` becomes a few lines: `@AGENTS.md` plus the
  Claude-only notes. Delete `sync-agents.sh`. Both agents now read identical rules.
- **Keep it under ~150 lines.** It holds only: the layer rule, build/test/run commands, the
  multi-agent safety rules, where docs live. Everything else moves to `docs/` or a skill.
  Long instruction files get skimmed — by agents too.
- **Each package/surface folder gets a short `README.md`** with its local rules (job, public API,
  what it must never import). Agents working in that lane read the nearest one.

### 2.5 Agent permissions and hooks — safe by default

- **Committed `.claude/settings.json`: small and generic.** Allow read-only and build/test
  commands (`./scripts/build-debug.sh`, `./scripts/test.sh`, `git status`, `git diff`…).
- **Never allowed without asking:** `./scripts/ship.sh`, any `rm -rf`, `git push` to `main`,
  `git reset --hard`, `git stash`, `git checkout -- .` (the ones CLAUDE.md already forbids —
  now enforced as **deny** rules, not prose).
- **Machine-specific rules** (paths under `/Users/…`, one-off `awk` lines) go to
  `.claude/settings.local.json`, which is git-ignored.
- **Hooks that help:** a `Stop` hook that runs `./scripts/check.sh` so an agent cannot finish a
  turn with a broken build; the graphify hook referenced by `$HOME`/`PATH`, not a fixed path.

### 2.6 Parallel agents without collisions

- **One agent = one worktree = one branch = one issue.** No agent works in the shared tree.
  (Your rule "isolate risky work in a worktree" becomes "isolate *all* agent work".)
- **Lanes, not luck.** Two agents may run at once only if their issues name different lanes
  (e.g. `Surfaces/Find` and `DoraXEngine`). The package structure (`00-APP-STRUCTURE.md`) is what
  makes lanes real.
- **At most 3 builders at once** `[judgment]` — the owner's review time is the real bottleneck;
  more agents than you can review just grows a queue of unreviewed PRs.

### 2.7 Branching and releases

- **Trunk-based.** `main` is protected: no direct push, CI must pass, squash-merge only.
  Branches live < 3 days.
- **`ship.sh` changes job:** it no longer merges anything. It runs **from `main` after merge**:
  bump → build Release → sign/notarize → DMG → tag → GitHub Release. Merging is the PR's job.
- **Two update channels:** `beta` (every 2 weeks `[guess]`) and `stable` (monthly, or when beta
  has been crash-free for a week). The manifest already has a `channel` field. `[code]`
- **Labs flags** keep unfinished surfaces in `main` but off for users — so long-running work
  merges early instead of living on a branch for weeks.
- **`CHANGELOG.md`** updated in each PR (one line, user-facing words); the release notes are
  generated from it.

### 2.8 Quality gates

| When | Gate | Blocks |
|---|---|---|
| Every agent turn | `Stop` hook → `check.sh` (build + fast tests) | ending the turn |
| Every PR | CI: build, **all tests**, golden-corpus score, file size, dependency direction | merge |
| Every PR | Reviewer agent + owner diff read + acceptance test | merge |
| Every beta | Release build, `docs/RELEASE_CHECKLIST.md` manual QA, signed + notarized | publishing |
| Every stable | beta crash-free ≥ 7 days, corpus score not lower than last stable | promoting |

### 2.9 Where agents help most (and least)

| Give agents freely (`agent-ok`) | Give with a spec + owner review | Keep human-led |
|---|---|---|
| Writing tests for existing code | New features from an approved plan | Product decisions, what to cut |
| Small bug fixes with a repro | Refactors across one package | Security-sensitive code (approval, `run_command`, `send_keys`) |
| Doc updates, `graphify update` | Moving files into the new structure | Release and signing |
| Dependency bumps | Performance work (with a measurement) | Anything touching user data deletion |
| Triage: reproduce a bug report, find the file | Golden-corpus additions | Merging |

### 2.10 Documentation that stays true

- `docs/master/` is the map; each surface doc names its files.
- **Every PR that changes behaviour updates the matching `docs/master` section** — a box in the PR
  template, checked by the Reviewer agent.
- Decisions go in `docs/decisions/` as short records (date, decision, why) — `DECISIONS.md`
  already does this; keep it.
- A monthly "doc truth" agent task: compare each `docs/master` claim tagged `[code]` against the
  code and open issues for anything stale.

### 2.11 Observability

- **Dev:** `turns.log` (keep), perf signposts on the typing path, `SearchPerformanceLog`.
- **Users (opt-in):** crash reports + anonymous feature counts, so the roadmap follows real use.
- **Release health:** crash-free %, corpus score, open `security` issues — one line at the top of
  `00-PRODUCT-PLAN.md`, updated each release.

---

## 3. A solo owner's week `[judgment]`

| Day | Owner does | Agents do |
|---|---|---|
| **Mon** | Pick this week's issues from the milestone; approve any plans | Planner drafts plans for M-size issues |
| **Tue–Thu** | Review PRs (≤ 3 lanes open), run the app, merge | Builders implement; Reviewer reviews each PR |
| **Fri** | Cut the beta (`ship.sh` from `main`), read crash/health numbers, update the health line | Doc-truth / `graphify update` / dependency chores |

Rule of thumb: **never have more open agent PRs than you can review in a day.**

---

## 4. Rollout — first two weeks

| # | Step | Size |
|---|---|---|
| 1 | Clean `.claude/settings.json`: generic allow list, **deny** `ship.sh` / `rm -rf` / push to `main`; move the rest to git-ignored `settings.local.json` | S |
| 2 | Make `AGENTS.md` the single source; `CLAUDE.md` imports it; delete `sync-agents.sh` | S |
| 3 | Add `scripts/check.sh` (build + tests + file-size) and a `Stop` hook that runs it | S |
| 4 | CI runs `./scripts/test.sh`; protect `main` (CI required, no direct push) | S |
| 5 | Update the PR template: issue link, feature id, test added, doc updated, CHANGELOG line | S |
| 6 | Create milestone `1.0`; turn the v1 **Must** list into issues with lanes and acceptance tests | M |
| 7 | Change `ship.sh` to release from `main` only (no merge step); add beta/stable channels | M |
| 8 | Fold "brain issues" and open markdown TODOs into GitHub Issues | S |

After these eight, every rule in CLAUDE.md that today depends on an agent remembering it is
either enforced by a tool or removed.

---

## 5. Corrections to earlier plan docs

- `00-CODEBASE-PLAN.md §4 Stage A` says "add a PR template" — one **already exists**
  (`.github/pull_request_template.md`); the task is to update it (§4 step 5 above).

---

## 6. Owner decisions

1. Allow agents to run `ship.sh` at all? (Recommendation: no — owner only.)
2. GitHub Issues as the single work queue, replacing the CLAUDE.md sequence?
3. Protect `main` and route every change through a PR, including your own quick fixes?
4. `AGENTS.md` as the single instruction file for both Claude and Codex?
5. Beta every 2 weeks, stable monthly — or a different rhythm?

---

## Sources `[ext]`

- [A Technical Deep Dive Into the New Raycast](https://www.raycast.com/blog/a-technical-deep-dive-into-the-new-raycast)
- [How the Raycast API and extensions work](https://www.raycast.com/blog/how-raycast-api-extensions-work)
- [Raycast — Publish an Extension](https://developers.raycast.com/basics/publish-an-extension) · [Review an Extension in a PR](https://developers.raycast.com/basics/review-pullrequest)
- [raycast/extensions (DeepWiki)](https://deepwiki.com/raycast/extensions)
- [Alfred — What's New](https://www.alfredapp.com/whats-new/)
- [AI Coding Agents in 2026: a practical roadmap](https://codepick.dev/en/guides/ai-coding-agents-2026-roadmap/) · [Agentic Coding Guide 2026](https://www.teamday.ai/blog/complete-guide-agentic-coding-2026) · [AI agents for engineering teams](https://www.workclaw.com/blog/ai-agents-engineering-teams)
