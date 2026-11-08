# Issue #257: Convert Hidden Dock into Headless DockEngine (Final Closure)

> **Date:** 2026-11-08  
> **Status:** Specification / Revised (EGM Cycle - Iteration 6)  
> **Target Branch:** `claude/issue-257-headless-dock-engine` (bases on `general-chat-agent`)  
> **GitHub Issue:** #257 (Milestone 1.0)  
> **References:**  
> - `AGENTS.md` (DoraX architecture rule: Unified Dock Surface rule, windowless DockCore/DockEngine, swift-testing suite, no duplicated engine code)  
> - `docs/master/00-DOCK-AND-CORNER.md` (§1–§5, migration history and end state)  
> - `docs/master/00-NOW.md` (Issue #257 queued task)  
> - GitHub Issue #257 (`Convert the hidden Dock into a headless DockEngine`)  
> - Commits `a17056e9` (#257 E1), `0fbc271f` (#257 E2), `053cc220` (#257 E3a), `e71c27db` (#257 E3b), `81b94ad9` (#257 E4), `5669038a` (#257 E5)  
> - `Context-Dock/Search/DockEngine.swift`  
> - `Context-Dock/Search/DockCore*.swift`  
> - `Context-Dock/Search/FeatureViewModels.swift`  
> - `Context-Dock/Services/MenuWarmCacheService.swift`  

---

## 1. Context & Goals

### 1.1 Problem Statement
Historically, DoraX drew its user interface using two different shells:
1. The **Dock** (`LauncherView` / `DockCore`): the original floating window centered on the screen.
2. The **Corner** (`CornerDockWindow`, `AppChat*`, `SelectionScopeCard`): the compact, bottom-anchored interface that became the single unified Dock surface per owner decision (2026-10-27, #327).

In PRs #260–#268, stages E1 through E5 of Issue #257 retired the old launcher screen and deleted its floating window:
- **E1 (PR #260):** Moved view-held `@State` into `DockCoreState` outside SwiftUI.
- **E2 (PR #261):** Created `DockEngine` to run `DockCore` windowless.
- **E3a (PR #263) & E3b (PR #266):** Deleted the launcher window and removed the ~35k line screen view code.
- **E4 (PR #267):** Deleted launcher window sizing math, window position settings, Space-hold logic, and `KeyableWindow`.
- **E5 (PR #268):** Renamed `LauncherView` to `DockCore`.

Despite these merges, Issue #257 remains open on GitHub and listed in `00-NOW.md` because several residual window-coupled artifacts were left behind in `DockCore`:
1. **Window-hunting in `refocusLauncherWindowAfterAppAction`:** `Context-Dock/Search/DockCore+DockAppActions.swift:89-93` searches `NSApp.windows.first(where: { $0.isVisible })` and brings it to front. For a windowless engine, manipulating arbitrary visible windows (`NSApp.windows`) violates the headless contract and risks erroneously raising detached Pet panels, inspector overlays, or settings windows.
2. **Residual `@FocusState` in Headless Struct:** `DockCore.swift:93` still declares `@FocusState var isSearchFieldFocused: Bool`. Since `DockCore` is a standalone struct instantiated by `DockEngine` without a hosting SwiftUI `View`, reading or writing `@FocusState` outside a view hierarchy causes undefined runtime behavior and crashes during headless tests.
3. **Vestigial "Launcher" dismissal methods:** `hideLauncherAfterResultExecution()`, `forceHideLauncherAfterResultExecution()`, and `hideLauncherAfterFinderAction()` in `DockCore+ContextDetection.swift` manipulate view-focus properties under names referencing the deleted launcher window.
4. **Dead cache warming routines:** `MenuWarmCacheService.warmRecentAppsOnLauncherOpen()` and `MenuWarmCacheService.warmStatusMenuAppsOnLauncherOpen()` have 0 callers since the launcher window open lifecycle was deleted.
5. **Windowless Contract Drift:** There is currently no automated test enforcing that `DockEngine` and `DockCore` remain completely decoupled from `NSWindow` / `NSPanel` lifecycles.

### 1.2 Goals
1. **Eliminate window manipulation from `DockCore` while preserving process reactivation:** In `Context-Dock/Search/DockCore+DockAppActions.swift`, eliminate `NSApp.windows` inspection and front-ordering. Retain `NSApp.activate(ignoringOtherApps: true)` on the main queue to ensure macOS focus returns to DoraX during multi-quit and app actions, coupled cleanly with `self.reclaimSearchInputFocus()`.
2. **Migrate `@FocusState` to `DockCoreModel`:** Replace `@FocusState var isSearchFieldFocused: Bool` on `DockCore` with a standard property on `DockCoreModel` (in `FeatureViewModels.swift`) bridged via `var isSearchFieldFocused: Bool { get nonmutating set }`, matching existing state bridges in `DockCore+StateBridges.swift` and making it completely safe for headless execution and automated tests.
3. **Refactor vestigial launcher methods:** Implement `resetEngineStateAfterResultExecution(force: Bool = false)` in `DockCore+ContextDetection.swift`, keeping `hideLauncherAfterResultExecution`, `forceHideLauncherAfterResultExecution`, and `hideLauncherAfterFinderAction` as forwarding wrappers with zero deprecation warnings until broad file reorganization.
4. **Remove dead launcher-open code:** Clean up `MenuWarmCacheService.warmRecentAppsOnLauncherOpen()` and `MenuWarmCacheService.warmStatusMenuAppsOnLauncherOpen()`. Rename `warmRunningAppsOnLauncherOpen` to `warmRunningAppsForDock`, updating all call sites.
5. **Assert Windowless Headless Invariant in Tests:** Add automated swift-testing unit tests (`DockEngineHeadlessTests.swift`) proving that `DockEngine.shared` and `DockCore`:
   - Can register and evaluate inputs without creating, expecting, or querying any `NSWindow` or `NSPanel`.
   - Never iterate or mutate `NSApp.windows`.
   - Provide safe test harness methods `startObservingForTesting()` and `resetForTesting()` on `DockEngine` that reuse the extracted `attachNotificationInputs()` helper without triggering live background services (`core.startEngine()`).
6. **Verify Acceptance Criteria:**
   - `grep -rn "showLauncher\|LauncherView" Context-Dock` returns zero matches.
   - Zero references to `NSApp.windows` inside `Context-Dock/Search/DockCore*.swift`.
   - Gate `./scripts/check.sh` and full test suite `./scripts/test.sh` pass cleanly with zero warnings.
7. **Formally close Issue #257:** Update documentation (`docs/master/00-NOW.md`, `MEMORY.md`, `docs/master/00-DOCK-AND-CORNER.md`) and close GitHub Issue #257 with full provenance.

### 1.3 Non-Goals
1. Moving `DockCore*.swift` files from `Context-Dock/Search/` to `Context-Dock/Services/` in this PR (that is separate file-reorganization follow-up).
2. Changing the visual appearance, animation, or layout of the Corner shell (`CornerDockWindow`, `AppChatPromptModel`).
3. Altering how `GeneralChatWindowController` manages its dedicated window.

---

## 2. Architectural Lane & Layer Alignment

### 2.1 DoraX Unified Dock Surface Rule (`AGENTS.md`)
- The Corner (`AppChat*`, `Corner*`, `SelectionScope*`) is the **only shell**.
- `Search/DockCore*` is strictly the engine behind Corner App Chat and Global results, operated windowless by `DockEngine`.
- Engine code must never assume it owns an `NSWindow` or call `NSApp.windows.first(where: { $0.isVisible })`.

### 2.2 Data Lane vs. UI Lane Separation
- **Data Lane (Headless Engine):** `DockEngine` and `DockCore` run purely in memory. They ingest system events via NotificationCenter/Combine, match queries against `InstalledApplicationsCatalog`, `AXMenuReader`, and `GlobalSearchIndexBuilder`, and emit structured `SearchResult` and `DockPill` collections.
- **UI Lane (Presentation Shell):** Window creation, window positioning, key/first-responder management, and view animations are strictly restricted to `UI/Corner*`, `UI/AppChat*`, and `App/AppDelegate`.

---

## 3. Data Model & Invariants

### 3.1 Headless Contract Invariants
1. **Windowless Invariant:** At no point during `DockEngine.register()`, `DockEngine.start()`, or any method on `DockCore` shall an `NSWindow` or `NSPanel` be instantiated, retained, or queried via `NSApp.windows`.
2. **Process Focus without Window Ordering:** `NSApp.activate(ignoringOtherApps: true)` is executed on the main thread to ensure macOS yields foreground status back to DoraX when quitting an app from the dock. Window ordering is strictly prohibited within `DockCore`.
3. **State Decoupling & SwiftUI Safety:** View-related state fields in `DockCoreModel` (including `isSearchFieldFocused`) serve solely as state-bridges. Replacing `@FocusState` with `@Published var isSearchFieldFocused: Bool` in `DockCoreModel` guarantees that headless unit tests and background threads never touch SwiftUI runtime internals outside a view body.

### 3.2 Migrating `@FocusState` to `DockCoreModel`
In `Context-Dock/Search/FeatureViewModels.swift` (inside `class DockCoreModel`):
```swift
@Published var isSearchFieldFocused: Bool = false
```
In `Context-Dock/Search/DockCore.swift`:
```swift
// Replace:
// @FocusState var isSearchFieldFocused: Bool
// With:
var isSearchFieldFocused: Bool {
    get { dockCoreModel.isSearchFieldFocused }
    nonmutating set { dockCoreModel.isSearchFieldFocused = newValue }
}
```

### 3.3 Refactoring `refocusLauncherWindowAfterAppAction`
In `Context-Dock/Search/DockCore+DockAppActions.swift`:
The method can be called from synchronous or asynchronous contexts. To prevent deadlock when called from a background thread, the inner action is always dispatched asynchronously if off-main-thread:
```swift
// Refactored method:
func refocusDockInputAfterAppAction(delay: TimeInterval = 0.12) {
    let action = { @MainActor in
        self.isVisible = true
        self.expandSearchBar()
        self.isSearchFieldFocused = true
        self.reclaimSearchInputFocus()
        NSApp.activate(ignoringOtherApps: true)
    }

    if delay <= 0 {
        if Thread.isMainThread {
            MainActor.assumeIsolated { action() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
        }
    } else {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { action() }
        }
    }
}

// Forwarding alias:
func refocusLauncherWindowAfterAppAction(delay: TimeInterval = 0.12) {
    refocusDockInputAfterAppAction(delay: delay)
}
```
Update internal call sites in `Context-Dock/Search/DockCore+DockAppActions.swift`:
- Line 293: Update `refocusLauncherWindowAfterAppAction(delay: 0.06)` → `refocusDockInputAfterAppAction(delay: 0.06)`.
- Line 615: Update `refocusLauncherWindowAfterAppAction(delay: 0.06)` → `refocusDockInputAfterAppAction(delay: 0.06)`.

### 3.4 Cleaning Up `hideLauncherAfterResultExecution` & Related Methods
In `Context-Dock/Search/DockCore+ContextDetection.swift`:
```swift
func resetEngineStateAfterResultExecution(force: Bool = false) {
    suppressAutomaticGlobalContextUntil = Date().addingTimeInterval(1.6)
    suppressedAutomaticFinderSelectionSignature = nil
    dismissedFinderSelectionSignature = nil

    // A global-context launch is morphing into the app's Context Dock — keep the dock
    // visible instead of hiding, regardless of dock mode.
    if Date() < (AppDelegate.shared?.suppressResultHideUntil ?? .distantPast) {
        searchState.query = ""
        focusedAppPillIndex = nil
        l2.focusedPillIndex = nil
        l2.pillNavViaKeyboard = false
        DispatchQueue.main.async { self.reclaimSearchInputFocus() }
        return
    }

    // Always-float (or taskbar mode): keep the dock visible after the action runs;
    // just reset it to idle and refocus the input for the next command, unless force is true.
    if !force && (settings.alwaysFloatDock || (settings.effectiveDockAtBottom && showContextInDock)) {
        searchState.query = ""
        focusedAppPillIndex = nil
        l2.focusedPillIndex = nil
        l2.pillNavViaKeyboard = false
        DispatchQueue.main.async { self.reclaimSearchInputFocus() }
        return
    }

    isSearchFieldFocused = false
}

func hideLauncherAfterResultExecution() {
    resetEngineStateAfterResultExecution(force: false)
}

func forceHideLauncherAfterResultExecution() {
    resetEngineStateAfterResultExecution(force: true)
}

func hideLauncherAfterFinderAction() {
    guard showContextInDock else { return }
    guard
        frontmost.bundleID == "com.apple.finder"
            || contextTargetApp()?.bundleIdentifier == "com.apple.finder"
            || axContext.bundleId == "com.apple.finder"
    else { return }

    resetEngineStateAfterResultExecution(force: false)
}
```

Update internal call sites in `Context-Dock/Search/DockCore+DockAppActions.swift`:
- Line 103: Update `hideLauncherAfterResultExecution()` → `resetEngineStateAfterResultExecution(force: false)`.
- Line 147: Update `forceHideLauncherAfterResultExecution()` → `resetEngineStateAfterResultExecution(force: true)`.
- Line 149: Update `hideLauncherAfterResultExecution()` → `resetEngineStateAfterResultExecution(force: false)`.
- Line 599: Update `hideLauncherAfterResultExecution()` → `resetEngineStateAfterResultExecution(force: false)`.

### 3.5 Purging Dead Warming Code and Renaming Call Sites
In `Context-Dock/Services/MenuWarmCacheService.swift`:
1. Remove uncalled `warmRecentAppsOnLauncherOpen()`.
2. Remove uncalled `warmStatusMenuAppsOnLauncherOpen(force:)`.
3. Rename `warmRunningAppsOnLauncherOpen(_:maxApps:)` to `warmRunningAppsForDock(_:maxApps:)`.
4. Provide a forwarding wrapper `warmRunningAppsOnLauncherOpen` so legacy call paths compile safely.
5. Update active call sites:
   - `Context-Dock/UI/AppChatMenuBrowsing.swift:558`: `MenuWarmCacheService.shared.warmRunningAppsForDock(runningApps, maxApps: 12)`
   - `Context-Dock/Automation/AutomationSettingsView.swift:734`: `MenuWarmCacheService.shared.warmRunningAppsForDock(apps, maxApps: 12)`

### 3.6 Shared Notification Input Wiring on `DockEngine`
To satisfy the engine reuse rule (AGENTS.md) and avoid duplicate wiring:
In `Context-Dock/Search/DockEngine.swift`:
```swift
/// Shared notification subscriptions wired to DockCore handlers.
private func attachNotificationInputs() {
    let core = self.core
    let center = NotificationCenter.default
    let inputs: [(Notification.Name, (Notification) -> Void)] = [
        (.servicesOpenWithFiles, { core.handleServicesOpenWithFiles($0) }),
        (.servicesOpenWithText, { core.handleServicesOpenWithText($0) }),
        (AXMenuReader.scriptedMenusDidLoad, { core.handleScriptedMenusDidLoad($0) }),
        (.globalSearchIndexRebuildRequested, { core.handleGlobalSearchIndexRebuildRequest($0) }),
        // The Corner's App Chat and the Selection card ask on this engine's pipeline.
        (.appChatPromptSubmitted, { core.handleAppChatPromptSubmission($0) }),
        (.appChatPromptScopeChanged, { core.handleAppChatPromptScopeChange($0) }),
        (.appChatPromptNewChat, { _ in core.handleAppChatPromptNewChat() }),
        (.appChatPromptCancel, { _ in core.handleAppChatPromptCancel() }),
        (.appChatPromptPickAction, { core.handleAppChatPromptPickAction($0) }),
        (.appChatPromptEnableApp, { core.handleAppChatPromptEnableApp($0) }),
        (.appChatPromptDeclineEnableApp, { core.handleAppChatPromptDeclineEnableApp($0) }),
    ]
    for (name, handle) in inputs {
        center.publisher(for: name).sink { handle($0) }.store(in: &sinks)
    }
}
```
`DockEngine.start()` invokes `attachNotificationInputs()`.

Test harness methods:
```swift
#if DEBUG
extension DockEngine {
    /// Safe test method: attaches notification sinks for testing without starting background indexing or menu warming.
    func startObservingForTesting() {
        guard !isStarted else { return }
        isStarted = true
        attachNotificationInputs()
    }

    func resetForTesting() {
        sinks.removeAll()
        watches.removeAll()
        watchPassScheduled = false
        isStarted = false
    }
}
#endif
```

---

## 4. Failure Modes & Error Handling

| Failure Mode | Root Cause | Mitigation |
|---|---|---|
| Headless test crashes on `@FocusState` | Struct mutated `@FocusState` outside SwiftUI view hierarchy | Migrated `isSearchFieldFocused` to `DockCoreModel` `@Published` property with `nonmutating set`. |
| Headless test hangs waiting for window | Test or engine assumes a window is key | Invariant enforcement: engine never reads `NSApp.keyWindow` without nil-guarding, and never assumes `keyWindow != nil`. |
| Arbitrary window brought to front on app quit | `NSApp.windows.first(where: { $0.isVisible })` ordered front whatever window matched | Removed `NSApp.windows` iteration entirely from `DockCore`. |
| Focus lost on app termination | External app took focus when killed | Retained `NSApp.activate(ignoringOtherApps: true)` in `refocusDockInputAfterAppAction` on the main actor. |
| Background thread deadlock | Synchronous main dispatch from background queue | Asynchronous dispatch via `DispatchQueue.main.async` if not on the main thread. |
| Test host pollution / hang | Live services started in unit tests | Gated behind `startObservingForTesting()` and `resetForTesting()`. |
| Async test false-positive | Testing delayed action before dispatch completes | Test passes `delay: 0` to `refocusDockInputAfterAppAction` to test execution synchronously on main actor. |

---

## 5. Acceptance Criteria & Offline Tests

### 5.1 Acceptance Criteria
1. **Zero Legacy Launcher Names in Product Code:**
   - `git grep -rn "showLauncher\|LauncherView" Context-Dock` returns 0 results.
2. **Zero `NSApp.windows` in DockCore:**
   - `git grep -n "NSApp\.windows" Context-Dock/Search/DockCore*.swift` returns 0 results.
3. **Automated Headless Test Suite (`swift-testing`):**
   - Create `Context-DockTests/DockEngineHeadlessTests.swift` using `import Testing` and `@Test`:
     - `@Test @MainActor func dockEngineRegistersWithoutWindow()`: asserts that `DockEngine.shared.register()` succeeds in a headless state without requiring any active or key window.
     - `@Test @MainActor func dockEngineObservingWithoutWindow()`: verifies notification sink registration and clean teardown via `startObservingForTesting()` and `resetForTesting()`.
     - `@Test @MainActor func refocusDockInputDoesNotTouchNSAppWindows()`: invokes `DockEngine.shared.core.refocusDockInputAfterAppAction(delay: 0)`, asserts `DockEngine.shared.core.isSearchFieldFocused == true` and verifies zero windows were inspected or ordered front.
4. **Build & Test Gate:**
   - `./scripts/check.sh` passes with "build OK" and zero new warnings.
   - Whole suite `./scripts/test.sh` passes cleanly offline.

---

## 6. Implementation Plan

1. **Step 1:** Create branch `claude/issue-257-headless-dock-engine` from `origin/general-chat-agent`.
2. **Step 2:**
   - Add `@Published var isSearchFieldFocused: Bool = false` to `DockCoreModel` in `FeatureViewModels.swift`.
   - Update `DockCore.swift` to bridge `isSearchFieldFocused` to `dockCoreModel.isSearchFieldFocused` using `nonmutating set`.
3. **Step 3:** Refactor `refocusLauncherWindowAfterAppAction` to `refocusDockInputAfterAppAction` in `DockCore+DockAppActions.swift`, updating internal call sites at lines 293 and 615.
4. **Step 4:**
   - Implement `resetEngineStateAfterResultExecution(force:)` in `DockCore+ContextDetection.swift`.
   - Update active call sites in `DockCore+DockAppActions.swift` (lines 103, 147, 149, 599) to `resetEngineStateAfterResultExecution(force:)`.
   - Remove dead `warmRecentAppsOnLauncherOpen()` and `warmStatusMenuAppsOnLauncherOpen(force:)` and rename `warmRunningAppsOnLauncherOpen` to `warmRunningAppsForDock` in `MenuWarmCacheService.swift`.
   - Update call sites in `AppChatMenuBrowsing.swift` and `AutomationSettingsView.swift`.
5. **Step 5:**
   - Extract `attachNotificationInputs()` on `DockEngine`.
   - Add test helper methods (`startObservingForTesting`, `resetForTesting`) to `DockEngine.swift`.
6. **Step 6:** Add `Context-DockTests/DockEngineHeadlessTests.swift` using `import Testing` verifying windowless invariants.
7. **Step 7:** Run `./scripts/check.sh` and `./scripts/test.sh`.
8. **Step 8:** Update `docs/master/00-NOW.md`, `MEMORY.md`, and `docs/master/00-DOCK-AND-CORNER.md` marking Issue #257 as completed.
9. **Step 9:** Open draft PR and present hand-check checklist to Owner.
