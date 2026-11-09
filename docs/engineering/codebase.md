# Codebase — structure, architecture and conventions

Status: current · Last checked against the code: 2026-11-09 · Describes: `Context-Dock/` (the app target)

Moved here from `CLAUDE.md` / `AGENTS.md` when `AGENTS.md` became the single agent-instruction
file (`docs/master/00-ENGINEERING-OPERATING-MODEL.md` §2.4). The target structure is in
`docs/master/DORAX-BLUEPRINT.md` Part 3. This file describes the code as it is today; when a
fact here stops matching the code, fix this file in the same PR.

## Project facts

- **Deployment target**: macOS 26.1
- **Swift version**: 5.0
- **Bundle ID**: `com.krishgokul.ContextDock`
- **External dependency**: SwiftTerm (SPM, `github.com/migueldeicaza/SwiftTerm`, auto-resolved by Xcode)
- **Other targets**: `Context-DockExtension` (Safari Web Extension, `com.krishgokul.ContextDock.SafariExtension`)
  and `Context-DockTests` (`com.krishgokul.ContextDock.tests`; swift-testing, run with `./scripts/test.sh`)

## Project structure

The project uses `PBXFileSystemSynchronizedRootGroup` (Xcode 16). **Creating a subfolder on disk
automatically creates an Xcode group**, so no `project.pbxproj` edits are needed when adding or moving files.

Source lives in `Context-Dock/` at the repo root (about 800 Swift files), in these folders:

```
App/            Entry point (ILauncherApp.swift: AppDelegate), AppSettings, AppState, routing
Search/         DockCore and its extensions: the engine behind the Corner (search, rows, chat pipeline)
AI/             Providers, the agent tool loop, capabilities, skills, prompts
Accessibility/  AX observer pipeline, context reader, event bus
Automation/     Cross-app routing, Mail / Messages automation, share routing
UI/             The Corner shell (AppChat*, Corner*, SelectionScope*), settings, shared components
Services/       Shared infrastructure: context, skills, stores, extensions, on-device bridge
Developer/      Developer Inspector
Preview/        Preview helpers
```

## Architecture

### One shell, one engine

The Corner (`UI/AppChat*`, `UI/Corner*`, `UI/SelectionScope*`) is the only shell. The old Dock's
window is gone (#257). `Search/DockCore*` is now only the **engine** behind the Corner's App Chat
and Global results, run windowless by `Search/DockEngine.swift`. Read
`docs/master/00-DOCK-AND-CORNER.md` before touching either, and reuse the engine's code rather
than copying it (`AGENTS.md`).

`Search/DockCore.swift` declares `struct DockCore` (1,601 lines). Its state lives outside SwiftUI
(`DockCoreState` / `DockCoreModel`); the struct itself holds 16 `@ObservedObject`s and no `@State`.
Extensions split it by job, for example `DockCore+Search.swift` (the search engine:
`performSearch`, `detectSmartQuery`) and `DockCore+ContextualActions.swift` (4,970 lines; read
only the range you need). Extensions on a struct have full access to its state, which is the
intended pattern for splitting it.

**Adding to a view's `body` has a ceiling.** Release aborted in SILGen for two months (#25) because
`DockCore.body`'s opaque type grew past what the compiler could finish substituting: a computed
property returning `some View` is not a boundary, only a nominal type is. Two scripts exist so the
next person does not rediscover this: `scripts/view-leaves.py` lists view members safe to extract,
and `scripts/release-type-size.sh` measures the type. Prefer a `struct` over another `some View`
property when adding UI.

### The AI turn

The provider is the brain and the app is the harness:
`docs/superpowers/specs/2026-11-09-agent-harness-model.md`. In code:

- **Providers:** `AI/AIProviderRouter.swift`, `AI/AIProviderService.swift`; on-device through
  `Services/OnDeviceToolBridge.swift`.
- **Tool loop:** `AI/AgentToolRegistry.swift` (and its extensions); per-turn tool narrowing in
  `AI/FrontmostAppTaskPlan.swift`.
- **Data lane vs UI lane:** `Services/DataLane.swift` (`RequestLane`), `Services/LanePlan.swift`.
- **Skills:** `Services/SkillStore.swift` / `Services/SkillScope.swift`; solved skills (#205) in
  `AI/SolvedSkill*.swift`; Computer Use skills in `AI/ComputerUseSkillRecorder.swift`.
- **Per-app instructions:** `AppAgentProfileStore` (each app's `AGENT.md`).
- **Turn diagnosis:** `docs/runbooks/diagnose-an-ai-turn.md`.

### ContextDockEnvironment: context into the engine

`Services/ContextEngineProtocol.swift` defines:

- **`ContextEngineProtocol`**: abstracts `ContextDetector`'s context-reading methods. UI code that
  reads context should accept `any ContextEngineProtocol`, not `ContextDetector` directly.
  `ContextDetector` conforms via an extension at the bottom of `Services/ContextDetector.swift`.
- **`ContextDockEnvironment`**: callers report changes with `userContextDidDetect(_:)` and
  `frontmostAppDidChange(name:bundleID:)` instead of posting notifications. `DockEngine`
  subscribes to `userContextUpdates` / `frontmostAppUpdates`; the Corner window subscribes to
  `frontmostAppUpdates`.

### NotificationCenter: what still uses it

NotificationCenter is reserved for **UI-scope coordination** (hotkey changes, window open/close
signals). Cross-layer context flows through `ContextDockEnvironment`.

`App/NotificationNames.swift` holds 26 names in one `extension Notification.Name`; look there
first. A few surface-local names live beside the code that owns them, so if a name is not in the
registry, grep for the string literal. `userContextDetected` and `frontmostAppDetected` still
exist as names but are never posted.

### AXEventBus: accessibility events

`Accessibility/AXEventBus.swift` is a Combine subject of `AXEvent` (`appActivated`,
`focusedElementChanged`, `selectedTextChanged`, `menuItemsReady`), used by
`Accessibility/AXObserverManager.swift` and `Accessibility/AXContextReader.swift`.

### Routing

Requests are routed by the model through the ladder (#204 is retiring the remaining pre-model
shortcuts, one per PR). `Automation/MenuIntentRouter.swift` no longer has a router class; it keeps
`MenuPick` and `MenuPickRule` (#402).

### Extension layers

`Services/LayeredExtensionManager.swift` runs the layered extension model (L1 keyword quick
actions, L2 context-triggered actions, L3 browser/web actions). Packs and the Store are
described in `docs/superpowers/specs/2026-11-05-streamline-settings-and-extensions.md`.

### ContextDockStore

`Services/ContextDockStore.swift` is the file-based config store at
`~/Library/Application Support/Context-Dock/`, with per-app storage under `apps/{bundleId}/`.
Writes are debounced (300 ms) and deduplicated by content hash.

## Conventions

**Adding a new file**: drop it in the appropriate folder; Xcode picks it up automatically.

**Adding a cross-layer event**: prefer a method on `ContextDockEnvironment` or a typed
`PassthroughSubject`. Add a `Notification.Name` only for UI-scope signals with no natural owner.

**Reading context in a new view**: accept `any ContextEngineProtocol`, not
`ContextDetector.shared` directly.

**Singletons**: there are about 280 `static let shared` instances. `AppDelegate.shared` is set on
the first line of `applicationDidFinishLaunching` (`App/ILauncherApp.swift`); do not touch other
singletons before that point. Under XCTest the app returns early into
`configureTestHostEnvironment()`.

**Tests**: `Context-DockTests/` uses swift-testing (`import Testing`, `@Test`), not XCTest. Nothing
in the suite needs a live model.

## Apple documentation

Fetch current Apple docs before using any API, especially macOS 26 APIs:

- SwiftUI: https://developer.apple.com/documentation/swiftui
- Liquid Glass (macOS 26): https://developer.apple.com/documentation/swiftui/glass-effect
- AppKit: https://developer.apple.com/documentation/appkit
- Accessibility: https://developer.apple.com/documentation/accessibility
- Safari Web Extensions: https://developer.apple.com/documentation/safariservices/safari-web-extensions
