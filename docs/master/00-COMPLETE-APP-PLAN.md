# 00 — Complete App Plan: every feature, measured against Raycast and Alfred

> **Status: PROPOSAL — written as if I owned DoraX.** This is the master feature plan. It sits
> above [`00-PRODUCT-PLAN.md`](00-PRODUCT-PLAN.md) (why + launch),
> [`00-CODEBASE-PLAN.md`](00-CODEBASE-PLAN.md) (code rules) and
> [`00-APP-STRUCTURE.md`](00-APP-STRUCTURE.md) (folders).
> Tags: `[code]` found in this repo · `[ext]` public info about Raycast/Alfred · `[judgment]` my call · `[?]` verify.
> Written 2026-09-24 against `main` @ `341494a`.

---

## 0. Read this first: do not clone Raycast

Raycast has a funded team, years of polish, and a store with hundreds of extensions (GitHub,
Linear, Jira, Notion, Slack, Spotify…). `[ext]` Alfred has over a decade of loyal users. A solo
developer who copies their feature list arrives, a year later, with a worse Raycast.

Look at **how** they reach other apps: Raycast needs someone to write an extension for each
app; Alfred needs someone to write a workflow. **If nobody wrote one, the app is invisible to
them.**

DoraX is built the other way round. It reads **any** app's live menus, drives them directly,
routes through that app's own adapters/MCP/Shortcuts, and **checks the result**. `[code — 01 §8, 03 §5, 10 §1]`

> **Raycast needs an extension for every app. DoraX already speaks every app — and proves what it did.**

So the plan has two halves:
1. **Table stakes** — the launcher basics a Raycast/Alfred user expects on day one. Without
   them nobody switches, however good the AI is. Match them; do not try to beat them.
2. **The edge** — the things only DoraX does. Put all the ambition here.

---

## 1. Feature matrix

Legend — **DoraX today:** ✅ exists `[code]` · 🟡 partial / unclear · ❌ missing.
**v1 decision:** **Must** (ships in 1.0) · **1.x** (soon after) · **Later** · **Never**.

### 1.1 Table stakes — the launcher

| Feature | Raycast `[ext]` | Alfred `[ext]` | DoraX today | v1 decision |
|---|:-:|:-:|:-:|:-:|
| Launch apps, fuzzy + learned ranking | ✓ | ✓ | ✅ `GlobalSearchService` (`learnedUsageBoost`) | **Must** |
| File search + Quick Look | ✓ | ✓ | ✅ `FileIndexManager`, `Preview/` | **Must** |
| File navigation & file actions (move, copy, reveal, share) | ✓ | ✓ Powerpack | ✅ `Finder*` services | **Must** |
| System commands (sleep, lock, empty trash, quit all…) | ✓ | ✓ | ✅ `SystemCommands.swift` | **Must** |
| Web search + custom search engines | ✓ | ✓ | 🟡 web fallback exists; custom engines `[?]` | **Must** |
| **Calculator** (inline answer as you type) | ✓ | ✓ | 🟡 references exist; `01 §4` audit says none in Global Context `[?]` | **Must** |
| **Unit / currency / time-zone conversion** | ✓ | 🟡 | 🟡 one file mentions it | **Must** |
| **Quicklinks** (saved URLs/paths with `{query}`) | ✓ | ✓ (custom searches) | ❌ | **Must** |
| Clipboard history (text, images, files, links) | ✓ | ✓ Powerpack | ✅ `ClipboardPanelWindow` | **Must** |
| …skips password-manager clips | ✓ | ✓ | ✅ `org.nspasteboard.ConcealedType` (`LauncherView+ContextLifecycle.swift:2221`) | **Must** |
| **Snippets / text expansion** | ✓ | ✓ Powerpack | ❌ none found | **1.x** |
| Window management (halves, thirds, snap zones) | ✓ | via workflows | ✅ `SnapLayout`, `WindowManagementService` | **Must** |
| **Per-command hotkeys + aliases** | ✓ | ✓ | 🟡 app hotkeys exist; per-command `[?]` | **Must** |
| Favorites / pinned results | ✓ | ✓ | ✅ `DockPinStore`, `PinnedAppsRow` | **Must** |
| Fallback commands (what shows when nothing matches) | ✓ | ✓ | 🟡 | **Must** |
| **Action panel on every result (⌘K)** | ✓ | ✓ (→ actions) | 🟡 per-surface, not uniform | **Must** |
| Emoji & symbol picker | ✓ | ❌ | ❌ | **1.x** |
| Floating notes | ✓ | ❌ | ✅ `QuickNotesStore` | **1.x** (Labs until then) |
| Calendar / reminders glance | ✓ | ❌ | ✅ EventKit tools | **Must** (in Find) |
| Menu-bar item search for the front app | ✓ (extension) | ❌ | ✅ **deeper** — live AX menu tree + cache | **Must** (edge) |
| Script commands (bash/python) | ✓ | ✓ | ✅ `L2ExtensionManager` | **Must** |
| Visual workflow builder | ❌ | ✓ | ❌ (DoraX saves recipes from chat instead) | **Never** |
| Extension store | ✓ (large) | ✓ (gallery) | ❌ | **Never** (use MCP — §5) |
| Themes | ✓ | ✓ | ❌ | **Later** |
| Settings sync across Macs | ✓ Pro | ✓ (Dropbox) | ❌ (`SettingsBackupManager` export only) | **Later** |
| Teams / shared commands | ✓ | ❌ | ❌ | **Never** (for now) |
| Import from Raycast / Alfred (quicklinks, snippets) | — | — | ❌ | **1.x** — cheap way to win switchers |

### 1.2 AI — where Raycast and Alfred have bolted it on

| Capability | Raycast `[ext]` | Alfred `[ext]` | DoraX today | v1 |
|---|:-:|:-:|:-:|:-:|
| AI chat with model choice | ✓ | 🟡 (ChatGPT workflow) | ✅ 11 providers (`08 §2`) | **Must** |
| On-device model by default, no key needed | 🟡 | ❌ | ✅ Apple Foundation Models | **Must** |
| Bring your own key / local models (Ollama, LM Studio) | ✓ | 🟡 | ✅ | **Must** |
| AI presets ("fix grammar", "explain", "translate") on selection | ✓ AI Commands | via workflows | 🟡 built-ins (`summarize`…) | **Must** |
| Tab from search to AI with the query | ✓ | ❌ | 🟡 separate surfaces | **Must** |
| Tool use through MCP | ✓ | ❌ | ✅ per-app MCP linking | **Must** |

### 1.3 The edge — only DoraX

| Capability | DoraX today | v1 |
|---|:-:|:-:|
| **Chat scoped to the app in front of you** ("this app") | ✅ `03` | **Must** — headline |
| **Drive any app through its live menu**, no extension needed | ✅ `MenuExecutionCoordinator` | **Must** — headline |
| **Verified actions** — success only after read-back; `contradicted` when disproven | ✅ `CommandOutcomeVerifier`, `VerificationStatus` | **Must** — headline |
| Route order: app's own action → menu → MCP → Shortcut → CLI last | ✅ `ScopedAppPromptBuilder` | **Must** |
| Multi-step plans that cannot contain invented steps | ✅ `ChatPlanRunner` | **Must** |
| Save a plan that worked → replay by name | ✅ `WorkflowRecipe` | **Must** |
| One approval inbox, per-route authority, hard-deny for critical | ✅ `ApprovalCenter`, `AppAccessLevel` | **Must** |
| Receipts: what ran, when, exit status | ✅ `TaskRunStore`, daily brief | **Must** (visible history) |
| Cost ledger per turn | ✅ `AITokenLedger` | **1.x** (Settings → Usage) |
| Hand a coding problem to Claude Code / Codex inside an authority envelope | ✅ built, Release build blocked (#25) | **Labs** |
| Memory vault you own (Markdown, Obsidian-compatible) | ✅ `09` | **Labs** |

**Reading the matrix:** DoraX is already ahead of Raycast on everything in §1.3 and level on most
of §1.2. The v1 gap is **six small table-stakes items**: calculator, conversions, quicklinks,
per-command hotkeys/aliases, a uniform ⌘K action panel, and Tab-to-AI. Those six are what stop a
Raycast user from switching. `[judgment]`

---

## 2. The complete v1 functionality — by what the user does

Every feature belongs to one of three verbs (`00-PRODUCT-PLAN.md §2`). Each item lists its
**acceptance test** — how we know it is done.

### Hotkeys as built `[code]`

Read from `UI/Settings/HotkeysSettingsPage.swift` and `App/AppSettings.swift` (2026-09-24).
**The app is the source of truth** — if this table and Settings → Hotkeys disagree, fix the table.

| Action | Default | Where to change |
|---|---|---|
| Open Global Context in the corner | **⌘⌘ double-press Command** (on) | Hotkeys → Launch Shortcut |
| Show the launcher | **⌥⌥ double-press Option** (on) | Hotkeys → Launch Shortcut |
| Global Context (extra shortcut) | unset | Hotkeys → Custom Shortcuts |
| App Chat (ask the frontmost app) | unset | Hotkeys → Custom Shortcuts |
| Chat Window (General Chat) | unset | Hotkeys → Custom Shortcuts |
| Selection Scope | unset — while unset, a selection auto-scopes on every launch | Hotkeys → Custom Shortcuts |
| Clipboard Scope | unset | Hotkeys → Custom Shortcuts |
| Quick Note | unset | Hotkeys → Custom Shortcuts |
| Capture Text / Capture Area / Screenshot | unset | Hotkeys → Custom Shortcuts |

The old "long-press ⌘ opens the Selection Shortcut Sheet" was **removed**; ⌘ only tap-toggles
scope now (`Search/LauncherView+KeyboardNavigation.swift`, around line 1303).
Earlier drafts of these plans proposed ⌥Space / ⌥⌘Space / hold-⌘ — those were never in the app.
Whether Ask should get a default hotkey is an open owner decision.

### 2.1 FIND — `⌘⌘` (double-press Command) `[code: today's default]`

One root search. Everything is findable from here.

| # | Feature | Behaviour | Done when |
|---|---|---|---|
| F1 | Root search | Apps, files, commands, front-app menus, quicklinks, scripts, system commands, calendar — one ranked list | Top result is what the user runs ≥ 80% of the time (measured in beta) |
| F2 | Front app first | When opened over an app, its menu commands rank at the top (today's Context Dock) | Opening over Safari and typing "tab" shows Safari's tab commands first |
| F3 | Inline answers | Calculator, unit/currency/time-zone conversion answered in the first row as you type | `12*7` → `84` in < 16 ms; Enter copies |
| F4 | Quicklinks | `gh {query}` → `https://github.com/search?q=…`; also folders and app deep links | Create, edit, alias, hotkey; import from Raycast/Alfred JSON |
| F5 | Action panel `⌘K` | Every row, every surface: same panel — Open, Reveal, Copy, Ask about this, Pin, Assign hotkey, Add alias | Identical keyboard behaviour on apps, files, menus, clips |
| F6 | Hotkeys & aliases | Any command can get a global hotkey or a short alias | Assign from `⌘K`; conflicts detected and shown |
| F7 | Tab → Ask | Tab sends the typed text to Ask with the current app as scope | Query survives the hand-off unchanged |
| F8 | Fallbacks | No match → "Ask DoraX", "Search web", "Search files for…" | Never an empty screen |
| F9 | Window layouts | "left half", "center", snap zones | Works on multi-display |
| F10 | System & scripts | System commands + user script commands in root search | Script output shown inline or as a toast |

Performance budget: open < 100 ms, keystroke → results < 16 ms, **no AX scan while typing**
(existing rule, `PERFORMANCE_RULES.md`).

### 2.2 ASK — App Chat / Chat Window hotkeys (unset by default), or Tab from Find `[proposal]`

One chat. A **scope chip** at the top: `This app · These apps · Everywhere`.

| # | Feature | Behaviour | Done when |
|---|---|---|---|
| A1 | Scope chip | Defaults to the app you came from; one click widens | Scope visible on every message, even after change (`messageApps`) |
| A2 | Answer or act | Answers questions; performs actions through the route order | Every action shows its route (menu / adapter / MCP / Shortcut / CLI) |
| A3 | Verified result | ✓ verified · ⚠ unconfirmed · ✗ contradicted — on every action | No green tick without a read-back |
| A4 | Approvals | One inbox, one card style; "always allow" is per route | Approval cannot be bypassed from any surface (tested) |
| A5 | Multi-step | Shows the plan before running; each step ticks off live | A failed step stops the plan with a reason |
| A6 | Save & replay | "save that as X" → "run X"; re-resolves steps against today's Mac | Replay refuses a step whose capability is gone, with a reason |
| A7 | Attachments | Files, images (seen, not just OCR'd), selection, Finder folder | Attached items shown as chips |
| A8 | Providers | On-device default; add Anthropic / OpenAI / Ollama keys in Settings | Works with zero keys configured |
| A9 | History | Threads per scope; search history | Reopening a thread restores its scope |
| A10 | Enable an app | "Enable Notes for this chat" one-tap grant | Grant visible and revocable |

### 2.3 ACT ON THIS — selection auto-scopes on launch, or the Selection Scope hotkey (unset by default)

Whatever is selected or just copied.

| # | Feature | Behaviour | Done when |
|---|---|---|---|
| S1 | Selection card | Selected text / file / URL / image read while the source app is still in front | Works in Safari, Mail, Notes, Finder, Xcode, VS Code |
| S2 | AI presets | Fix grammar, summarise, translate, explain, rewrite shorter — user-editable | Result replaces selection or copies, user's choice |
| S3 | Send to | Notes, Reminders, Mail, a chat, a quicklink, a script | Uses the same route order and verification as Ask |
| S4 | Clipboard history | Pill on copy → card of recent clips; search, pin, paste as plain text | Password-manager clips never stored (already true) |
| S5 | Retention | Keep for 1 day / 7 days / 30 days / forever; "Clear all" | Setting honoured across restarts |
| S6 | Snippets (1.x) | `;addr` expands anywhere; placeholders `{date}`, `{clipboard}`, `{cursor}` | Expansion works in any text field |

### 2.4 FOUNDATION — what every surface relies on

| # | Feature | Done when |
|---|---|---|
| B1 | **Onboarding** — welcome, Accessibility with live ✓, provider choice, one guided task that ends in ✓ verified, teach the 3 hotkeys | A new user succeeds in < 2 min |
| B2 | **Settings** — General · Hotkeys · Find · Ask & Providers · Act on this · Apps & Integrations · Privacy · Labs · Updates · About | Every setting findable from Find ("settings hotkeys") |
| B3 | **Signed, notarized install + signed updates** | No Gatekeeper warning; update verified before opening |
| B4 | **Privacy** — what leaves the Mac, per provider; private data to local models only (already true for Safari) | Privacy page in app + website |
| B5 | **Receipts & history** — what DoraX did today, with status | Every action traceable |
| B6 | **Feedback** — "Report a problem" with version + optional turn log | One click, user sees what is sent |
| B7 | **Accessibility** — VoiceOver labels, full keyboard, Dynamic Type where SwiftUI allows | Audit passes (`appkit-accessibility-auditor` skill) |
| B8 | **Crash reporting + usage counts (opt-in)** | Crash-free % and per-feature use visible to the owner |

---

## 3. Interaction rules (what makes Raycast *feel* good)

1. **Keyboard first.** Every action reachable without the mouse; mouse works too.
2. **One action panel (`⌘K`) everywhere.** Same shortcut, same order, every row.
3. **Esc always goes back one level**, never loses typed text; a second Esc closes.
4. **Nothing moves under the cursor.** Results update in place; the shell never resizes on a keypress (existing Unified Dock Surface rule).
5. **Instant first, smart second.** Cached results in < 16 ms; AI and live AX only after the user pauses or presses Enter.
6. **Every result says what it is** — icon + subtitle ("Menu · Safari", "Quicklink", "Script").
7. **Honest status.** ✓ verified / ⚠ unconfirmed / ✗ contradicted — the DoraX signature.
8. **One visual language** — Liquid Glass shell, one row style, one card style, one toast style.

---

## 4. How features are built — one Command model

Raycast's secret is that *everything* is a command in one list. DoraX already has half of this:
the `CapabilityRegistry` the AI ranks over. `[code — 07 §5]` Make it the single source for the
user **and** the AI:

```swift
// DoraXCore — the one shape every feature takes  [judgment — illustrative]
struct Command: Identifiable {
    let id: String                 // "system.lock", "quicklink.github", "menu.safari.new-tab"
    let title: String              // shown in Find
    let keywords: [String]         // search + AI matching
    let icon: IconSource
    let kind: Kind                 // app, file, menu, system, quicklink, script, capability…
    let risk: RiskLevel            // drives approval (existing AICapabilityRiskLevel)
    let actions: [CommandAction]   // what ⌘K shows
    let run: (CommandInput) async throws -> CommandResult   // result carries VerificationStatus
}
```

- **Find** lists `Command`s ranked for a query.
- **Ask** gives the same `Command`s to the model as tools (via `find_capability` / `run_capability`).
- **Act on this** filters `Command`s that accept the selection's type.
- Hotkeys, aliases, favourites, usage learning attach to a `Command.id` — once, for every feature.

One registry means a new feature appears in search, in chat, in ⌘K and in hotkeys **without extra
wiring**. That is how a small team ships like a big one.

---

## 5. Extensions: MCP is the store

Do **not** build a proprietary extension store — that is Raycast's moat and a multi-year
project. Instead, three layers, all already partly built:

| Layer | Who writes it | Exists? |
|---|---|---|
| **Script commands** — a folder with `extension.json` + a script | power users | ✅ `L2ExtensionManager` |
| **MCP servers** — the open standard; hundreds already exist for GitHub, Linear, Notion, Slack… | the whole industry | ✅ `MCPServerManager`, per-app linking |
| **Adapter packs** — per-app bundles (actions + MCP + Shortcuts + skills), shareable as a file | DoraX + community | ✅ `AdapterPackImporter` |

Plan: a **Discover** page in Settings → Apps & Integrations that lists recommended MCP servers
and adapter packs per installed app, with one-click install. Every MCP server written for any AI
tool becomes a DoraX extension for free. `[judgment]`

---

## 6. Release plan

| Release | Contents | Gate |
|---|---|---|
| **1.0** | Every **Must** in §1 and §2 · onboarding · signed install/updates · privacy · receipts | `00-PRODUCT-PLAN.md §5` checklist |
| **1.1** | Snippets · emoji picker · import from Raycast/Alfred · cost page · floating notes out of Labs | 1.0 crash-free ≥ 99.5% |
| **1.2** | MCP/adapter-pack Discover page · themes · usage-driven ranking tweaks | Beta data says which apps people link |
| **2.0** | Settings sync · memory vault out of Labs · worker hand-off out of Labs | Paid tier live |

---

## 7. What DoraX will never be

- A visual workflow editor (plans come from plain language instead).
- A proprietary extension store (MCP is the store).
- An autonomous agent that acts without asking.
- A notes app, a browser, an editor, a chat app — it carries work **between** them.

---

## 8. Pricing — a starting point `[ext / judgment]`

Raycast: free core, paid Pro subscription for AI and sync. Alfred: free core, one-time Powerpack
licence. `[ext — exact prices change; check before deciding]`

DoraX proposal:
- **Free:** all of Find, Act on this, clipboard, quicklinks, window layouts, on-device Ask.
- **Pro (subscription or one-time `[owner decision]`):** cloud providers with your own key,
  saved workflows, multi-app plans, receipts history beyond 7 days, Labs.
- BYO key means no AI cost for DoraX to carry — price can undercut Raycast Pro.

---

## 9. Corrections to earlier plan docs

- `00-PRODUCT-PLAN.md §4.5` asked for skipping password-manager clips — **already done**
  (`org.nspasteboard.ConcealedType` at `Search/LauncherView+ContextLifecycle.swift:2221`).
  Remaining: retention setting + "Clear all".

---

## 10. Owner decisions

1. Accept "don't clone Raycast — table stakes + edge" as the strategy?
2. Accept the six table-stakes additions as v1 **Must** (calculator, conversions, quicklinks,
   hotkeys/aliases, ⌘K panel, Tab-to-AI)?
3. Accept MCP instead of an own extension store?
4. Accept one `Command` model shared by Find, Ask and Act on this?
5. Free / Pro split as in §8, subscription or one-time?

*Redline directly. Once accepted, this file is the feature source of truth; every PR names the
feature id it implements (F1…F10, A1…A10, S1…S6, B1…B8).*
