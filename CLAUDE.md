# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## DoraX architecture rule

Never merge product layers.

- Global Context is not Chat Mode.
- Context Dock is not Global Context.
- Context Dock Chat Mode is not General Chat Mode.
- Selection Shortcut Sheet is not a launcher.
- Media Dock is not a chat surface.

Each surface must keep one job: search, frontmost app actions, general chat, app-scoped chat, media, or selection-aware actions.

Unified Dock Surface rule: one shell, multiple modes, stable state, mode-specific content. Do not create separate floating visual containers per mode; use shared shell, input, row, animation, and size rules.

Architecture truth files live in `docs/architecture/`.

## Build & run (canonical — use the script)

This is a pure Xcode project — no Makefile, no SPM package at the root.

**After every code edit, build + relaunch with the shared script — never raw `xcodebuild` + `open`:**

```bash
./scripts/dev-run.sh     # builds Debug into .build/XcodeDerivedData and relaunches THAT app
```

Why this rule exists: both Claude and Codex work in this repo (VS Code + desktop apps). Raw
`xcodebuild` writes to Xcode's hashed DerivedData while `.build/XcodeDerivedData` holds the
agents' build — launching by `find ~/Library/Developer/Xcode/DerivedData …` has shipped a
**stale app** before. `dev-run.sh` is the single source of truth for which binary runs;
Codex follows the same rule via AGENTS.md.

```bash
# Build only, no launch (same DerivedData as dev-run.sh)
./scripts/build-debug.sh

# Build for release (only via ship.sh in practice)
xcodebuild -project Context-Dock.xcodeproj -scheme Context-Dock -configuration Release build
```

In Xcode: **Cmd+B** to build, **Cmd+Shift+K** to clean first.

```bash
./scripts/test.sh        # runs the whole suite (offline: no API key, no network)
```

The suite lives in `Context-DockTests/` and uses **swift-testing** (`import Testing`, `@Test`),
not XCTest. It was long believed this project could not have automated tests — the runner
always died with "exited with code 0 before establishing connection". The cause was the app's
own single-instance guard: the test bundle loads into a second copy of Context-Dock, the
developer's copy is nearly always running, and the guard terminated the host before XCTest
could attach. The guard stands down under XCTest now (`ILauncherApp.swift`), and the tests run.

Anything needing a live model is NOT in this suite. Provider behaviour is still verified by
hand against the running app.

- **Deployment target**: macOS 26.1  
- **Swift version**: 5.0  
- **Bundle ID**: `com.krishgokul.ContextDock`  
- **External dependency**: SwiftTerm (via SPM, auto-resolved by Xcode)  
- **Second target**: `Context-DockExtension` (Safari Web Extension, `com.krishgokul.ContextDock.SafariExtension`)

## Shipping a release ("ship it")

When the user says **"ship it"** / **"release it"**, run the script — do **not** re-derive the steps:

```bash
./scripts/ship.sh        # auto-increment the build number
./scripts/ship.sh 9      # explicit build number
```

`scripts/ship.sh` is the single source of truth for releasing. In one command it: bumps the build, builds Release (serial `-jobs 1` to dodge the build.db prune flake), makes the DMG, commits + pushes the current work branch, merges into `main` and pushes it, then publishes a GitHub Release with the DMG attached (token read from the git credential store).

Preconditions the script enforces: run from a **work branch** (not `main`) with all source changes already committed; it aborts cleanly on merge conflicts. The DMG is an **unsigned** beta (no notarization) — first launch on another Mac needs right-click → Open. The in-app updater reads `update-manifest.json` from `main`.

## Project structure

The project uses `PBXFileSystemSynchronizedRootGroup` (Xcode 16). **Creating a subfolder on disk automatically creates an Xcode group** — no `project.pbxproj` edits needed when adding or moving files.

Source lives in `Context-Dock/Context-Dock/`, organised into 7 folders:

```
App/            Entry point, window, hotkeys, AppSettings
Search/         Main UI (LauncherView), search engine, result models
AI/             L2 assistant stack (intent, workflow, execution, Claude API)
Accessibility/  AX observer pipeline, context snapshots, event bus
Automation/     Cross-app routing, menu intent, app-specific macros
UI/             Reusable components (overlays, toasts, panels, settings)
Services/       All shared infrastructure — context, media, file, extensions
```

## Architecture

### Layer dependencies (top → bottom)

```
App/  ──environmentObject──►  Search/LauncherView
                                  │
               ┌──────────────────┼──────────────────┐
               ▼                  ▼                  ▼
            AI/               Automation/      Accessibility/
               └──────────────────┴──────────────────┘
                                  │
                               Services/
```

`AppDelegate` never imports Search or AI types. Data flows down via `ContextDockEnvironment` or direct method calls on `Services/` singletons.

### ContextDockEnvironment — the AppDelegate → UI bridge

`Services/ContextEngineProtocol.swift` defines:

- **`ContextEngineProtocol`** — abstracts all 20 context-reading methods from `ContextDetector`. UI code that reads context should accept `any ContextEngineProtocol`, not `ContextDetector` directly.
- **`ContextDockEnvironment: ObservableObject`** — injected into the view tree at `setupLauncherWindow()`. AppDelegate calls `userContextDidDetect(_:)` and `frontmostAppDidChange(name:bundleID:)` directly instead of posting NotificationCenter events. `LauncherView` subscribes via `.onReceive(contextEnv.userContextUpdates)` and `.onReceive(contextEnv.frontmostAppUpdates)`.

`ContextDetector` conforms to `ContextEngineProtocol` via an extension at the bottom of `ContextDetector.swift`.

### NotificationCenter — what still uses it

NC is reserved for **UI-scope coordination** only (hotkey changes, window open/close signals). All cross-layer context data now flows through `ContextDockEnvironment`. Notification names are declared in scattered `extension Notification.Name` blocks — they live in the file that first needs them, not a central registry:

| Name | Declared in |
|---|---|
| `launcherWindowOpened`, `folderPreviewShouldClose`, `userContextDetected`*, `frontmostAppDetected`* | `Search/ContentView.swift` |
| `escapePressed`, `focusSearchField`, `activateGlobalContext`, `activateClipboardScope`, `launcherBackspacePressed`, `toggleAIExtensions` | `Search/ContentView.swift` |
| `hotkeyChanged`, `chatHistoryCleared`, `activateContextDock`, `switchToL1`, `menuBarIconVisibilityChanged` | `UI/SettingsView.swift` |
| `servicesOpenWithFiles`, `servicesOpenWithText` | `App/ILauncherServicesProvider.swift` |
| `settingsImported` | `Services/SettingsBackupManager.swift` |
| `appPanelToolRemoved`, `newBinaryDiscovered` | `Services/BinaryWatcherService.swift` / `Search/ContentView.swift` |

\* `userContextDetected` and `frontmostAppDetected` exist as NC names but are **no longer posted** — AppDelegate now calls `ContextDockEnvironment.shared` directly.

### AXEventBus — accessibility events

`Accessibility/AXEventBus.swift` is a Combine `PassthroughSubject<AXEvent, Never>`. `AXEvent` cases: `appActivated`, `focusedElementChanged`, `selectedTextChanged`, `menuItemsReady`. Consumers in `CrossAppRouter` and `AXTriggerRuleEngine` subscribe to this, not to NotificationCenter.

### LauncherView state

`Search/ContentView.swift` declares the `LauncherView` struct with 420+ `@State` vars. `Search/LauncherView+Search.swift` is a Swift extension on the same struct that adds the entire search engine (`performSearch`, `detectSmartQuery`, `handleSmartQueryResult`, `findApplications`, `SmartQueryType`). Extensions on a struct have full access to `@State` vars — this is the intended pattern for splitting the file.

### Extension system layers

The app has a 3-layer extension model:
- **L1** — keyword-triggered quick actions (search bar)
- **L2** — context-triggered actions (selected files, text, app in focus); AI assistant lives here
- **L3** — browser/web context actions

`Automation/MenuIntentRouter` routes NL queries: keyword scoring first → on-device AI → cloud AI fallback.

### ContextDockStore

`Services/ContextDockStore.swift` is the file-based config store. Path: `~/Library/Application Support/Context-Dock/`. Per-app storage under `apps/{bundleId}/`. Writes are debounced 300 ms and content-hash deduplicated.

## Key conventions

**Adding a new file**: drop it in the appropriate folder; Xcode picks it up automatically.

**Adding a new cross-layer event**: prefer a method call on `ContextDockEnvironment` or a typed `PassthroughSubject`. Only add a new `Notification.Name` for UI-scope signals that have no natural owner (hotkey changes, window lifecycle).

**Reading context in a new view**: accept `any ContextEngineProtocol` via `@EnvironmentObject` (`contextEnv.engine`), not `ContextDetector.shared` directly.

**Singletons**: 68 `static let shared` instances exist. Initialisation order matters — `AppDelegate.shared` is set as the first line of `applicationDidFinishLaunching`. Do not access other singletons before that point.

**Notification name declarations are not centralised** — search for the string literal if you need to find where a name is defined.


## XcodeBuildMCP

XcodeBuildMCP is configured in `~/.claude/settings.json` and gives Claude direct Xcode control without opening the IDE:

- Build the app (xcodebuild wrapper)
- Run in simulator and launch on device  
- Capture simulator screenshots for visual debugging
- Run tests and parse structured results
- Attach debugger and inspect variables via LLDB

## Skills

These skills are installed and activate automatically based on your request:

| Task | Skill |
|---|---|
| Build / run / fix compile errors | build-run-debug |
| SwiftUI layout, scenes, navigation, state | swiftui-patterns |
| Add Liquid Glass / modern macOS 26 UI | liquid-glass |
| Run or debug tests | testing |
| AppKit bridges (NSWindow, responder chain) | appkit-interop |
| Window size, placement, toolbar, materials | window-customization |
| Refactor large views (LauncherView, ContentView) | view-refactor |
| Codesign / entitlement / sandbox errors | codesigning |
| Notarization / App Store distribution | distribution-signing |
| OSLog instrumentation | app-telemetry |
| Swift Package Manager / dependencies | swiftpm |
| GitHub PRs / issues | github |
| Address PR review comments | gh-address-comments |
| Modern SwiftUI API review (deep dive) | swiftui-pro |
| Swift 6.2 concurrency review (actors, `@concurrent`, isolation) | swift-concurrency-pro |
| App Intents / Siri / Shortcuts / Spotlight schemas | app-intents |
| Core Data stack, threading, migrations, CloudKit sync | core-data-expert |
| SwiftUI accessibility audit (VoiceOver, Dynamic Type) | swiftui-accessibility-auditor |
| UIKit accessibility audit (iOS/iPadOS) | uikit-accessibility-auditor |
| AppKit accessibility audit (macOS) | appkit-accessibility-auditor |

Note: `swiftui-pro` overlaps with `swiftui-patterns` (the former is a deep API/hygiene review skill; the latter covers app architecture/scene structure) — use whichever matches the task. Similarly, `appkit-accessibility-auditor` overlaps with `appkit-interop` (accessibility audit vs. general AppKit bridging).

Vendored (not plugin-installed) skills above live in `Context-Dock/skills/<name>/SKILL.md`, copied directly from their upstream repos:
- swiftui-pro ← https://github.com/twostraws/SwiftUI-Agent-Skill
- swift-concurrency-pro ← https://github.com/twostraws/Swift-Concurrency-Agent-Skill
- app-intents ← https://github.com/n0an/App-Intents-Agent-Skill
- core-data-expert ← https://github.com/AvdLee/Core-Data-Agent-Skill
- swiftui-accessibility-auditor, uikit-accessibility-auditor, appkit-accessibility-auditor ← https://github.com/rgmez/apple-accessibility-skills (shared docs in `skills/apple-accessibility-shared/`)

These are plain files, not yet under `.claude/skills/`, so they won't auto-trigger via the skill-discovery mechanism the plugin-installed skills above use. Move them into `.claude/skills/` (e.g. `mv skills .claude/skills`) if you want Claude Code to auto-discover them the same way.

## Apple Documentation

Always fetch current Apple docs before using any API, especially macOS 26 Tahoe APIs:

- SwiftUI: https://developer.apple.com/documentation/swiftui
- Liquid Glass (macOS 26): https://developer.apple.com/documentation/swiftui/glass-effect
- AppKit: https://developer.apple.com/documentation/appkit
- Accessibility: https://developer.apple.com/documentation/accessibility
- Safari Web Extensions: https://developer.apple.com/documentation/safariservices/safari-web-extensions

## Large Files

These files are very large - read only the relevant range:
- Search/ContentView.swift - 420+ @State vars; use awk NR>=X and NR<=Y
- Search/LauncherView+ContextualActions.swift - use same awk pattern

## Diagnosing an AI turn

OSLog is not reliable here. On the development Mac, notice-level logging from third-party
processes is not persisted — a marker emitted from a separate process under this app's
subsystem never reaches the store either, so every `log.notice("stage: …")` in the chat
pipeline is invisible. That is a `sudo log config` setting on the machine, not an app bug, and
chasing a chat bug without knowing it cost a day.

Use the app's own turn log instead. Off by default, because it names the apps and questions
somebody asks:

```bash
defaults write com.krishgokul.ContextDock doraxTurnLogEnabled -bool YES
tail -f ~/Library/Application\ Support/Context-Dock/turns.log
```

It records the two facts that settle most "why did it not do that" questions: the provider a
turn ran on and whether it carries native tools, and the exact tool names sent to the model.
A provider without native tools (Claude Code, Apple Intelligence) is handed none of DoraX's
tools by design — it answers, the app acts.

## Working alongside other agents

2-4 Claude/Codex sessions run against this repo at once. Assume a file you did not
touch is being edited by someone else **right now**, and that HEAD moves under you.

- **Never `git add -A` / `git commit -a`.** Stage explicit paths only — anything else
  sweeps up another session's half-finished work.
- **Never** `git checkout -- .`, `git stash`, `git reset --hard`, or branch switches on
  the shared tree. Those destroy uncommitted work you cannot see.
- **Re-check before you conclude.** `git log --oneline -3` and `git status` at the start
  of a task, and again before reporting counts or "this is all the usages" — both change
  mid-task.
- **Isolate risky work in a worktree** (`.claude/worktrees/`) rather than the shared tree.
- If `git status` shows modifications you did not make, leave them alone and say so.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).

## Finish the started task before taking the next one

Work in this repo is sequenced deliberately, and the sequence is the user's.

When a task or feature is underway and the user asks for something else — a new
feature, another bug, a question that turns into work — **finish the current
task first**, then take the new one. Say plainly that the new item is queued and
where it sits in the order; do not silently drop it, and do not abandon what is
half-built to chase it. A half-finished feature is worse than an unstarted one:
it looks done from the outside and nobody knows what it left behind.

The exception is the user saying to switch, or the new item making the current
task pointless. A defect found *inside* the current task is part of it and gets
fixed on the spot.

Keep the agreed order visible. When the plan is a numbered sequence, name the
task being worked on and what comes next, so the user can reorder deliberately
rather than by accident.

### The current sequence (2026-09-06)

`docs/superpowers/plans/2026-09-06-corner-general-chat-parity.md`

1. ✅ Task 1 — carry out a resolved call in every scope
2. ✅ Task 2 — a combined chat names every app it is with
3. ✅ Task 3 — corner General shows its steps
4. ✅ Task 6 — "no linked route" is not "cannot": the approval-gated command rung
5. ✅ Task 8 — ask in options, not prose
6. Worker layer (Claude Code / Codex as specialist workers, with an authority
   envelope) — its own plan, after the above
