# Plugins — phased todo plan

> **For agentic workers:** this is the roadmap, not a bite-sized plan. Each phase below gets
> its own `docs/superpowers/plans/` TDD plan (superpowers:writing-plans) when the owner starts
> it, and is executed with superpowers:subagent-driven-development or executing-plans.
> Checkboxes track phases and their exit criteria.

**Goal:** replace Global Commands and Global Extensions with one Plugin system: declarative
views rendered natively in dock, corner, strip and window; scripts for data and actions; query,
selection and clipboard as inputs; an AI Creator; packs users can install and share.

**Architecture:** JSON manifest → schema → `PluginRenderer` (one, host-agnostic) → five hosts
via `HostTraits`. `PluginScriptRunner` produces state; `PluginRegistry` indexes into search,
Selection Sheet and clipboard scope. Creator and Import both write packs to
`~/Library/Application Support/Context-Dock/plugins/`.

**Tech Stack:** Swift 5, SwiftUI + AppKit, swift-testing, existing `ContextDockStore`,
`GlobalSearchService`, `SearchPresetMerge`, `SelectionScopeExtensionPolicy`,
`ClipboardScopeService`, `AICapabilityApprovalCenter`, `TerminalView` (SwiftTerm).

**Spec:** `docs/superpowers/specs/2026-09-15-plugins-design.md`

## Global constraints

- Deployment target macOS 26.1; Swift 5.0; build with `./scripts/dev-run.sh`; tests with
  `./scripts/test.sh`, verified **by name** (memory `test-script-can-report-stale-green`).
- Never merge product layers (`CLAUDE.md`); one shell, mode-specific content.
- No live AX refresh or menu scan while typing; corner size pure from model state.
- Every script visible; Run test before Save; permissions declared and gated.
- Route A / Route B code is removed only in Phase 8, after parity tests pass.
- Work on a work branch off `general-chat-agent`; stage explicit paths only.

## Sequencing and dependencies

```
P0 decide ─► P1 model ─► P2 kit+renderer ─► P4 hosts (dock, corner, window) ─► P5 search+scopes ─► P5b chat participants ─► P6 settings+import ─► P7 creator ─► P8 migrate+delete
                     └─► P3 runtime+skills ──┘                 └─ strip host waits for #24 ─┘   └─ needs #19 resolver ─┘         └─ Engine B waits for worker layer (item 6)
```

P1–P3 are pure and testable without UI. P4 onward each ship something a user can touch.

---

## Phase 0 — decisions and ground truth  (S)

- [ ] Owner confirms or changes the eight defaults in spec §16; record each as an
      llmbrain `add_decision` with the why.
- [ ] Hand-verify #15's fix (a user extension answers to its name in the launcher; a preset
      match keeps unrelated rows). Still unverified as of 2026-09-10.
- [ ] Record the architecture decision "declarative DSL over web view / arbitrary code" and
      "Plugins is its own Settings section; Integrations keeps Apps".
- [ ] Add `docs/architecture/PLUGINS.md` (truth file, short) and a Plugins entry in
      `PRODUCT_LAYERS.md` under Global Context.

**Exit:** decisions recorded; #15 observed; truth files updated.

## Phase 1 — plugin model, schema, migration converter  (M, pure Swift)

Files: `Services/Plugins/PluginManifest.swift`, `PluginSchema.swift` (validation +
diagnostics), `PluginPack.swift`, `PluginRegistry.swift` (load, enable/disable, folder watch),
`PluginMigration.swift` (SystemCommand → manifest, UserGlobalExtension → manifest).
Tests: `Context-DockTests/Plugins/*`.

- [ ] `PluginManifest` Codable with the shape in spec §7 plus the `agent` block of §8b
      (`instructions`, `skills` paths, `tools` ⊆ actions, `inputs`); unknown component names
      decode to a diagnostic, not a throw; a `tools` entry naming no action is a diagnostic.
- [ ] `PluginSchema.validate(_:) -> [PluginDiagnostic]` covers: unknown component, missing
      binding key against `sample`, undeclared action referenced, permission implied by an
      action type but not declared (`http` → `network:<host>`), family/width enums.
- [ ] `PluginPack` reads `pack.json` + `plugins/*/manifest.json`; version compare; minAppVersion.
- [ ] `PluginRegistry` loads bundle Essentials + user folder; publishes changes; enable state
      persisted through `ContextDockStore`.
- [ ] `PluginMigration` converts all 23 built-ins and a fixture set of user commands and Route B
      extensions; keywords, icons, undo preserved; golden-file tests.

**Exit:** every existing built-in converts to a valid manifest with zero diagnostics.

## Phase 2 — component kit and renderer  (XL)

Files: `UI/Plugins/PluginRenderer.swift`, `UI/Plugins/Components/*.swift` (one file per
component group), `UI/Plugins/HostTraits.swift`, `UI/Plugins/PluginBinding.swift`
(`{{ }}` resolution), `UI/Plugins/PluginSizing.swift` (pure height function).
Tests: binding, sizing, snapshot-free layout tests (sizes and row counts), diagnostics render.

Order inside the phase — each step is user-visible in the Developer Inspector preview harness:
- [ ] Binding + `PluginSizing` (pure) + `emptyState` / `loading` / diagnostics view.
- [ ] Panel views: `list` (local + query filter), `row`, `section`, `actionPanel`, `push`.
- [ ] `listDetail` (markdown + metadata), `detail`, `grid`, `form`.
- [ ] Containers + text + chips + controls (`toggle`, `slider`, `stateButton`, `statusBadge`).
- [ ] Cards: `header`, `card`, `stat`, `eventRow`, `activityRow`, `fileRow`, `footerCard`.
- [ ] Live: `progress`, `timer`, `waveform`, `liveText`, `pulse`; `mediaCard`, `avatar`,
      `thumbnail`; `searchField`, `dropzone`; `ai`.
- [ ] Compact-width rules (corner): split→push, grid column drop, metadata stacking.
- [ ] Developer Inspector gains a "Plugin preview" region rendering any manifest in all five
      traits from `sample` data.

**Exit:** the Sonos and YouTube-thumbnail example manifests render in all five traits from
sample data; heights are pure; no component styles itself outside the kit tokens.

## Phase 3 — runtime: scripts, inputs, permissions, cache  (M)

Files: `Services/Plugins/PluginScriptRunner.swift` (replaces `UserExtensionScriptRunner` and
the runner in `CustomListProviderService`), `PluginEnvironment.swift` (all `CD_*` variables
from spec §8), `PluginPermissions.swift`, `PluginStateCache.swift`, `PluginRefreshScheduler.swift`.

- [ ] Runner: bash / applescript / jxa / scriptFile / shortcut / http(GET JSON); per-presentation
      timeouts; off-main; JSON decode with diagnostics.
- [ ] `PluginEnvironment.build(inputs:, host:)` — existing names untouched (`CD_QUERY`,
      `CD_TEXT`, `CD_URL`, `CD_APP`, `CD_ROW_*`); new: `CD_FILES`, `CD_IMAGE`, `CD_CLIP_*`,
      `CD_HOST`, `CD_WIDTH`, `CD_VALUE`. Tested for every input.
- [ ] Permissions: implied-permission derivation; first-run prompt through
      `AICapabilityApprovalCenter` for anything beyond read; network host allowlist in the env.
- [ ] Cache keyed by (plugin, query, inputs hash); `filter: local` never re-runs on typing.
- [ ] Refresh scheduler: per-presentation intervals, pause on hidden / strip shrunk, max 4 live.
- [ ] `SkillScope` gains a plugin scope (`Services/SkillScope.swift`, `SkillStore.swift`):
      a plugin's pack skills + the user's added skills, keyed by plugin id, progressive
      disclosure and pinning exactly as for a bundle id. `SkillScopeTests` extended: pinning
      does not escape the plugin scope; pack skills survive a pack update; user skills are
      stored beside the pack, not inside it.
- [ ] `PluginToolset`: a plugin's `tools` exposed to the harness as adapter actions with their
      declared `risk`; tests prove an undeclared action is never offered and a `risk` above
      read reaches `AICapabilityApprovalCenter`.

**Exit:** the migrated Listening Ports, Volume and Scratch Notes plugins run through the new
runner with identical output to today, proven by tests against recorded fixtures; a plugin
with two skills contributes two summaries to a turn and one body when pinned.

## Phase 4 — hosts: dock sheet, corner panel, window  (L)

Files: `Search/ScopedListPanel.swift` (retire `ScopedListPanelContent` in favour of
`PluginRenderer`), `Search/LauncherView+LivePanel.swift`, corner panel host in
`UI/AppChat*`, new `UI/Plugins/PluginWindow.swift` (detached, shared shell),
`Search/DockModels.swift` (row ▢ affordance).
Tests: `CornerGlobalContextParityTests` extended; window sizing tiers; ▢ routing.

- [ ] Dock result sheet hosts `panel` through the renderer; ⏎ / ⌘⏎ / ⌘K wired to `actionPanel`.
- [ ] Corner result panel hosts the same tree with compact traits; parity tests assert same
      rows, same actions, compact height pure.
- [ ] Detached window: 360 / 480 / 640 tiers, 70 % max height, shell glass; opened by ▢ or
      programmatically; ▢ falls back to the panel tree when no `window` view exists.
- [ ] Strip host (`icon`, `widget`, families, live budget) — **after #24 lands**; tracked
      there, not here.

**Exit:** a `panel` plugin behaves identically in dock and corner; ▢ opens a window; strip
host has a written seam in #24.

## Phase 5 — search, Selection Sheet, clipboard scope  (M)

Files: `Services/GlobalSearchService.swift` (`ActionSpec.plugin(id:)`),
`Search/LauncherView+Search.swift` (`SearchCandidateEligibility`, scope entry),
`Services/SelectionScopeExtensionPolicy.swift`, `Services/ClipboardScopeService.swift`,
`Search/LauncherView+ClipboardScope.swift`.

- [ ] Index plugins (name, description, keywords); merge-and-rank retained; usage learning and
      icon resolution switch cases handled (they are exhaustive by design).
- [ ] ⏎ / Tab on a `panel` plugin makes it the search scope; `"scope": false` respected; the
      sheet keeps identity while typing; scope pill shows the plugin (#22 seam).
- [ ] Selection Sheet lists plugins whose `selection.*` inputs are satisfied, ranked by
      exactness and recency, through the existing policy; never shows unsatisfied ones.
- [ ] Clipboard scope lists `clipboard.*` plugins as actions on the current item / selection
      of items; `clipboard.history` gated by permission.

**Exit:** "yt" finds the YouTube plugin; selecting a URL and long-pressing ⌘ shows it; a
clipboard-text plugin transforms the current clipboard item.

## Phase 5b — plugins as participants in General Chat  (M)

Files: `AI/GeneralChatScopeResolver.swift` (#19 — first real call site), the General Chat
participant model and scope pills (`UI/GeneralChat*`), `AI/ScopedTurnRunner` scope case,
dock/corner chat-mode scope entry.

- [ ] A plugin with an `agent` block is a resolvable participant: `@sonos …`, a scope pill,
      or the resolver picking it per step; ambiguity between two participants asks in options,
      not prose (Task 8 rule).
- [ ] The turn assembles: plugin `instructions` + skills via `SkillScope` + `PluginToolset`
      tools, on the shared harness; a combined chat names the plugin among its participants.
- [ ] Providers without native tools receive instructions and skills only; the turn log
      records the provider and the tool names sent, as it does today.
- [ ] Dock and corner input in **chat mode** can scope a plugin; search mode is untouched.
- [ ] Settings → Plugins → *plugin* → Skills: `SkillEditorSheet` reused; add from folder,
      paste, Git URL; imported skill shown in full before save.

**Exit:** "@sonos what's playing in the kitchen" answers from `data.sh` output and offers
`toggle` behind approval; the same plugin with tools removed still answers; a pasted
`SKILL.md` changes the answer style on the next turn.

## Phase 6 — Settings → Plugins, import, sources  (L)

Files: `UI/Settings/Plugins/*` (page, cards, Installed / Discover / Sources, detail with
scripts + permissions), `Services/Plugins/PluginInstaller.swift` (folder, zip, git source,
official index), `App/` URL scheme handler for `dorax://install`,
`Services/Plugins/PluginUpdateChecker.swift`.
Reuse: the install-preview pattern of `AdapterPackImportPreviewSheet`;
`IntegrationRemovalService` for removal semantics.

- [ ] Plugins section in Settings sidebar; Integrations → Global loses the Commands group.
- [ ] Installed: cards, toggle, detail (views, scripts read-only, permissions, source, version),
      remove.
- [ ] Import: drop folder / `.doraxpack`; preview lists permissions and opens every script
      before writing; unverified label.
- [ ] Sources: add Git URL; `dorax-marketplace.json` parse; pull-to-update with diff and
      permission-change highlight; official index in Discover.
- [ ] `dorax://install?...` deep link → same preview sheet.

**Exit:** a pack from a Git URL installs, shows Verified/unverified correctly, updates with a
visible diff, disables and uninstalls cleanly.

## Phase 7 — Plugin Creator, a mode of the General Chat window  (L, + Engine B later)

Depends on 5b (the Creator *is* a participant plugin).
Files: `UI/GeneralChat*` (workspace pane beside the thread: preview tabs, source editor,
versions), `UI/Plugins/Creator/*` (workspace views), the built-in Creator pack in the bundle
(`agent.instructions` = DSL spec + kit reference, `tools` = `writeManifest`, `writeScript`,
`validate`, `runTest`, `render`), `AI/PluginAuthoring/PluginAuthoringEngineAPI.swift`, later
`…EngineWorker.swift`.
Reuse: `SkillScope` for the user's Creator skills; `TerminalView` for Engine B; approval
center for `runTest` on risky actions.

- [ ] General Chat window gains a **workspace pane** (mode-specific content, same shell, same
      input); the Create-plugin workspace opens from Settings → Plugins → Add → Create, the
      Creator's strip icon, or `@creator`.
- [ ] Built-in Plugin Creator pack; its tools are jailed to the pack being edited; `runTest`
      shows the script and is the gate on Save.
- [ ] User-added Creator skills: Settings → Plugins → Plugin Creator → Skills (same sheet as
      5b); a design-system `SKILL.md` measurably changes the generated manifest in a test
      fixture (component choice, family).
- [ ] Engine A: structured-output call with images and skills; response validated by
      `PluginSchema`; diagnostics shown; retries with diagnostics appended.
- [ ] Preview tabs (five traits) from `sample`; Run test switches to live data; Save disabled
      until Run test has happened with the script visible.
- [ ] Edit with AI: element click scopes the prompt to a node id; Source edits feed back.
- [ ] Versions: every write is a version; restore.
- [ ] Preview in dock (ghost mount) — v1 if time allows, else v1.1.
- [ ] Engine B (worker in `TerminalView`, cwd jailed to the pack folder, the user's Creator
      skills mounted as its skills directory, folder watch) — **after the worker layer**
      (sequence item 6).

**Exit:** from a Sonos screenshot and one sentence typed in General Chat, the Creator
produces a plugin that renders in all five traits, runs its script on Run test, saves as a pack
findable in search, and answers `@sonos` in the same window afterwards.

## Phase 8 — Essentials pack, migration, deletion, launch seed  (M)

- [ ] Ship DoraX Essentials in the bundle (23 built-ins migrated; slider/toggle ones also get
      `widget.small`).
- [ ] First-launch migration of user commands and Route B extensions with backup; one-time
      notice listing what moved.
- [ ] Delete `SystemCommand*`, `CustomListProviderService`, `ScopedListPanelContent`,
      `UserGlobalExtension*`, `ExtensionPanelManager`, the Add Command / Add Extension sheets
      — only after parity tests pass on the migrated set.
- [ ] Seed `krishgokulk/dorax-plugins` with ~15 packs (Essentials examples, Sonos, YouTube
      thumbnail, calculator/timezone, audio-output switcher, kill port, dev utilities).
- [ ] Docs: `PLUGINS.md` final, `CLAUDE.md` sequence updated, README "write a plugin in 10
      lines" section for the Reddit launch.

**Exit:** no reference to Route A / Route B remains; suite green by name; a fresh machine
installs a pack from the official directory.

---

## Size legend

S = a session · M = 2–4 sessions · L = a week of sessions · XL = the biggest single piece;
Phase 2 is where the board becomes real and where most of the risk lives.

## Where this sits in the owner's sequence

Current sequence (`CLAUDE.md`) has item 6 = worker layer. Plugins P0–P6 do not need it;
P7 Engine B does. #24 (strip) owns the icon/widget host. Suggested placement: P0–P3 can start
now in a worktree without touching #24's files; P4+ after #24's strip host seam is written.
