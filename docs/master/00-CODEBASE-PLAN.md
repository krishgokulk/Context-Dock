# 00 — Codebase Plan: how I would keep DoraX's code

> **Status: PROPOSAL — written as if I owned this codebase.** Companion to
> [`00-PRODUCT-PLAN.md`](00-PRODUCT-PLAN.md). Measured on `main` @ `341494a`, 2026-09-24.
> Tags: `[code]` measured in the repo · `[judgment]` my recommendation · `[guess]` estimate.

---

## 0. The one problem underneath all the others

The architecture rules are good, but they live in **prose** (CLAUDE.md, `PRODUCT_LAYERS.md`).
Nothing in the build enforces them, so with 2–4 agents editing at once they erode a little
every day. `[code]` Proof — the AI engine reaches into the UI:

```swift
// AI/GeneralAIActionResolver.swift:496   (engine → UI view type)
guard !LauncherView.isBrowserLibraryReadPhrase(lowered) else { return nil }
// Services/ClipboardScopeService.swift:22 (service → UI view type)
typealias Entry = LauncherView.ClipboardEntry
```

12 files in `AI/` and `Services/` name `LauncherView`. CLAUDE.md says data flows *down*;
the code flows both ways.

**The fix is not more rules. It is making the compiler enforce the rules you already have.**
Everything below serves that. `[judgment]`

---

## 1. What the codebase looks like today `[code]`

| Folder | Files | Lines | What the name says | What is actually inside |
|---|---:|---:|---|---|
| `Search/` | 83 | 83,129 | search | search **and** chat, clipboard, media, Finder, Safari, Mail — the whole UI |
| `Services/` | 180 | 54,339 | shared infra | infra **and** features (media, memory, updater, dashboard…) |
| `AI/` | 169 | 49,958 | AI engine | engine **and** UI (`L2AIIntegrationView`, `GeneralChatWindowModel`) |
| `UI/` | 95 | 32,296 | reusable UI | reusable UI **and** 8,656-line legacy settings |
| `Automation/` | 15 | 13,204 | routing | routing **and** an 8,128-line settings view |
| `App/` | 10 | 7,002 | entry | `ILauncherApp.swift` alone is thousands of lines |
| `Accessibility/` | 13 | 4,925 | AX pipeline | ✓ matches |
| `Preview/`, `Developer/` | 22 | 3,376 | previews, inspector | ✓ matches |

Other measurements:
- **One god view.** `LauncherView` is spread over **39** `LauncherView+*.swift` extensions — every
  surface shares one struct and its `@State`.
- **21 files over 2,000 lines; 49 over 1,000.**
- **247 `static let shared` singletons.**
- **22 settings files, 23,532 lines** — about 10% of the app is settings.
- **Repo root:** an 18 MB DMG committed **9 times** (history bloat on every clone), PNG/PDF/HTML
  design files, two script folders (`script/` and `scripts/`), `CHANGES.md` *and*
  `CHANGELOG.md`, a stale `Base.lproj/ILauncher.entitlements`.
- **CI builds but never runs the 148 test files.** (`.github/workflows/build.yml`)

---

## 2. The target shape

### 2.1 Dependency direction — enforced by the compiler

```
                ┌──────────────────────────────┐
  app target    │  App/  (entry, hotkeys, windows)│
                │  Shell/ (one dock shell, rows,  │
                │          animation, sizing)     │
                │  Surfaces/Find · Ask · ActOnThis│
                │  Surfaces/Labs/…                │
                │  Settings/                      │
                └──────────────┬─────────────────┘
                               │ imports
          ┌────────────────────┼─────────────────────┐
          ▼                    ▼                     ▼
   DoraXEngine          DoraXCapabilities       DoraXMemory
   providers, tool      registry, adapters,     vault, retrieval,
   loop, planner,       MCP, menu execution,    distiller
   verifiers, approval  CLI, Shortcuts
          └────────────────────┼─────────────────────┘
                               ▼
                        DoraXContext   (AX observer, snapshots, event bus)
                               ▼
                        DoraXCore      (models, store, keychain, logging, utils)
```

Each box below the app target is a **local Swift package** (`Packages/DoraX*/`). A package
cannot import anything above it — if `DoraXEngine` mentions `LauncherView`, **it does not
compile**. That single mechanism replaces most of the "never merge layers" prose. `[judgment]`

Side benefits:
- Package tests run with `swift test` — no host app, so no single-instance-guard trouble, and
  they are fast enough to run on every PR.
- Agents working in parallel collide less: engine work and UI work touch different packages.

### 2.2 The app-target folders

```
Context-Dock/
  App/                entry point, AppDelegate, hotkeys, window setup
  Shell/              the Unified Dock Surface: shell, input, rows, sizes, animation
  Surfaces/
    Find/             Global Context + Context Dock (01, 02)
    Ask/              app-scoped + general chat UI (03, 04)
    ActOnThis/        selection sheet + clipboard (05)
    Labs/             Media Dock, dashboard, drop shelf, dock strip — off by default
  Settings/           every settings page, one file per page
  Developer/          inspector (Debug builds only)
Packages/
  DoraXCore/  DoraXContext/  DoraXCapabilities/  DoraXEngine/  DoraXMemory/
Context-DockTests/    app-level tests only (UI state, surfaces)
Context-DockExtension/
docs/  scripts/
```

Folder names match the product (`00-PRODUCT-PLAN.md` §2): a new contributor — or agent — finds
code by what the user sees.

### 2.3 Repo root after cleanup

```
README.md  CLAUDE.md  AGENTS.md  CHANGELOG.md  LICENSE  NOTICE
Context-Dock.xcodeproj/  Context-Dock/  Packages/  Context-DockTests/  Context-DockExtension/
docs/  scripts/  .github/
```

Everything else moves to `docs/` (design files → `docs/assets/`, audits → `docs/history/`) or
is deleted.

---

## 3. Rules that keep it that way

| Rule | How it is enforced |
|---|---|
| Lower layers never import upper layers | Swift packages (§2.1) — compile error |
| No file over **1,500** lines; new files aim for < 500 | `scripts/check-file-size.sh` in CI — warns now, fails once the big files are split |
| No new singleton | New types take dependencies through `init`. Existing singletons stay until touched |
| One surface = one state owner | Each surface has its own `@Observable` model; `LauncherView` becomes only the shell router |
| Tests run on every PR | `scripts/test.sh` in `build.yml`, required check on `main` |
| AI quality can't silently drop | Golden-corpus pass-rate printed in CI (`00-PRODUCT-PLAN.md` §3.4) |
| No binaries in git | DMG goes to GitHub Releases only; `.gitignore` `*.dmg` |
| Cross-layer events | Method call or typed publisher; `Notification.Name` only for UI-scope signals (already your rule) |
| Every PR names its checklist box | PR template |

---

## 4. Migration — safe order, every step is one PR that builds

The app keeps working after every step. Nothing is a big-bang rewrite. `[judgment]`

### Stage A — Guardrails first (during Product Phase 1–2, ~1 week) `[guess]`
1. Add `./scripts/test.sh` to CI; make it required.
2. Add `scripts/check-file-size.sh` (warn only).
3. Add a PR template: *which v1 checklist box does this tick?*

### Stage B — Tidy without touching logic (~1 week)
4. Root cleanup: stop committing the DMG — the updater's `dmgURL` points at a GitHub Release
   asset instead of `raw.githubusercontent.com/.../main/…dmg`; move design files; merge
   `script/` into `scripts/`; merge `CHANGES.md` into `CHANGELOG.md`; delete stale
   `Base.lproj/ILauncher.entitlements`.
   *(Removing the DMG from past history needs a force-push rewrite — only with the owner's
   explicit OK, and only when no other session has open branches.)*
5. **Pure file moves:** split `Search/` into `Shell/`, `Surfaces/Find`, `Surfaces/Ask`,
   `Surfaces/ActOnThis`, `Surfaces/Labs`; gather settings into `Settings/`. The project uses
   synchronized folders, so moving a file needs no `project.pbxproj` edit. Zero code change —
   easy to review, easy to revert.

### Stage C — Delete dead code (~1 week)
6. Prove with `turns.log` which intent router is live; delete the other
   (`L2UnifiedAssistant` + its 4 companion files, or `GeneralAIActionResolver`).
7. Audit `LegacySettingsContent.swift` (8,656 lines): move what is still reachable, delete the rest.

*Stages A–C fit inside the product plan's "freeze & cut" and "trust" phases.*

### Stage D — Packages, bottom up (after v1.0 launch, ~4–6 weeks)
8. `DoraXCore` first (models, store, keychain, logging) — it has no upward dependencies.
9. `DoraXContext` (AX pipeline).
10. `DoraXCapabilities`, `DoraXMemory`.
11. `DoraXEngine` last — this is where the 12 `LauncherView` references break. Fix each by
    moving the shared thing *down* (e.g. `ClipboardEntry` → `DoraXCore`,
    `isBrowserLibraryReadPhrase` → `DoraXEngine`).

Each package extraction is its own PR. When the compiler complains, it is showing a real
layering bug that already existed.

### Stage E — Break the god view (after v1.0, ongoing)
12. One surface at a time: move its `@State` out of `LauncherView` into that surface's model;
    delete the matching `LauncherView+*.swift` extension. Start with the smallest (Media
    Dock, clipboard) to learn the pattern; Ask (chat) last.
13. Split the remaining >1,500-line files as each one is touched for a real reason. Then flip
    the file-size check from *warn* to *fail*.

**Why packages and the god-view split wait until after launch:** users never see file sizes.
Refactoring before you know which surfaces people use risks polishing code you will cut. Stages
A–C are cheap and lower risk immediately; D–E are an investment you make once the product has
proven what matters. `[judgment]`

---

## 5. How work happens (people and agents)

- **One task, one branch, one PR, CI green, then merge.** `ship.sh` stays the only way to release.
- **Agents stay in their lane:** a task names the package or surface folder it may touch. Work
  that crosses packages is split into one PR per package.
- **Worktrees for risky work** (already your rule) — and required for Stage D moves.
- **Docs next to code:** each package gets a short `README.md` (job, public API, what it must
  never import). `docs/master/` stays the product-level map.
- **Weekly health line** at the top of this file:
  `files >1,500 lines · singletons · LauncherView extensions · test count · corpus pass-rate`.
  If the first three go up in a week, stop and ask why.

---

## 6. Health numbers to track

| Metric | Today `[code]` | After Stage C | After Stage E `[guess]` |
|---|---:|---:|---:|
| Files > 2,000 lines | 21 | ~18 | 0 |
| `LauncherView+*` extensions | 39 | 39 | < 8 |
| `static let shared` | 247 | ~235 | < 120 |
| UI types named in `AI/` + `Services/` | 12 files | 12 | 0 (compiler-enforced) |
| Tests run in CI | 0 | all | all + corpus score |
| Binaries in git | 18 MB DMG | 0 new | 0 |

---

## 7. Decisions only the owner can make

1. Accept local Swift packages as the enforcement mechanism? (Alternative: a lint script that
   greps imports — weaker, but no project restructuring.)
2. Rewrite git history to purge the committed DMGs, or only stop adding new ones?
3. Stages A–C before v1.0 and D–E after — or all of it after launch?

---

*Redline directly. Once accepted, CLAUDE.md's "Project structure" section is rewritten from
this file and the old folder table is removed.*
