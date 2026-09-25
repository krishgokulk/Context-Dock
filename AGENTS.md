# AGENTS.md

The one instruction file for every coding agent in this repo — Claude Code (via `CLAUDE.md`, which
imports this file) and Codex. Keep it under ~150 lines: the layer rule, build/test/run, the
multi-agent safety rules, and where the docs live. Everything else belongs in `docs/` or a skill.

## Start here

- **The plan:** `docs/master/DORAX-BLUEPRINT.md` — product, architecture, code, docs, workflow,
  the 15-week plan and the owner's decisions. Follow it; do not rewrite it.
- **Now:** `docs/master/00-NOW.md` — the next few tasks in order, and the owner's decisions.
- **The queue:** GitHub Issues, milestone `1.0`. The milestone is the current order of work.
- **How the code is laid out today:** `docs/engineering/codebase.md`.
- **How work is done:** `docs/master/00-ENGINEERING-OPERATING-MODEL.md`.
- **Architecture truth files:** `docs/architecture/`.
- **Runbooks:** `docs/runbooks/` — ship a release, diagnose an AI turn.

## DoraX architecture rule

Never merge product layers.

- Global Context is not Chat Mode.
- Context Dock is not Global Context.
- Context Dock Chat Mode is not General Chat Mode.
- Selection Shortcut Sheet is not a launcher.
- Media Dock is not a chat surface.

Each surface must keep one job: search, frontmost app actions, general chat, app-scoped chat, media,
or selection-aware actions.

Unified Dock Surface rule: one shell, multiple modes, stable state, mode-specific content. Do not
create separate floating visual containers per mode; use shared shell, input, row, animation, and
size rules.

Before touching any Dock (`LauncherView*`) or Corner (`AppChat*`, `Corner*`, `SelectionScope*`)
code, read `docs/master/00-DOCK-AND-CORNER.md` and `docs/master/00-DOCK-PARITY-INVENTORY.md`.
- The Dock is the reference behaviour; the Corner must match it. Reuse Dock code; never write a
  second copy.
- A bug fixed in one shell: check the other shell for the same bug in the same PR, and update the
  matching inventory row.

## Build, run, test

Pure Xcode project — no Makefile, no SPM package at the root.

**After every code edit, build + relaunch with the shared script — never raw `xcodebuild` + `open`:**

```bash
./scripts/dev-run.sh     # builds Debug into .build/XcodeDerivedData and relaunches THAT app
./scripts/build-debug.sh # build only, same DerivedData
./scripts/check.sh       # the gate: Debug build + oversized-file warning; --full adds the tests
./scripts/test.sh        # whole suite (offline: no API key, no network)
```

Why: raw `xcodebuild` writes to Xcode's hashed DerivedData while `.build/XcodeDerivedData` holds the
agents' build — launching a `~/Library/Developer/Xcode/DerivedData` path has shipped a **stale app**
before. `dev-run.sh` is the single source of truth for which binary runs.

**Before finishing a turn that touched Swift, `./scripts/check.sh` must pass.** Claude's `Stop` hook
runs it automatically.

The suite lives in `Context-DockTests/` and uses **swift-testing** (`import Testing`, `@Test`), not
XCTest. The app's single-instance guard stands down under XCTest (`ILauncherApp.swift`), which is
what lets the test host start while the developer's copy is running. Anything needing a live model
is NOT in this suite — provider behaviour is verified by hand against the running app.

A new worktree fails its first build in `actool` until `Context-Dock/AppIcon.icon` (git-ignored) is
copied in from the main checkout.

Releases: only when the owner says **"ship it"** — see `docs/runbooks/ship-a-release.md`. Agents
never run `ship.sh` on their own.

## Working alongside other agents

2–4 Claude/Codex sessions run against this repo at once. Assume a file you did not touch is being
edited by someone else **right now**, and that HEAD moves under you.

- **One agent = one worktree = one branch = one issue.** Put work in `.claude/worktrees/`, not the
  shared tree.
- **Never `git add -A` / `git commit -a`.** Stage explicit paths only — anything else sweeps up
  another session's half-finished work.
- **Never** `git checkout -- .`, `git stash`, `git reset --hard`, or branch switches on the shared
  tree. Those destroy uncommitted work you cannot see.
- **Never push to `main`.** Changes reach `main` through a pull request with green CI.
- **Re-check before you conclude.** `git log --oneline -3` and `git status` at the start of a task,
  and again before reporting counts or "this is all the usages" — both change mid-task.
- If `git status` shows modifications you did not make, leave them alone and say so.
- Cross-session progress goes in `MEMORY.md` at the repo root — append-only, one dated line per
  session.

## Finish the started task before taking the next one

Work is sequenced deliberately, and the sequence is the owner's.

When a task is underway and the owner asks for something else, **finish the current task first**,
then take the new one. Say plainly that the new item is queued and where it sits; do not silently
drop it, and do not abandon half-built work to chase it. The exception is the owner saying to
switch, or the new item making the current task pointless. A defect found *inside* the current task
is part of it and gets fixed on the spot.

When the plan is a numbered sequence, name the task being worked on and what comes next.

## Codebase navigation

Before grepping or reading raw source, ask the knowledge graph:

- `graphify query "<question>"` when `graphify-out/graph.json` exists; `graphify path "<A>" "<B>"`
  for relationships; `graphify explain "<concept>"` for one concept.
- `graphify-out/wiki/index.md` for broad navigation; `graphify-out/GRAPH_REPORT.md` only for broad
  architecture review.
- Dirty `graphify-out/` files after hooks are expected, not a reason to skip it.
- After modifying code, run `graphify update .` (AST-only, no API cost).

Large files — read only the range you need: `Search/LauncherView.swift` (3,899 lines),
`Search/LauncherView+ContextualActions.swift`.

## Diagnosing an AI turn

OSLog notice-level logs are not persisted on the development Mac. Use the app's turn log —
`docs/runbooks/diagnose-an-ai-turn.md`.
