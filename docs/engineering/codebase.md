# Codebase — structure, architecture and conventions

Status: current · Last checked: 2026-09-24 · Describes: `Context-Dock/` (the app target)

Moved here from `CLAUDE.md` / `AGENTS.md` when `AGENTS.md` became the single agent-instruction
file (`docs/master/00-ENGINEERING-OPERATING-MODEL.md` §2.4). The target structure is in
`docs/master/DORAX-BLUEPRINT.md` Part 3; this file describes the code as it is today.

## Project facts

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

NC is reserved for **UI-scope coordination** only (hotkey changes, window open/close signals). All cross-layer context data now flows through `ContextDockEnvironment`.

**Notification names are centralised now.** `App/NotificationNames.swift` holds 27 of them in one `extension Notification.Name`. Look there first. A handful of surface-local names still live beside the code that owns them — `UI/AppChatPromptModel.swift`, `UI/Settings/SettingsView.swift`, `UI/Settings/AdvancedSettingsPage.swift`, `Search/ClipboardPanelWindow.swift`, `Automation/AutomationSettingsView.swift`, `Services/DockActionFeedback.swift`, `Services/MinimizedPanelRegistry.swift` — so if a name is not in the registry, grep for the string literal.

`userContextDetected` and `frontmostAppDetected` exist as NC names but are **no longer posted** — AppDelegate calls `ContextDockEnvironment.shared` directly.

### AXEventBus — accessibility events

`Accessibility/AXEventBus.swift` is a Combine `PassthroughSubject<AXEvent, Never>`. `AXEvent` cases: `appActivated`, `focusedElementChanged`, `selectedTextChanged`, `menuItemsReady`. Consumers in `CrossAppRouter` and `AXTriggerRuleEngine` subscribe to this, not to NotificationCenter.

### LauncherView state

`Search/LauncherView.swift` declares the `LauncherView` struct — 3,899 lines, **105 stored properties** (74 `@State`, 14 `@ObservedObject`, 9 `@StateObject`, 4 `@Environment`, 2 `@EnvironmentObject`, 1 `@AppStorage`, 1 `@FocusState`). `Search/ContentView.swift` is a 14-line stub that renders `LauncherShell()` and declares none of this.

`Search/LauncherView+Search.swift` is a Swift extension on the same struct that adds the entire search engine (`performSearch`, `detectSmartQuery`, `handleSmartQueryResult`, `findApplications`, `SmartQueryType`). Extensions on a struct have full access to `@State` vars — this is the intended pattern for splitting the file.

**Adding to `body` has a ceiling.** Release aborted in SILGen for two months (#25) because `LauncherView.body`'s opaque type grew past what the compiler can finish substituting — a computed property returning `some View` is not a boundary, only a nominal type is. It builds again because eight view members became `struct`s. Two scripts exist so the next person does not rediscover this: `scripts/view-leaves.py` lists view members safe to extract (a leaf reachable from `body`), and `scripts/release-type-size.sh` measures the type. Prefer a `struct` over another `some View` property when adding UI here.

### Extension system layers

The app has a 3-layer extension model:
- **L1** — keyword-triggered quick actions (search bar)
- **L2** — context-triggered actions (selected files, text, app in focus); AI assistant lives here
- **L3** — browser/web context actions

`Automation/MenuIntentRouter` routes NL queries: keyword scoring first → on-device AI → cloud AI fallback.

### ContextDockStore

`Services/ContextDockStore.swift` is the file-based config store. Path: `~/Library/Application Support/Context-Dock/`. Per-app storage under `apps/{bundleId}/`. Writes are debounced 300 ms and content-hash deduplicated.

## Conventions

**Adding a new file**: drop it in the appropriate folder; Xcode picks it up automatically.

**Adding a new cross-layer event**: prefer a method call on `ContextDockEnvironment` or a typed `PassthroughSubject`. Only add a new `Notification.Name` for UI-scope signals that have no natural owner (hotkey changes, window lifecycle).

**Reading context in a new view**: accept `any ContextEngineProtocol` via `@EnvironmentObject` (`contextEnv.engine`), not `ContextDetector.shared` directly.

**Singletons**: 68 `static let shared` instances exist. Initialisation order matters — `AppDelegate.shared` is set as the first line of `applicationDidFinishLaunching`. Do not access other singletons before that point.

## Large files

Read only the relevant range (`awk 'NR>=X && NR<=Y'`):
- `Search/LauncherView.swift` — 3,899 lines, 105 stored properties
- `Search/LauncherView+ContextualActions.swift`

## Apple documentation

Fetch current Apple docs before using any API, especially macOS 26 Tahoe APIs:

- SwiftUI: https://developer.apple.com/documentation/swiftui
- Liquid Glass (macOS 26): https://developer.apple.com/documentation/swiftui/glass-effect
- AppKit: https://developer.apple.com/documentation/appkit
- Accessibility: https://developer.apple.com/documentation/accessibility
- Safari Web Extensions: https://developer.apple.com/documentation/safariservices/safari-web-extensions
