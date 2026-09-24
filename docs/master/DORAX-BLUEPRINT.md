# DoraX Blueprint — the whole product on one page

> **If I had built DoraX, this is how it would be put together.** One document, seven parts:
> product → architecture → code → documents → workflow → plan → decisions.
> Each part is short and links to the detailed file behind it. Read this one first.
> Written 2026-09-24. Tags: `[code]` true in the repo today · `[judgment]` my recommendation.

---

## Part 1 — The product

| Question | Answer |
|---|---|
| **What is it?** | A Mac layer that lets you tell any app what to do. It uses that app's own controls, asks before anything risky, and proves the result. |
| **One sentence** | *Tell your Mac what to do, in any app — it uses the app's own controls, asks first, and proves it worked.* |
| **First users** | Mac developers who already use Claude Code or Codex. |
| **Why it wins** | Raycast and Alfred need someone to write an extension per app. DoraX reads any app's live menus and verifies every action. `[code]` |
| **What the user sees** | Three verbs: **Find** (⌘⌘ double-press Command) · **Ask** (App Chat / Chat Window hotkeys, set by the user) · **Act on this** (selection auto-scopes on launch, or the Selection Scope hotkey) — see [Hotkeys as built](00-COMPLETE-APP-PLAN.md#hotkeys-as-built-code) |
| **Names (owner decision 2026-09-24)** | The system-wide chat is **General Chat** — never "AI Assistant", "AI Assistant Mode" or "DoraX Action Chat". The chat scoped to one app is **App Chat**. Still wrong in the app `[code]`: `GeneralSettingsPage.swift:104` "AI Assistant Mode", `DataStorageSettingsPage.swift:69` "AI Assistant History", `HotkeysSettingsPage.swift:291` Navigation chip, `LauncherView+LivePanel.swift:1400` and `:1546`, `LegacySettingsContent.swift:439`; and in `docs/architecture/` PRODUCT_LAYERS, UI_RULES, UNIFIED_DOCK_SURFACE |
| **v1 includes** | Launcher basics (apps, files, calculator, conversions, quicklinks, clipboard, windows, hotkeys, ⌘K actions) + app-scoped and cross-app AI with verified actions + onboarding + signed install |
| **Later (Labs)** | Memory vault, dashboard, coding-agent workers, media dock, drop shelf |
| **Never** | Visual workflow editor, own extension store (MCP is the store), acting without asking |
| **Business** | Free core; Pro for cloud AI, saved workflows, Labs. Users bring their own AI key. |

Detail → [`00-COMPLETE-APP-PLAN.md`](00-COMPLETE-APP-PLAN.md) (every feature with a "done when" test) ·
[`00-PRODUCT-PLAN.md`](00-PRODUCT-PLAN.md) (launch and trust)

---

## Part 2 — The architecture

### 2.1 Five layers, one direction

```
┌──────────────────────────── APP (what you see) ────────────────────────────┐
│  Find          Ask            Act on this        Settings     Onboarding     │
│  └──────────── one Shell: one window, one input, one row style ───────────┘ │
└────────────────────────────────────┬────────────────────────────────────────┘
                                     ▼ uses
      ┌──────────────┬───────────────┴───────────┬─────────────────┐
      │  ENGINE      │  CAPABILITIES             │  MEMORY         │
      │  thinks      │  does                     │  remembers      │
      │  providers,  │  menus, adapters, MCP,    │  Markdown vault │
      │  routing,    │  Shortcuts, terminal,     │                 │
      │  plans,      │  files, Apple apps        │                 │
      │  verify,     │                           │                 │
      │  approve     │                           │                 │
      └──────┬───────┴─────────────┬─────────────┴────────┬────────┘
             ▼                     ▼                      ▼
                 CONTEXT — sees: frontmost app, selection, menus, web page
                                     ▼
                 CORE — shared models, storage, keychain, logs
```

**The one rule:** a layer may only use layers **below** it. Each lower box is a Swift package,
so breaking the rule is a compile error, not a code-review comment. `[judgment]`

### 2.2 One shape for every feature: the `Command`

Every feature — an app, a file, a menu item, a quicklink, a script, an AI capability — is a
`Command` (id, title, keywords, icon, risk, actions, run → result + verification status) in
**one registry**. Find lists commands, Ask gives them to the model as tools, Act on this filters
them by selection type, hotkeys and aliases attach to a command id. A new feature appears
everywhere without extra wiring. The existing `CapabilityRegistry` is the starting point. `[code]`

### 2.3 One path for every AI request

```
request → pick scope → ground (what this app can do) → choose route
        → run (tool loop · plan · tool-less) → approval if risky
        → verify (read back) → answer with ✓ verified / ⚠ unconfirmed / ✗ contradicted
```

All of this exists today in `AppScopedChatService`, `ScopedTurnRunner`, `ApprovalCenter` and
the verifiers. `[code — docs 03, 08]`

Detail → [`08-AI-ENGINE.md`](08-AI-ENGINE.md) · [`10-CROSS-CUTTING.md`](10-CROSS-CUTTING.md)

---

## Part 3 — The code

### 3.1 Repository

```
Context-Dock/
├── Context-Dock/            the app: UI only
│   ├── App/                 startup, hotkeys, routing
│   ├── Shell/               the one dock shell + shared components
│   ├── Surfaces/
│   │   ├── Find/            Global Context + Context Dock
│   │   ├── Ask/             chat in the dock and in the window
│   │   ├── ActOnThis/       selection + clipboard
│   │   └── Labs/            off by default
│   ├── Settings/            one file per page
│   └── Onboarding/
├── Packages/
│   ├── DoraXCore/           models, storage, keychain, logs
│   ├── DoraXContext/        accessibility, selection, web, apps
│   ├── DoraXCapabilities/   menus, adapters, MCP, terminal, files
│   ├── DoraXEngine/         providers, routing, loop, planner, verify, approval
│   └── DoraXMemory/         vault
├── Context-DockTests/       app-level tests
├── Context-DockExtension/   Safari extension
├── docs/                    Part 4
├── scripts/                 dev-run, check, test, ship
└── .github/                 CI, PR template, issue templates
```

### 3.2 Code rules (enforced by tools, not memory)

| Rule | Enforced by |
|---|---|
| Lower layers never import upper ones | Swift packages |
| No file over 1,500 lines | `scripts/check.sh` in CI |
| One state model per surface; `LauncherView` only routes | code review + file-size check |
| No new singletons; pass dependencies in | review |
| Every change has a test | PR template + CI |
| No binaries in git | `.gitignore` + CI |

**Where a new file goes:** draws pixels → app · talks to a model → Engine · acts in another app →
Capabilities · reads the screen → Context · touches memory → Memory · plain data → Core.

**Today vs target:** 587 files / ~248k lines; `Search/` holds 83k lines of mixed UI; 39
`LauncherView+*` files share one view; 21 files > 2,000 lines; 12 engine/service files reach
into the UI. `[code]` The move is staged so the app builds after every step.

Detail → [`00-APP-STRUCTURE.md`](00-APP-STRUCTURE.md) (every file mapped) ·
[`00-CODEBASE-PLAN.md`](00-CODEBASE-PLAN.md) (rules + migration order)

---

## Part 4 — The documents: where everything is saved

### 4.1 One tree, one index

```
docs/
├── README.md                 ← START HERE: what each folder is, reading order
├── product/                  WHY and WHAT
│   ├── vision.md             one sentence, first users, what we are not
│   ├── features.md           every feature with its id (F1…, A1…, S1…, B1…) and "done when"
│   ├── roadmap.md            releases, milestones, health line
│   ├── competitors.md        Raycast, Alfred, Siri — kept current
│   └── pricing.md
├── architecture/             HOW it is built (true today)
│   ├── overview.md           Part 2 of this blueprint, expanded
│   ├── layers.md             product layers + package rules (today's PRODUCT_LAYERS.md)
│   ├── engine.md  capabilities.md  context.md  memory.md
│   ├── security.md  performance.md  privacy.md
├── surfaces/                 WHAT each surface does, for users and code
│   ├── find.md  ask.md  act-on-this.md  labs.md
├── engineering/              HOW we work
│   ├── workflow.md           the life of a change, roles, agents
│   ├── codebase.md           code rules, structure, naming
│   ├── testing.md            test types, golden corpus, how to run
│   └── release.md            beta/stable, signing, ship.sh
├── decisions/                WHY we chose it — one short file per decision
│   └── 0001-swift-packages-for-layers.md …
├── specs/                    one per feature, written before building
├── plans/                    one per feature, step by step, linked to its issue
├── runbooks/                 do-this-when: ship a release, diagnose an AI turn, notarize
├── history/                  finished audits, old plans — read-only
└── assets/                   images, diagrams, mockups
```

Today's files map in naturally: `docs/master/01–10` → `surfaces/` + `architecture/`;
`docs/architecture/*` → `architecture/`; `docs/superpowers/specs|plans` → `specs/` + `plans/`;
`DECISIONS.md` → `decisions/`; `FOUND.md`, `PRERELEASE_AUDIT.md`, `CONTEXT.md` → `history/`;
PNG/PDF/HTML at the repo root → `assets/`.

### 4.2 Document rules

1. **Every doc starts with a header:** status (draft / current / retired), last checked date,
   the code it describes.
2. **One topic per doc.** If you need "and" in the title, it is two docs.
3. **Claims are tagged** `[code]` / `[owner]` / `[?]` — the method `docs/master` already uses. Keep it.
4. **Docs change in the same PR as the code.** The PR template has a box for it.
5. **Specs and plans are temporary; architecture docs are permanent.** When a feature ships, its
   spec's lasting content moves into `architecture/` or `surfaces/`, and the spec moves to `history/`.
6. **Agent instructions** (`AGENTS.md`, one file for Claude and Codex) point to `docs/README.md`
   instead of copying its content.

---

## Part 5 — How the work gets done

```
Issue ──► (Plan, if > 1 day) ──► Builder agent in its own worktree ──► check.sh
  │                                                                      │
  │   feature id + "done when" + lane                                    ▼
  │                                                         Pull request (template)
  │                                                                      │
  │                                     CI: build · tests · corpus score · file size
  │                                                                      │
  │                                  Reviewer agent ──► Builder fixes ──► Owner tries it
  ▼                                                                      │
Milestone = release  ◄──── squash-merge to protected main ◄──────────────┘
                              │
                              ▼  every 2 weeks: beta · monthly: stable (ship.sh from main)
```

| Who | Does | Never |
|---|---|---|
| **You (owner)** | decide, approve plans, merge, release | — |
| **Planner agent** | writes spec + plan from an issue | writes app code |
| **Builder agent** | one issue, one worktree, one lane | touches other lanes, pushes to `main`, runs `ship.sh` |
| **Reviewer agent** | reviews the PR in a fresh session | fixes what it reviewed |

Max **3 builders at once** — your review time is the limit. Agents get tests, small fixes, docs
freely; features only with an approved plan; security code, releases and merges stay with you.

**Urgent today** `[code]`: `.claude/settings.json` pre-approves `./scripts/ship.sh` and
`rm -rf ~/Library/Caches/*` — any agent can publish a release without asking. Turn those into
deny rules first.

Detail → [`00-ENGINEERING-OPERATING-MODEL.md`](00-ENGINEERING-OPERATING-MODEL.md)

---

## Part 6 — The plan to success

| Phase | Weeks | Goal | Done when |
|---|---|---|---|
| **0 · Decide** | 1 | Answer Part 7 | This blueprint has your redlines |
| **1 · Safe workflow** | 1 | Permissions fixed, one `AGENTS.md`, tests in CI, `main` protected, issues + milestone 1.0 | Every change goes through a PR with green CI |
| **2 · Freeze & tidy** | 2 | Labs switch, cut surfaces hidden, dead router deleted, files moved into `Surfaces/` (no logic change), docs moved into Part 4 tree | App shows only Find / Ask / Act on this |
| **3 · Trust** | 2 | Developer ID + notarization, signed updates, open security items closed | Installs on a clean Mac with no warning |
| **4 · Table stakes** | 3 | Calculator, conversions, quicklinks, hotkeys + aliases, ⌘K panel, Tab-to-Ask | A Raycast user finds nothing basic missing |
| **5 · First run + hero** | 2 | Onboarding, the "test it → fixed ✓" loop flawless, 60-second video | 5 people succeed in < 2 min alone |
| **6 · Private beta** | 3 | 20–50 developers, opt-in crash + usage data, weekly fixes | Crash-free ≥ 99.5 %; corpus score tracked |
| **7 · Launch 1.0** | 1 | Show HN, r/macapps, X | v1 checklist fully ticked |
| **After launch** | ongoing | Swift packages, break up `LauncherView`, Labs features graduate by usage | Health numbers improve each release |

**About 15 weeks** for one person with agents `[judgment — estimate]`.

**Numbers to watch** (one line at the top of `product/roadmap.md`, updated each release):
users · crash-free % · first-result accuracy in Find · AI corpus pass-rate · files > 1,500 lines · open security issues.

---

## Part 7 — Your decisions (all plans combined)

| # | Decision | My recommendation |
|---|---|---|
| 1 | The one sentence in Part 1 | Accept or rewrite it — everything follows from it |
| 2 | First users | Mac developers with coding agents |
| 3 | Scope | Three verbs; Media Dock cut; memory, workers, plugins → Labs |
| 4 | Strategy vs Raycast | Match the basics, invest in the edge; MCP instead of an own store |
| 5 | Architecture | Swift packages enforce the layers; one `Command` model |
| 6 | Documents | One `docs/` tree as in Part 4 |
| 7 | Workflow | GitHub Issues as the one queue; protected `main`; agents never run `ship.sh` |
| 8 | Apple Developer ID ($99/yr) | Yes — no product without it |
| 9 | Opt-in telemetry | Yes — otherwise the beta is guesswork |
| 10 | License | Decide open vs closed (README and update notes disagree today) |
| 11 | Release rhythm | Beta every 2 weeks, stable monthly |

**Owner's answers (2026-09-24):** all eleven recommendations accepted as written. #8 — yes,
bought later (Phase 3). The ~15-week plan in Part 6 stands, with no fixed launch deadline
(1.0 around early January 2027).

---

*This file replaces reading five plans. When you have answered Part 7, it becomes
`docs/README.md`, the other `00-*` files move into the Part 4 tree, and Phase 1 starts.*
