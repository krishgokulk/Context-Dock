# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

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

## Build

This is a pure Xcode project — no Makefile, no SPM package at the root.

**After every code edit, build + relaunch with the shared script — never raw `xcodebuild` + `open`:**

```bash
./scripts/dev-run.sh     # builds Debug into .build/XcodeDerivedData and relaunches THAT app
```

Why this rule exists: both Codex and Claude work in this repo (VS Code + desktop apps). Raw
`xcodebuild` writes to Xcode's hashed DerivedData while `.build/XcodeDerivedData` holds the
agents' build — launching a `~/Library/Developer/Xcode/DerivedData` path has shipped a
**stale app** before. `dev-run.sh` is the single source of truth for which binary runs;
Claude follows the same rule via CLAUDE.md.

```bash
# Build only, no launch (same DerivedData as dev-run.sh)
./scripts/build-debug.sh

# Build for release (only via ship.sh in practice)
xcodebuild -project Context-Dock.xcodeproj -scheme Context-Dock -configuration Release build
```

In Xcode: **Cmd+B** to build, **Cmd+Shift+K** to clean first. There are no automated tests — all verification is manual via the running app.

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
AI/             L2 assistant stack (intent, workflow, execution, Codex API)
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

XcodeBuildMCP is configured in .codex/config.toml and gives Codex direct Xcode control:

- Build the app (xcodebuild wrapper)
- Run in simulator and launch on device
- Capture simulator screenshots for visual debugging
- Run tests and parse structured results
- Attach debugger and inspect variables via LLDB

## Skills (Claude Code)

If Claude Code is also active on this project, these skills trigger automatically:

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

## Apple Documentation

Always fetch current Apple docs before using any API, especially macOS 26 Tahoe APIs:

- SwiftUI: https://developer.apple.com/documentation/swiftui
- Liquid Glass (macOS 26): https://developer.apple.com/documentation/swiftui/glass-effect
- AppKit: https://developer.apple.com/documentation/appkit
- Accessibility: https://developer.apple.com/documentation/accessibility

## Large Files

These files are very large - read only the relevant range:
- Search/ContentView.swift - 420+ @State vars; use awk NR>=X and NR<=Y
- Search/LauncherView+ContextualActions.swift - use same awk pattern
