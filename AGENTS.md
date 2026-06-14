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

```bash
# Build from CLI (run from repo root)
xcodebuild -project Context-Dock.xcodeproj -scheme Context-Dock -configuration Debug build

# Clean + build
xcodebuild -project Context-Dock.xcodeproj -scheme Context-Dock clean build

# Build for release
xcodebuild -project Context-Dock.xcodeproj -scheme Context-Dock -configuration Release build
```

In Xcode: **Cmd+B** to build, **Cmd+Shift+K** to clean first. There are no automated tests — all verification is manual via the running app.

- **Deployment target**: macOS 26.1  
- **Swift version**: 5.0  
- **Bundle ID**: `com.krishgokul.ContextDock`  
- **External dependency**: SwiftTerm (via SPM, auto-resolved by Xcode)  
- **Second target**: `Context-DockExtension` (Safari Web Extension, `com.krishgokul.ContextDock.SafariExtension`)

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
