# Runbook — ship a release

Status: current · Last checked: 2026-09-24 · Describes: `scripts/release-prep.sh`, `scripts/ship.sh`

When the owner says **"ship it"** / **"release it"**, follow these two steps — do **not** re-derive
them. Agents never run `ship.sh` on their own: `.claude/settings.json` makes it ask first.

`main` is protected, so a release reaches it through a pull request like any other change, and
`ship.sh` only publishes what `main` already says (`docs/master/00-ENGINEERING-OPERATING-MODEL.md` §2.7).

## 1. Open the release PR — from a work branch

```bash
./scripts/release-prep.sh beta        # next build number
./scripts/release-prep.sh beta 17     # explicit build number
./scripts/release-prep.sh stable      # needs a CFBundleShortVersionString not yet released
```

It bumps the build, writes the channel's update manifest, commits, pushes and opens a PR into
`main`. The manifest's `dmgURL` is the GitHub Release asset `ship.sh` will publish — its address is
known in advance from the tag. Notes come from the top section of `CHANGELOG.md`, so update that first.

| Channel | Manifest | Tag | DMG |
|---|---|---|---|
| beta | `update-manifest.json` (every build shipped so far reads it) | `v1.1-beta.16` | `Context-Dock-1.1-beta.dmg` |
| stable | `update-manifest-stable.json` **and** `update-manifest.json` | `v1.2` | `Context-Dock-1.2.dmg` |

The app picks its manifest from the `updates.channel` default (`beta` unless set to `stable`).

## 2. Merge, then ship — from `main`

Merge the PR once CI is green, then straight away:

```bash
git switch main && git pull --ff-only
./scripts/ship.sh beta                # or: ./scripts/ship.sh stable
```

`ship.sh` refuses unless `main` is clean, equals `origin/main`, has green CI on that commit, and its
manifest names the build in `Info.plist`. It builds Release (serial `-jobs 1`, to dodge the build.db
prune flake), signs with the local Apple Development identity, makes the DMG under `.build/release/`,
and publishes a GitHub Release at that commit with the DMG attached. It checks the uploaded URL is
exactly the manifest's `dmgURL`. It commits, merges and pushes nothing.

Between the merge and `ship.sh`, the manifest names a DMG that does not exist yet — an update check
in that window fails to download. Keep the gap short.

The DMG is signed with Apple Development, not Developer ID, and not notarized — first launch on
another Mac needs right-click → Open. Developer ID and notarization come in Phase 3 (issue B3).
