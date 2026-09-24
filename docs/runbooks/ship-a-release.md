# Runbook — ship a release

Status: current · Last checked: 2026-09-24 · Describes: `scripts/ship.sh`

When the owner says **"ship it"** / **"release it"**, run the script — do **not** re-derive the steps.
Agents never run it on their own: `.claude/settings.json` makes it ask first.

```bash
./scripts/ship.sh        # auto-increment the build number
./scripts/ship.sh 9      # explicit build number
```

`scripts/ship.sh` is the single source of truth for releasing. In one command it: bumps the build,
builds Release (serial `-jobs 1` to dodge the build.db prune flake), makes the DMG, commits + pushes
the current work branch, merges into `main` and pushes it, then publishes a GitHub Release with the
DMG attached (token read from the git credential store).

Preconditions the script enforces: run from a **work branch** (not `main`) with all source changes
already committed; it aborts cleanly on merge conflicts. The DMG is an **unsigned** beta (no
notarization) — first launch on another Mac needs right-click → Open. The in-app updater reads
`update-manifest.json` from `main`.

Planned change (`docs/master/00-ENGINEERING-OPERATING-MODEL.md` §4 step 7): `ship.sh` will release
from `main` after a PR merge, with no merge step of its own, and gain beta/stable channels.
