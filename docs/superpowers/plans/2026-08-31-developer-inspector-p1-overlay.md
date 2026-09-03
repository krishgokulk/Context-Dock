# Developer Inspector P1 Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Stop after each task so the user can build, test, and approve the next task.

**Goal:** Turn the invisible P0 registry into a DEBUG-only interactive inspector — toggle Inspect Mode, hover an instrumented region, Option-click to lock it, and read its identity, source location and measured bounds — without altering product behaviour.

**Architecture:** One `@MainActor InspectorSessionController` owns Inspect Mode. A pure `InspectorSessionState` holds the transitions so they are testable offline. Each eligible DoraX window gets one transparent non-activating child `NSPanel` that only draws what the controller hands it. Hit resolution reuses the P0 contract exactly: screen point → `window.convertPoint(fromScreen:)` → `rootView.convert(_:from: nil)` → `InspectRegistry.hitTest`.

**Tech Stack:** Swift 5, SwiftUI, AppKit, Carbon `RegisterEventHotKey`, swift-testing, macOS 26.1, Xcode filesystem-synchronized groups.

**Spec:** `docs/superpowers/specs/2026-08-31-developer-inspector-p1-overlay-design.md`
**Parent spec:** `docs/superpowers/specs/2026-08-26-developer-inspector-design.md`
**Foundation:** `docs/superpowers/plans/2026-08-31-developer-inspector-p0.md` (complete; compiles)

## Global Constraints

- P1 only: activation, hover, lock, overlay, detail panel, teardown. No screenshots, no user note, no ViewModel-state serialization, no `sourceCandidates` ranking, no bug packet, no DiagnosticsPanel integration, no IPC, no scenarios, no repair session, no CLI handoff, no rebuild automation. `[Capture Bug]` must not appear.
- Everything in this plan is `#if DEBUG`. Nothing here may compile into Release.
- Never mutate `acceptsMouseMovedEvents` on a product window. `CornerDockWindow.swift:92` already sets it for its own reasons; P1 reads pointer position from its own event monitors and leaves that flag alone.
- Coordinate conversion is exactly the two P0 lines. No SwiftUI `.global`, no manual screen arithmetic, no re-derivation inside tests.
- Registry identity stays `(windowID, InspectID, instanceToken)`. Ordinals stay derived. P1 adds only read-only registry APIs.
- `InspectRegistry.emitsChanges` is true only while a session is enabled, and false again after disable.
- No synthetic mouse or keyboard events, ever. The monitor consumes only the Option-click Inspect Mode actually handles; every other event passes through untouched.
- Do not touch or stage unrelated working-tree changes. At time of writing these include `Context-Dock/AI/AppAdapterCapabilityCatalog.swift`, `Context-Dock/AI/GeneralAIActionExecutor.swift`, `Context-Dock/App/ILauncherApp.swift`, `Context-Dock/Search/LauncherView+AIChat.swift`, `Context-Dock/Services/AppAdapterManager.swift`, `Context-Dock/UI/AppChatPromptModel.swift`, `Context-Dock/UI/AppChatPromptPill.swift`, `Context-DockExtension/Resources/content_script.js`, `Context-DockTests/FrontmostAppTaskPlanTests.swift`, and a whitespace-only section reorder in `Context-Dock.xcodeproj/project.pbxproj`. Task 5 is the one exception: it edits `ILauncherApp.swift`, which another session is already modifying — see the warning in that task.
- Stage only the explicit paths listed in a completed task, and commit only after the user has verified and approved that task.

### Correction to the P0 plan's commands

Both the P0 plan and the P1 design instruct `./scripts/dev-stop.sh`. **That script does not exist** — `scripts/` contains `build-debug.sh`, `dev-run.sh`, `test.sh`, `build-release.sh`, `bump-build.sh`, `make-dmg.sh`, `release-beta.sh`, `ship.sh`. Anyone following those steps literally gets `command not found`, and then `test.sh` refuses because the app is still running.

Use this instead, everywhere those docs say `dev-stop.sh`:

```bash
osascript -e 'quit app "Context-Dock"'
```

`scripts/test.sh` refuses to run while a dev app or a lingering test host is alive, and that refusal is deliberate — a colliding run truncates silently and still prints a pass count in the hundreds. Quit first; do not work around the guard.

---

## File Map

- Modify `Context-Dock/Developer/InspectRegistry.swift`: add read-only `windowIDs()` and `registration(for:)`. No storage or identity changes.
- Create `Context-Dock/Developer/InspectRootBindings.swift`: DEBUG-only weak `InspectWindowID → (NSWindow, NSView)` map, so the session can convert a screen point into the same root space P0 measured in.
- Modify `Context-Dock/Developer/InspectModifier.swift`: `InspectRootModifier` registers and unregisters its window/root binding.
- Create `Context-Dock/Developer/InspectorSessionState.swift`: pure, synchronous state machine for enable/disable/hover/lock/escape/reconcile.
- Create `Context-Dock/Developer/InspectorOverlayWindow.swift`: transparent non-activating child panel plus the view that strokes one rect and draws one label.
- Create `Context-Dock/Developer/InspectorSessionController.swift`: session owner — monitors, overlay reconciliation, hit resolution, detail-panel lifecycle.
- Create `Context-Dock/Developer/InspectorDetailPanel.swift`: one shared non-activating metadata panel.
- Modify `Context-Dock/App/ILauncherApp.swift`: DEBUG-only `⌥⌘I` registration and teardown.
- Create `Context-DockTests/InspectRootBindingsTests.swift`
- Create `Context-DockTests/InspectorSessionStateTests.swift`
- Create `Context-DockTests/InspectorOverlayTests.swift`
- Create `Context-DockTests/InspectorHitResolutionTests.swift`

### Public P1 Interfaces

```swift
#if DEBUG
extension InspectRegistry {
    func windowIDs() -> [InspectWindowID]
    func registration(for key: InspectRegistryKey) -> InspectRegistration?
}

@MainActor
final class InspectRootBindings {
    static let shared: InspectRootBindings
    init()

    func bind(windowID: InspectWindowID, window: NSWindow, rootView: NSView)
    func unbind(windowID: InspectWindowID)
    func binding(for windowID: InspectWindowID) -> (window: NSWindow, rootView: NSView)?
    func boundWindowIDs() -> [InspectWindowID]
}

@MainActor
final class InspectorSessionState {
    enum EscapeOutcome: Equatable { case ignored, clearedLock, disabled }

    private(set) var isEnabled: Bool
    private(set) var hoveredKey: InspectRegistryKey?
    private(set) var lockedKey: InspectRegistryKey?

    @discardableResult func enable() -> Bool
    @discardableResult func disable() -> Bool
    @discardableResult func hover(_ key: InspectRegistryKey?) -> Bool
    @discardableResult func lock(_ key: InspectRegistryKey?) -> Bool
    func escape() -> EscapeOutcome
    @discardableResult func reconcile(liveKeys: Set<InspectRegistryKey>) -> Bool
}

@MainActor
final class InspectorOverlayController {
    init(windowID: InspectWindowID, owner: NSWindow, rootView: NSView)
    func show(highlight: InspectorHighlight?)
    func followOwnerFrame()
    func tearDown()
}

struct InspectorHighlight: Equatable {
    let frameInWindowRoot: CGRect
    let label: String
    let isLocked: Bool
}

@MainActor
final class InspectorSessionController {
    static let shared: InspectorSessionController
    var isEnabled: Bool { get }

    func toggle()
    func enable()
    func disable()
    func resolveHit(atScreenPoint screenPoint: CGPoint) -> InspectRegistration?
}
#endif
```

---

### Task 1: Registry Read APIs and Window/Root Bindings

**Files:**
- Modify: `Context-Dock/Developer/InspectRegistry.swift`
- Create: `Context-Dock/Developer/InspectRootBindings.swift`
- Modify: `Context-Dock/Developer/InspectModifier.swift:104-113` (`InspectRootModifier`)
- Create: `Context-DockTests/InspectRootBindingsTests.swift`

**Interfaces:**
- Consumes: `InspectWindowID`, `InspectRegistryKey`, `InspectRegistration`, `InspectRegistry` from P0.
- Produces: `InspectRegistry.windowIDs()`, `InspectRegistry.registration(for:)`, and the whole `InspectRootBindings` API above.

- [ ] **Step 1: Write the failing binding and registry-read tests**

Create `Context-DockTests/InspectRootBindingsTests.swift`:

```swift
import AppKit
import Foundation
import Testing

@testable import Context_Dock

@MainActor
struct InspectRootBindingsTests {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
    }

    @Test func bindingResolvesTheWindowAndRootItWasGiven() {
        let bindings = InspectRootBindings()
        let window = makeWindow()
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(root)

        bindings.bind(windowID: InspectWindowID(rawValue: 11), window: window, rootView: root)

        let resolved = bindings.binding(for: InspectWindowID(rawValue: 11))
        #expect(resolved?.window === window)
        #expect(resolved?.rootView === root)
    }

    @Test func unbindingRemovesOnlyThatWindow() {
        let bindings = InspectRootBindings()
        let first = makeWindow()
        let second = makeWindow()
        let firstRoot = NSView(frame: .zero)
        let secondRoot = NSView(frame: .zero)

        bindings.bind(windowID: InspectWindowID(rawValue: 1), window: first, rootView: firstRoot)
        bindings.bind(windowID: InspectWindowID(rawValue: 2), window: second, rootView: secondRoot)
        bindings.unbind(windowID: InspectWindowID(rawValue: 1))

        #expect(bindings.binding(for: InspectWindowID(rawValue: 1)) == nil)
        #expect(bindings.binding(for: InspectWindowID(rawValue: 2)) != nil)
        #expect(bindings.boundWindowIDs() == [InspectWindowID(rawValue: 2)])
    }

    @Test func rebindingReplacesTheEarlierBindingForThatWindowID() {
        let bindings = InspectRootBindings()
        let window = makeWindow()
        let firstRoot = NSView(frame: .zero)
        let secondRoot = NSView(frame: .zero)

        bindings.bind(windowID: InspectWindowID(rawValue: 7), window: window, rootView: firstRoot)
        bindings.bind(windowID: InspectWindowID(rawValue: 7), window: window, rootView: secondRoot)

        #expect(bindings.binding(for: InspectWindowID(rawValue: 7))?.rootView === secondRoot)
        #expect(bindings.boundWindowIDs().count == 1)
    }

    @Test func aDeallocatedWindowStopsResolvingAndIsNotEnumerated() {
        let bindings = InspectRootBindings()
        let id = InspectWindowID(rawValue: 5)
        autoreleasepool {
            let window = makeWindow()
            let root = NSView(frame: .zero)
            window.contentView?.addSubview(root)
            bindings.bind(windowID: id, window: window, rootView: root)
        }

        #expect(bindings.binding(for: id) == nil)
        #expect(bindings.boundWindowIDs().contains(id) == false)
    }

    @Test func registryEnumeratesEveryWindowThatHasRegistrations() {
        let registry = InspectRegistry()
        registry.upsert(makeRegistration(window: 1, id: .generalChat.thread))
        registry.upsert(makeRegistration(window: 1, id: .generalChat.input))
        registry.upsert(makeRegistration(window: 2, id: .contextDockChat.thread))

        #expect(Set(registry.windowIDs().map(\.rawValue)) == [1, 2])
    }

    @Test func registryLooksUpAnExactKeyAndMissesAStaleToken() {
        let registry = InspectRegistry()
        let registration = makeRegistration(window: 3, id: .generalChat.thread)
        registry.upsert(registration)

        #expect(registry.registration(for: registration.key) == registration)

        let staleKey = InspectRegistryKey(
            windowID: registration.key.windowID,
            id: registration.key.id,
            instanceToken: UUID()
        )
        #expect(registry.registration(for: staleKey) == nil)
    }

    private func makeRegistration(window: Int, id: InspectID) -> InspectRegistration {
        InspectRegistration(
            key: InspectRegistryKey(
                windowID: InspectWindowID(rawValue: window),
                id: id,
                instanceToken: UUID()
            ),
            frameInWindowRoot: CGRect(x: 0, y: 0, width: 100, height: 40),
            source: InspectSource(file: "Developer/Test.swift", line: 1, type: "body"),
            depth: 0
        )
    }
}
```

- [ ] **Step 2: Run the focused tests and confirm they fail to compile**

```bash
osascript -e 'quit app "Context-Dock"'
./scripts/test.sh -only-testing:Context-DockTests/InspectRootBindingsTests
```

Expected: non-zero exit, because `InspectRootBindings`, `windowIDs()` and `registration(for:)` do not exist. A zero-passing run with an unnamed failure is infrastructure failure, not the intended red — read the verdict line and the count together.

- [ ] **Step 3: Add the read-only registry APIs**

Append inside the existing `InspectRegistry` class in `Context-Dock/Developer/InspectRegistry.swift`, next to `registrations(in:)`:

```swift
    /// Every window that currently holds at least one registration.
    ///
    /// The session reconciles overlays from this: a window with no registrations is not
    /// eligible for an overlay, and a window that vanished is not in the list at all.
    func windowIDs() -> [InspectWindowID] {
        let ids = Set(registrationsByKey.keys.map(\.windowID))
        return ids.sorted { $0.rawValue < $1.rawValue }
    }

    /// Exact-key lookup. A stale token misses rather than matching a replacement instance —
    /// the same property that makes `remove` safe.
    func registration(for key: InspectRegistryKey) -> InspectRegistration? {
        registrationsByKey[key]
    }
```

Make `InspectRegistry`'s initializer internal if it is not already, so tests can construct a fresh instance rather than sharing `.shared`.

- [ ] **Step 4: Implement the window/root bindings**

Create `Context-Dock/Developer/InspectRootBindings.swift`:

```swift
#if DEBUG
import AppKit
import Foundation

/// Where a window's inspection root actually lives, so a screen point can be converted the
/// same way P0 measured.
///
/// The registry stores frames in a window's root coordinate space and deliberately knows
/// nothing about AppKit. Converting a pointer location back into that space needs the real
/// `NSWindow` and the real root `NSView`, and nothing else in the subsystem holds them.
///
/// References are weak on purpose. A window closing is normal, and the correct response is
/// for its binding to disappear on its own rather than for something to remember to call
/// `unbind` at exactly the right moment.
@MainActor
final class InspectRootBindings {
    static let shared = InspectRootBindings()

    private struct Binding {
        weak var window: NSWindow?
        weak var rootView: NSView?

        var resolved: (window: NSWindow, rootView: NSView)? {
            guard let window, let rootView else { return nil }
            return (window, rootView)
        }
    }

    private var bindingsByWindowID: [InspectWindowID: Binding] = [:]

    init() {}

    func bind(windowID: InspectWindowID, window: NSWindow, rootView: NSView) {
        bindingsByWindowID[windowID] = Binding(window: window, rootView: rootView)
    }

    func unbind(windowID: InspectWindowID) {
        bindingsByWindowID.removeValue(forKey: windowID)
    }

    func binding(for windowID: InspectWindowID) -> (window: NSWindow, rootView: NSView)? {
        guard let resolved = bindingsByWindowID[windowID]?.resolved else {
            bindingsByWindowID.removeValue(forKey: windowID)
            return nil
        }
        return resolved
    }

    func boundWindowIDs() -> [InspectWindowID] {
        for (windowID, binding) in bindingsByWindowID where binding.resolved == nil {
            bindingsByWindowID.removeValue(forKey: windowID)
        }
        return bindingsByWindowID.keys.sorted { $0.rawValue < $1.rawValue }
    }
}
#endif
```

- [ ] **Step 5: Register the binding from the inspection root**

In `Context-Dock/Developer/InspectModifier.swift`, extend `InspectWindowReader` so it reports the root `NSView` alongside the window, and have `InspectRootModifier` bind and unbind. Replace the `report` method and `WindowReportingView` with:

```swift
    private func report(_ view: WindowReportingView) {
        let window = view.window
        let newValue = window.map { InspectWindowID(rawValue: $0.windowNumber) }

        if let previous = windowID, previous != newValue {
            InspectRootBindings.shared.unbind(windowID: previous)
            InspectRegistry.shared.purge(windowID: previous)
        }

        if let newValue, let window, let root = window.contentView {
            InspectRootBindings.shared.bind(windowID: newValue, window: window, rootView: root)
        }

        guard newValue != windowID else { return }
        DispatchQueue.main.async {
            windowID = newValue
        }
    }

    final class WindowReportingView: NSView {
        var onWindowChange: ((WindowReportingView) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportCurrentWindow()
        }

        func reportCurrentWindow() {
            onWindowChange?(self)
        }
    }
```

Update `makeNSView`/`updateNSView` to pass the view itself: `view.onWindowChange = report`, then `view.reportCurrentWindow()`.

The root view is the window's `contentView`. That is the same view the P0 named coordinate space is established on, so the conversion in Task 4 lands in the space the frames were measured in. Do not substitute a different view.

- [ ] **Step 6: Run the focused tests, then the whole suite**

```bash
./scripts/test.sh -only-testing:Context-DockTests/InspectRootBindingsTests
./scripts/test.sh
```

Expected: focused tests pass, full offline suite passes with zero failures and a truthful exit code. Confirm the verdict line and the count together — a plausible-looking pass count from a truncated run has impersonated a real result in this repo three times.

- [ ] **Step 7: Build, relaunch, checkpoint**

```bash
./scripts/dev-run.sh
```

Expected: no visible change whatsoever. Open and close General Chat a few times; nothing new should appear.

Show the user the test results and the exact diff. Wait for approval. Optional approved commit:

```bash
git add Context-Dock/Developer/InspectRegistry.swift \
        Context-Dock/Developer/InspectRootBindings.swift \
        Context-Dock/Developer/InspectModifier.swift \
        Context-DockTests/InspectRootBindingsTests.swift
git commit -m "feat(inspector): resolve a window's inspection root"
```

---

### Task 2: Pure Session State Machine

**Files:**
- Create: `Context-Dock/Developer/InspectorSessionState.swift`
- Create: `Context-DockTests/InspectorSessionStateTests.swift`

**Interfaces:**
- Consumes: `InspectRegistryKey` from P0.
- Produces: `InspectorSessionState` with `enable()`, `disable()`, `hover(_:)`, `lock(_:)`, `escape()`, `reconcile(liveKeys:)`, and `EscapeOutcome`.

This task deliberately contains no AppKit, no SwiftUI and no windows. Every transition the design specifies is decided here, so it can be tested offline in milliseconds; Task 3 onward only wires real events into it.

- [ ] **Step 1: Write the failing state-machine tests**

Create `Context-DockTests/InspectorSessionStateTests.swift`:

```swift
import Foundation
import Testing

@testable import Context_Dock

@MainActor
struct InspectorSessionStateTests {
    private let windowID = InspectWindowID(rawValue: 31)

    private func key(_ id: InspectID, _ token: UUID = UUID()) -> InspectRegistryKey {
        InspectRegistryKey(windowID: windowID, id: id, instanceToken: token)
    }

    @Test func enableAndDisableAreIdempotent() {
        let state = InspectorSessionState()

        #expect(state.enable() == true)
        #expect(state.enable() == false)
        #expect(state.isEnabled)

        #expect(state.disable() == true)
        #expect(state.disable() == false)
        #expect(state.isEnabled == false)
    }

    @Test func disablingClearsHoverAndLock() {
        let state = InspectorSessionState()
        state.enable()
        state.hover(key(.generalChat.thread))
        state.lock(key(.generalChat.input))

        state.disable()

        #expect(state.hoveredKey == nil)
        #expect(state.lockedKey == nil)
    }

    @Test func hoverIsIgnoredWhileDisabled() {
        let state = InspectorSessionState()

        #expect(state.hover(key(.generalChat.thread)) == false)
        #expect(state.hoveredKey == nil)
    }

    @Test func repeatedHoverOnTheSameKeyReportsNoChange() {
        let state = InspectorSessionState()
        state.enable()
        let target = key(.generalChat.thread)

        #expect(state.hover(target) == true)
        #expect(state.hover(target) == false)
        #expect(state.hover(target) == false)
    }

    @Test func hoverDoesNotMoveWhileATargetIsLocked() {
        let state = InspectorSessionState()
        state.enable()
        let locked = key(.generalChat.thread)
        state.lock(locked)

        #expect(state.hover(key(.generalChat.input)) == false)
        #expect(state.lockedKey == locked)
    }

    @Test func lockingOutsideAnyRegionClearsTheLock() {
        let state = InspectorSessionState()
        state.enable()
        state.lock(key(.generalChat.thread))

        #expect(state.lock(nil) == true)
        #expect(state.lockedKey == nil)
    }

    @Test func firstEscapeClearsTheLockAndSecondDisables() {
        let state = InspectorSessionState()
        state.enable()
        state.lock(key(.generalChat.thread))

        #expect(state.escape() == .clearedLock)
        #expect(state.isEnabled)
        #expect(state.lockedKey == nil)

        #expect(state.escape() == .disabled)
        #expect(state.isEnabled == false)
    }

    @Test func escapeIsIgnoredWhileDisabled() {
        let state = InspectorSessionState()

        #expect(state.escape() == .ignored)
    }

    @Test func reconcileClearsAHoverWhoseRegistrationIsGone() {
        let state = InspectorSessionState()
        state.enable()
        let gone = key(.generalChat.thread)
        state.hover(gone)

        #expect(state.reconcile(liveKeys: []) == true)
        #expect(state.hoveredKey == nil)
    }

    @Test func reconcileClearsALockWhoseRegistrationIsGone() {
        let state = InspectorSessionState()
        state.enable()
        let gone = key(.generalChat.thread)
        state.lock(gone)

        #expect(state.reconcile(liveKeys: []) == true)
        #expect(state.lockedKey == nil)
    }

    @Test func reconcileKeepsSelectionsThatAreStillLive() {
        let state = InspectorSessionState()
        state.enable()
        let live = key(.generalChat.thread)
        state.lock(live)

        #expect(state.reconcile(liveKeys: [live]) == false)
        #expect(state.lockedKey == live)
    }

    @Test func aRecreatedWindowDoesNotInheritTheEarlierLock() {
        let state = InspectorSessionState()
        state.enable()
        let token = UUID()
        let oldWindowKey = InspectRegistryKey(
            windowID: InspectWindowID(rawValue: 41), id: .generalChat.thread, instanceToken: token
        )
        let newWindowKey = InspectRegistryKey(
            windowID: InspectWindowID(rawValue: 42), id: .generalChat.thread, instanceToken: token
        )
        state.lock(oldWindowKey)

        #expect(state.reconcile(liveKeys: [newWindowKey]) == true)
        #expect(state.lockedKey == nil)
    }
}
```

- [ ] **Step 2: Run the focused tests and confirm the missing-type failure**

```bash
osascript -e 'quit app "Context-Dock"'
./scripts/test.sh -only-testing:Context-DockTests/InspectorSessionStateTests
```

Expected: non-zero exit, `InspectorSessionState` undefined.

- [ ] **Step 3: Implement the state machine**

Create `Context-Dock/Developer/InspectorSessionState.swift`:

```swift
#if DEBUG
import Foundation

/// Every Inspect Mode transition, with no AppKit in sight.
///
/// The interesting failures in an inspector are transitions, not drawing: a lock that
/// survives the window it pointed at, a hover that keeps redrawing because "unchanged" was
/// never checked, an Escape that exits the mode when it should only have released the
/// selection. Deciding all of that here means it can be tested offline, and Task 3 onward is
/// only wiring.
@MainActor
final class InspectorSessionState {
    enum EscapeOutcome: Equatable {
        case ignored
        case clearedLock
        case disabled
    }

    private(set) var isEnabled = false
    private(set) var hoveredKey: InspectRegistryKey?
    private(set) var lockedKey: InspectRegistryKey?

    /// Returns whether the call changed anything, so callers can skip redundant redraws.
    @discardableResult
    func enable() -> Bool {
        guard !isEnabled else { return false }
        isEnabled = true
        return true
    }

    @discardableResult
    func disable() -> Bool {
        guard isEnabled else { return false }
        isEnabled = false
        hoveredKey = nil
        lockedKey = nil
        return true
    }

    /// Hover is preview only, and a locked selection freezes it: the panel a developer is
    /// reading must not change under them because the pointer drifted.
    @discardableResult
    func hover(_ key: InspectRegistryKey?) -> Bool {
        guard isEnabled, lockedKey == nil, hoveredKey != key else { return false }
        hoveredKey = key
        return true
    }

    @discardableResult
    func lock(_ key: InspectRegistryKey?) -> Bool {
        guard isEnabled, lockedKey != key else { return false }
        lockedKey = key
        if key != nil { hoveredKey = key }
        return true
    }

    func escape() -> EscapeOutcome {
        guard isEnabled else { return .ignored }
        if lockedKey != nil {
            lockedKey = nil
            hoveredKey = nil
            return .clearedLock
        }
        disable()
        return .disabled
    }

    /// Drop selections whose registration no longer exists. A closed window, a scrolled-away
    /// message and a rebuilt surface all arrive here as a key that is simply absent.
    @discardableResult
    func reconcile(liveKeys: Set<InspectRegistryKey>) -> Bool {
        guard isEnabled else { return false }
        var changed = false

        if let hoveredKey, !liveKeys.contains(hoveredKey) {
            self.hoveredKey = nil
            changed = true
        }
        if let lockedKey, !liveKeys.contains(lockedKey) {
            self.lockedKey = nil
            changed = true
        }
        return changed
    }
}
#endif
```

- [ ] **Step 4: Run focused tests, then the whole suite**

```bash
./scripts/test.sh -only-testing:Context-DockTests/InspectorSessionStateTests
./scripts/test.sh
```

Expected: all pass, truthful exit code.

- [ ] **Step 5: Build and checkpoint**

```bash
./scripts/dev-run.sh
```

Expected: no visible change; nothing calls this type yet. Show the user the diff and test results, then wait. Optional approved commit:

```bash
git add Context-Dock/Developer/InspectorSessionState.swift \
        Context-DockTests/InspectorSessionStateTests.swift
git commit -m "feat(inspector): decide inspect-mode transitions in one place"
```

---

### Task 3: Overlay Window and Reconciliation

**Files:**
- Create: `Context-Dock/Developer/InspectorOverlayWindow.swift`
- Create: `Context-DockTests/InspectorOverlayTests.swift`

**Interfaces:**
- Consumes: `InspectWindowID` and `InspectRootBindings` from Task 1.
- Produces: `InspectorHighlight` and `InspectorOverlayController` with `show(highlight:)`, `followOwnerFrame()`, `tearDown()`.

- [ ] **Step 1: Write the failing overlay tests**

Create `Context-DockTests/InspectorOverlayTests.swift`:

```swift
import AppKit
import Foundation
import Testing

@testable import Context_Dock

@MainActor
struct InspectorOverlayTests {
    private func makeOwner(origin: CGPoint) -> (NSWindow, NSView) {
        let window = NSWindow(
            contentRect: CGRect(origin: origin, size: CGSize(width: 500, height: 400)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let root = window.contentView ?? NSView()
        return (window, root)
    }

    @Test func theOverlayIsANonActivatingBorderlessChildOfItsOwner() {
        let (owner, root) = makeOwner(origin: CGPoint(x: 100, y: 120))
        let controller = InspectorOverlayController(
            windowID: InspectWindowID(rawValue: 3), owner: owner, rootView: root
        )
        defer { controller.tearDown() }

        let overlay = controller.overlayWindowForTesting
        #expect(overlay.styleMask.contains(.borderless))
        #expect(overlay.styleMask.contains(.nonactivatingPanel))
        #expect(overlay.isOpaque == false)
        #expect(overlay.backgroundColor == .clear)
        #expect(overlay.ignoresMouseEvents)
        #expect(owner.childWindows?.contains(overlay) == true)
    }

    @Test func theOverlayCoversTheOwnerContentAndFollowsItWhenItMoves() {
        let (owner, root) = makeOwner(origin: CGPoint(x: 100, y: 120))
        let controller = InspectorOverlayController(
            windowID: InspectWindowID(rawValue: 4), owner: owner, rootView: root
        )
        defer { controller.tearDown() }

        let expected = owner.convertToScreen(root.convert(root.bounds, to: nil))
        #expect(controller.overlayWindowForTesting.frame == expected)

        owner.setFrameOrigin(CGPoint(x: 260, y: 300))
        controller.followOwnerFrame()

        let moved = owner.convertToScreen(root.convert(root.bounds, to: nil))
        #expect(controller.overlayWindowForTesting.frame == moved)
    }

    @Test func showingAHighlightMakesTheOverlayVisibleAndClearingItHidesTheOverlay() {
        let (owner, root) = makeOwner(origin: .zero)
        owner.orderFront(nil)
        let controller = InspectorOverlayController(
            windowID: InspectWindowID(rawValue: 5), owner: owner, rootView: root
        )
        defer { controller.tearDown() }

        controller.show(
            highlight: InspectorHighlight(
                frameInWindowRoot: CGRect(x: 10, y: 20, width: 100, height: 40),
                label: "generalChat.thread #0",
                isLocked: false
            )
        )
        #expect(controller.overlayWindowForTesting.isVisible)

        controller.show(highlight: nil)
        #expect(controller.overlayWindowForTesting.isVisible == false)
    }

    @Test func tearingDownDetachesTheOverlayFromItsOwner() {
        let (owner, root) = makeOwner(origin: .zero)
        let controller = InspectorOverlayController(
            windowID: InspectWindowID(rawValue: 6), owner: owner, rootView: root
        )
        let overlay = controller.overlayWindowForTesting

        controller.tearDown()

        #expect(owner.childWindows?.contains(overlay) != true)
        #expect(overlay.isVisible == false)
    }

    @Test func tearingDownTwiceIsHarmless() {
        let (owner, root) = makeOwner(origin: .zero)
        let controller = InspectorOverlayController(
            windowID: InspectWindowID(rawValue: 7), owner: owner, rootView: root
        )

        controller.tearDown()
        controller.tearDown()

        #expect(controller.overlayWindowForTesting.parent == nil)
    }
}
```

- [ ] **Step 2: Run the focused tests and confirm the missing-type failure**

```bash
osascript -e 'quit app "Context-Dock"'
./scripts/test.sh -only-testing:Context-DockTests/InspectorOverlayTests
```

- [ ] **Step 3: Implement the overlay**

Create `Context-Dock/Developer/InspectorOverlayWindow.swift`:

```swift
#if DEBUG
import AppKit
import SwiftUI

struct InspectorHighlight: Equatable {
    let frameInWindowRoot: CGRect
    let label: String
    let isLocked: Bool
}

/// One transparent child window per inspected DoraX window.
///
/// A child window rather than one screen-sized capture window, because the P0 contract is
/// per-window: frames are stored in a window's root space, so a highlight drawn in that same
/// window needs no second coordinate system to go wrong. It also means an overlay cannot
/// outlive its owner or drift across a Space.
///
/// `ignoresMouseEvents` is the important flag. The overlay is a drawing surface and nothing
/// else; the session's own monitors do the hit testing, and the product window underneath
/// keeps receiving every event exactly as it did before.
@MainActor
final class InspectorOverlayController {
    private let windowID: InspectWindowID
    private weak var owner: NSWindow?
    private weak var rootView: NSView?
    private let overlay: NSPanel
    private let hostingView: NSHostingView<InspectorOverlayView>
    private let model = InspectorOverlayModel()

    var overlayWindowForTesting: NSPanel { overlay }

    init(windowID: InspectWindowID, owner: NSWindow, rootView: NSView) {
        self.windowID = windowID
        self.owner = owner
        self.rootView = rootView

        overlay = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.level = .floating
        overlay.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        overlay.isReleasedWhenClosed = false

        hostingView = NSHostingView(rootView: InspectorOverlayView(model: model))
        overlay.contentView = hostingView

        owner.addChildWindow(overlay, ordered: .above)
        followOwnerFrame()
    }

    func show(highlight: InspectorHighlight?) {
        model.highlight = highlight
        guard highlight != nil else {
            overlay.orderOut(nil)
            return
        }
        followOwnerFrame()
        overlay.orderFront(nil)
    }

    func followOwnerFrame() {
        guard let owner, let rootView else { return }
        overlay.setFrame(owner.convertToScreen(rootView.convert(rootView.bounds, to: nil)), display: false)
    }

    func tearDown() {
        model.highlight = nil
        overlay.orderOut(nil)
        owner?.removeChildWindow(overlay)
        overlay.contentView = nil
    }
}

@MainActor
final class InspectorOverlayModel: ObservableObject {
    @Published var highlight: InspectorHighlight?
}

private struct InspectorOverlayView: View {
    @ObservedObject var model: InspectorOverlayModel

    var body: some View {
        GeometryReader { _ in
            if let highlight = model.highlight {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(highlight.isLocked ? Color.orange : Color.accentColor, lineWidth: 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill((highlight.isLocked ? Color.orange : Color.accentColor).opacity(0.12))
                        )
                        .frame(width: highlight.frameInWindowRoot.width, height: highlight.frameInWindowRoot.height)
                        .offset(x: highlight.frameInWindowRoot.minX, y: highlight.frameInWindowRoot.minY)

                    Text(highlight.label)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(highlight.isLocked ? Color.orange : Color.accentColor)
                        )
                        .foregroundStyle(Color.white)
                        .offset(
                            x: highlight.frameInWindowRoot.minX,
                            y: max(0, highlight.frameInWindowRoot.minY - 20)
                        )
                }
            }
        }
        .allowsHitTesting(false)
    }
}
#endif
```

- [ ] **Step 4: Run focused tests, then the whole suite**

```bash
./scripts/test.sh -only-testing:Context-DockTests/InspectorOverlayTests
./scripts/test.sh
```

Expected: all pass. If a headless test environment refuses to make a window visible, prefer asserting `overlay.parent`, `styleMask` and `frame` over `isVisible`; do not delete the teardown assertions to make a run green.

- [ ] **Step 5: Build and checkpoint**

```bash
./scripts/dev-run.sh
```

Expected: still no visible change; nothing constructs an overlay yet. Show the diff and results, wait for approval. Optional approved commit:

```bash
git add Context-Dock/Developer/InspectorOverlayWindow.swift \
        Context-DockTests/InspectorOverlayTests.swift
git commit -m "feat(inspector): draw a highlight over one inspected window"
```

---

### Task 4: Session Controller, Hit Resolution and Event Routing

**Files:**
- Create: `Context-Dock/Developer/InspectorSessionController.swift`
- Create: `Context-DockTests/InspectorHitResolutionTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1-3.
- Produces: `InspectorSessionController.shared`, `toggle()`, `enable()`, `disable()`, `resolveHit(atScreenPoint:)`.

- [ ] **Step 1: Write the failing hit-resolution tests**

Create `Context-DockTests/InspectorHitResolutionTests.swift`. These use real `NSWindow`/`NSView` fixtures and the real converter — the point is to prove the screen→root path lands where P0 measured, without re-deriving the arithmetic in the test:

```swift
import AppKit
import Foundation
import Testing

@testable import Context_Dock

@MainActor
struct InspectorHitResolutionTests {
    private func makeWindow(origin: CGPoint) -> NSWindow {
        NSWindow(
            contentRect: CGRect(origin: origin, size: CGSize(width: 500, height: 400)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
    }

    @Test func aScreenPointResolvesToTheSmallestRegisteredRegionInThatWindow() {
        let window = makeWindow(origin: CGPoint(x: 200, y: 150))
        let root = window.contentView!
        let bindings = InspectRootBindings()
        let registry = InspectRegistry()
        let windowID = InspectWindowID(rawValue: 61)
        bindings.bind(windowID: windowID, window: window, rootView: root)

        let outerToken = UUID()
        let innerToken = UUID()
        registry.upsert(
            registration(windowID, .generalChat.thread, CGRect(x: 0, y: 0, width: 400, height: 300), outerToken, depth: 0)
        )
        registry.upsert(
            registration(windowID, .generalChat.input, CGRect(x: 20, y: 40, width: 120, height: 60), innerToken, depth: 1)
        )

        let rootPoint = CGPoint(x: 60, y: 70)
        let screenPoint = window.convertPoint(toScreen: root.convert(rootPoint, to: nil))
        let resolvedRoot = InspectCoordinateConverter.windowRootPoint(
            fromScreenPoint: screenPoint, window: window, rootView: root
        )

        #expect(abs(resolvedRoot.x - rootPoint.x) < 0.001)
        #expect(abs(resolvedRoot.y - rootPoint.y) < 0.001)

        let hit = registry.hitTest(rootPoint: resolvedRoot, in: windowID)
        #expect(hit?.key.instanceToken == innerToken)
    }

    @Test func aPointInsideOnlyTheAncestorResolvesToTheAncestor() {
        let window = makeWindow(origin: CGPoint(x: 40, y: 60))
        let root = window.contentView!
        let registry = InspectRegistry()
        let windowID = InspectWindowID(rawValue: 62)
        let outerToken = UUID()
        registry.upsert(
            registration(windowID, .generalChat.thread, CGRect(x: 0, y: 0, width: 400, height: 300), outerToken, depth: 0)
        )
        registry.upsert(
            registration(windowID, .generalChat.input, CGRect(x: 20, y: 40, width: 120, height: 60), UUID(), depth: 1)
        )

        let rootPoint = CGPoint(x: 300, y: 250)
        let screenPoint = window.convertPoint(toScreen: root.convert(rootPoint, to: nil))
        let resolvedRoot = InspectCoordinateConverter.windowRootPoint(
            fromScreenPoint: screenPoint, window: window, rootView: root
        )

        #expect(registry.hitTest(rootPoint: resolvedRoot, in: windowID)?.key.instanceToken == outerToken)
    }

    @Test func twoWindowsAtDifferentOriginsResolveOneScreenPointDifferently() {
        let first = makeWindow(origin: CGPoint(x: 0, y: 0))
        let second = makeWindow(origin: CGPoint(x: 300, y: 200))
        let screenPoint = CGPoint(x: 320, y: 240)

        let firstRoot = InspectCoordinateConverter.windowRootPoint(
            fromScreenPoint: screenPoint, window: first, rootView: first.contentView!
        )
        let secondRoot = InspectCoordinateConverter.windowRootPoint(
            fromScreenPoint: screenPoint, window: second, rootView: second.contentView!
        )

        #expect(firstRoot != secondRoot)
    }

    @Test func aPointOutsideEveryRegionResolvesToNothing() {
        let window = makeWindow(origin: .zero)
        let registry = InspectRegistry()
        let windowID = InspectWindowID(rawValue: 63)
        registry.upsert(
            registration(windowID, .generalChat.thread, CGRect(x: 0, y: 0, width: 100, height: 100), UUID(), depth: 0)
        )

        #expect(registry.hitTest(rootPoint: CGPoint(x: 400, y: 380), in: windowID) == nil)
    }

    private func registration(
        _ windowID: InspectWindowID,
        _ id: InspectID,
        _ frame: CGRect,
        _ token: UUID,
        depth: Int
    ) -> InspectRegistration {
        InspectRegistration(
            key: InspectRegistryKey(windowID: windowID, id: id, instanceToken: token),
            frameInWindowRoot: frame,
            source: InspectSource(file: "Developer/Test.swift", line: 1, type: "body"),
            depth: depth
        )
    }
}
```

- [ ] **Step 2: Run the focused tests**

```bash
osascript -e 'quit app "Context-Dock"'
./scripts/test.sh -only-testing:Context-DockTests/InspectorHitResolutionTests
```

Expected: these may already pass, since they exercise P0 plus Task 1. That is fine — they are the regression net for the conversion contract. If they fail, the conversion is wrong and Task 4 must not proceed.

- [ ] **Step 3: Implement the session controller**

Create `Context-Dock/Developer/InspectorSessionController.swift`:

```swift
#if DEBUG
import AppKit
import Foundation

/// The one owner of Inspect Mode.
///
/// Everything expensive lives behind `isEnabled`: the event monitors, the registry's change
/// emission, and the overlay windows. While Inspect Mode is off this object holds nothing and
/// costs nothing, which is the whole reason the pre-release audit's finding about always-on
/// mouse-moved delivery is not quietly undone by adding a developer tool.
@MainActor
final class InspectorSessionController {
    static let shared = InspectorSessionController()

    private let state = InspectorSessionState()
    private let registry: InspectRegistry
    private let bindings: InspectRootBindings

    private var overlays: [InspectWindowID: InspectorOverlayController] = [:]
    private var monitors: [Any] = []
    private var detailPanel: InspectorDetailPanelController?

    var isEnabled: Bool { state.isEnabled }

    init(
        registry: InspectRegistry = .shared,
        bindings: InspectRootBindings = .shared
    ) {
        self.registry = registry
        self.bindings = bindings
    }

    func toggle() {
        state.isEnabled ? disable() : enable()
    }

    func enable() {
        guard state.enable() else { return }
        registry.emitsChanges = true
        installMonitors()
        reconcile()
    }

    func disable() {
        guard state.disable() else { return }
        registry.emitsChanges = false
        removeMonitors()
        for overlay in overlays.values { overlay.tearDown() }
        overlays.removeAll()
        detailPanel?.close()
        detailPanel = nil
    }

    /// Screen point → the window under it → that window's root space → the registry.
    /// This is the only place a hit is decided, and it uses the P0 converter verbatim.
    func resolveHit(atScreenPoint screenPoint: CGPoint) -> InspectRegistration? {
        for windowID in registry.windowIDs() {
            guard let binding = bindings.binding(for: windowID) else { continue }
            guard binding.window.isVisible else { continue }

            let rootPoint = InspectCoordinateConverter.windowRootPoint(
                fromScreenPoint: screenPoint,
                window: binding.window,
                rootView: binding.rootView
            )
            if let hit = registry.hitTest(rootPoint: rootPoint, in: windowID) {
                return hit
            }
        }
        return nil
    }

    // MARK: - Monitors

    private func installMonitors() {
        removeMonitors()

        let moved = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.handleHover()
            return event
        }
        let globalMoved = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.handleHover()
        }
        // Only the Option-click Inspect Mode actually handles is swallowed; every other
        // click returns unchanged, so product surfaces behave exactly as before.
        let clicked = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, event.modifierFlags.contains(.option) else { return event }
            return self.handleOptionClick() ? nil : event
        }
        let keyed = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event }  // Escape
            return self.handleEscape() ? nil : event
        }

        monitors = [moved, globalMoved, clicked, keyed].compactMap { $0 }
    }

    private func removeMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    // MARK: - Event handling

    private func handleHover() {
        let hit = resolveHit(atScreenPoint: NSEvent.mouseLocation)
        guard state.hover(hit?.key) else { return }
        redraw()
    }

    private func handleOptionClick() -> Bool {
        let hit = resolveHit(atScreenPoint: NSEvent.mouseLocation)
        guard state.lock(hit?.key) else { return hit != nil }
        redraw()
        return true
    }

    private func handleEscape() -> Bool {
        switch state.escape() {
        case .ignored:
            return false
        case .clearedLock:
            detailPanel?.close()
            detailPanel = nil
            redraw()
            return true
        case .disabled:
            disable()
            return true
        }
    }

    // MARK: - Reconciliation and drawing

    private func reconcile() {
        guard state.isEnabled else { return }

        let liveKeys = Set(
            registry.windowIDs().flatMap { registry.registrations(in: $0).map(\.key) }
        )
        state.reconcile(liveKeys: liveKeys)

        let eligible = Set(registry.windowIDs().filter { bindings.binding(for: $0) != nil })

        for (windowID, overlay) in overlays where !eligible.contains(windowID) {
            overlay.tearDown()
            overlays.removeValue(forKey: windowID)
        }
        for windowID in eligible where overlays[windowID] == nil {
            guard let binding = bindings.binding(for: windowID) else { continue }
            overlays[windowID] = InspectorOverlayController(
                windowID: windowID, owner: binding.window, rootView: binding.rootView
            )
        }

        redraw()
    }

    private func redraw() {
        reconcileIfNeeded()

        let activeKey = state.lockedKey ?? state.hoveredKey
        let active = activeKey.flatMap { registry.registration(for: $0) }

        for (windowID, overlay) in overlays {
            overlay.followOwnerFrame()
            guard let active, active.key.windowID == windowID else {
                overlay.show(highlight: nil)
                continue
            }
            let ordinal = registry.ordinal(for: active.key)
            overlay.show(
                highlight: InspectorHighlight(
                    frameInWindowRoot: active.frameInWindowRoot,
                    label: ordinal.map { "\(active.key.id.rawValue) #\($0)" } ?? active.key.id.rawValue,
                    isLocked: state.lockedKey != nil
                )
            )
        }

        if let active, state.lockedKey != nil {
            presentDetailPanel(for: active)
        }
    }

    /// A window can appear or vanish between two pointer moves. Reconciling on demand keeps
    /// overlays honest without a timer.
    private func reconcileIfNeeded() {
        let eligible = Set(registry.windowIDs().filter { bindings.binding(for: $0) != nil })
        guard eligible != Set(overlays.keys) else { return }
        reconcile()
    }

    private func presentDetailPanel(for registration: InspectRegistration) {
        let panel = detailPanel ?? InspectorDetailPanelController()
        detailPanel = panel
        panel.present(
            registration: registration,
            ordinal: registry.ordinal(for: registration.key),
            isExactRegion: isExactRegion(registration)
        )
    }

    /// P0 does not record descendant coverage, so this is a statement about registry
    /// precision, not a claim about the SwiftUI leaf under the pixel.
    private func isExactRegion(_ registration: InspectRegistration) -> Bool {
        let siblings = registry.registrations(in: registration.key.windowID)
        return !siblings.contains { other in
            other.key != registration.key
                && registration.frameInWindowRoot.contains(other.frameInWindowRoot)
        }
    }
}
#endif
```

`reconcile()` is called on enable and whenever the eligible window set changes. Do not add a timer, a polling loop, or a Combine subscription to registry `revision` in this task — `revision` remains the seam a later phase may use.

- [ ] **Step 4: Run focused tests, then the whole suite**

```bash
./scripts/test.sh -only-testing:Context-DockTests/InspectorHitResolutionTests
./scripts/test.sh
```

Expected: all pass, truthful exit code and count.

- [ ] **Step 5: Build and checkpoint**

```bash
./scripts/dev-run.sh
```

Expected: still no visible change — nothing calls `toggle()` until Task 5. Show the diff and results, wait for approval. Optional approved commit:

```bash
git add Context-Dock/Developer/InspectorSessionController.swift \
        Context-DockTests/InspectorHitResolutionTests.swift
git commit -m "feat(inspector): route hover, lock and escape through one session"
```

---

### Task 5: Detail Panel, DEBUG Hotkey and the General Chat Proof

**Files:**
- Create: `Context-Dock/Developer/InspectorDetailPanel.swift`
- Modify: `Context-Dock/App/ILauncherApp.swift`

**Interfaces:**
- Consumes: `InspectorSessionController.shared`, `InspectRegistration`, `InspectSource`.
- Produces: `InspectorDetailPanelController` with `present(registration:ordinal:isExactRegion:)` and `close()`, plus DEBUG-only `⌥⌘I`.

> **Concurrent-work warning.** `ILauncherApp.swift` is currently modified by another session. Before editing, re-read `git status --short` and `git log --oneline -3`. Add the new registration as a self-contained `#if DEBUG` block and a single call site; do not reformat, reorder, or touch neighbouring hotkey functions. Stage only this file and the new Developer file — never `git add -A`.

- [ ] **Step 1: Implement the detail panel**

Create `Context-Dock/Developer/InspectorDetailPanel.swift`:

```swift
#if DEBUG
import AppKit
import SwiftUI

/// One shared, non-activating panel showing what the registry knows about the locked region.
///
/// Non-activating because reading it must not steal key status from the surface being
/// inspected — a panel that takes focus changes the very state a developer is trying to look
/// at.
@MainActor
final class InspectorDetailPanelController {
    private let panel: NSPanel
    private let model = InspectorDetailModel()

    init() {
        panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 380, height: 220),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "DoraX Inspector"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: InspectorDetailView(model: model))
    }

    func present(registration: InspectRegistration, ordinal: Int?, isExactRegion: Bool) {
        model.id = registration.key.id.rawValue
        model.ordinal = ordinal
        model.source = "\(registration.source.file):\(registration.source.line)"
        model.type = registration.source.type
        model.frame = registration.frameInWindowRoot
        model.windowID = registration.key.windowID.rawValue
        model.precision = isExactRegion ? "Exact instrumented region" : "Nearest instrumented ancestor"
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
    }
}

@MainActor
final class InspectorDetailModel: ObservableObject {
    @Published var id = ""
    @Published var ordinal: Int?
    @Published var source = ""
    @Published var type = ""
    @Published var frame = CGRect.zero
    @Published var windowID = 0
    @Published var precision = ""
}

private struct InspectorDetailView: View {
    @ObservedObject var model: InspectorDetailModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.ordinal.map { "\(model.id) #\($0)" } ?? model.id)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))

            row("Source", model.source)
            row("Type", model.type)
            row("Frame", String(
                format: "x %.0f  y %.0f  w %.0f  h %.0f",
                model.frame.minX, model.frame.minY, model.frame.width, model.frame.height
            ))
            row("Window", "\(model.windowID)")
            row("Precision", model.precision)

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
#endif
```

- [ ] **Step 2: Register the DEBUG hotkey**

In `Context-Dock/App/ILauncherApp.swift`, add a stored property beside the existing `EventHotKeyRef` declarations (they start around line 424):

```swift
    #if DEBUG
    var inspectorHotKeyRef: EventHotKeyRef?
    var inspectorEventHandlerRef: EventHandlerRef?
    #endif
```

Then add this function, following the exact shape of `registerAppChatHotkey()` at line 1776. Signature `'ILdi'` (`0x494C_6469`) and id `77` are unused — taken ids are 3, 4, 5, 9, 41, 42, 43 and 45. Key code `34` is `I`; modifiers are Option + Command:

```swift
    #if DEBUG
    /// Developer Inspector toggle. DEBUG only, fixed, and absent from hotkey settings — this
    /// is developer infrastructure, not a product hotkey a user can rebind or discover.
    func registerInspectorHotkey() {
        if let ref = inspectorEventHandlerRef {
            RemoveEventHandler(ref)
            inspectorEventHandlerRef = nil
        }
        if let ref = inspectorHotKeyRef {
            UnregisterEventHotKey(ref)
            inspectorHotKeyRef = nil
        }
        let hotKeyID = EventHotKeyID(signature: FourCharCode(bitPattern: 0x494C_6469), id: 77)  // 'ILdi'
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { (_, event, userData) -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var receivedID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &receivedID)
            guard status == noErr,
                receivedID.signature == FourCharCode(bitPattern: 0x494C_6469),
                receivedID.id == 77
            else { return OSStatus(eventNotHandledErr) }
            guard userData?.assumingMemoryBound(to: AppDelegate.self).pointee != nil else {
                return OSStatus(eventNotHandledErr)
            }
            InspectorSessionController.shared.toggle()
            return noErr
        }
        var selfPtr = UnsafeMutablePointer<AppDelegate>.allocate(capacity: 1)
        selfPtr.initialize(to: self)
        var handlerRef: EventHandlerRef?
        InstallEventHandler(
            GetApplicationEventTarget(), handler, 1, &eventType, selfPtr, &handlerRef)
        inspectorEventHandlerRef = handlerRef

        let optionCommand = UInt32(optionKey | cmdKey)
        let status = RegisterEventHotKey(
            34, optionCommand, hotKeyID, GetApplicationEventTarget(), 0, &inspectorHotKeyRef)
        if status != noErr {
            // Fails closed: Inspect Mode is simply unavailable this launch. Never displace a
            // product hotkey to win the registration.
            NSLog("[Inspector] ⌥⌘I unavailable (RegisterEventHotKey status \(status))")
            inspectorHotKeyRef = nil
        }
    }
    #endif
```

Call it once from `applicationDidFinishLaunching`, after the other hotkey registrations, wrapped in `#if DEBUG`. In `applicationWillTerminate`, add a `#if DEBUG` block that calls `InspectorSessionController.shared.disable()`, then unregisters the hotkey and removes the handler.

- [ ] **Step 3: Run the whole suite**

```bash
osascript -e 'quit app "Context-Dock"'
./scripts/test.sh
```

Expected: zero failures, truthful exit code. Read the verdict line and the count together.

- [ ] **Step 4: Build, relaunch and run the manual proof**

```bash
./scripts/dev-run.sh
```

General Chat is the only instrumented surface, so it is the whole proof. Walk it in order:

1. With Inspect Mode off, use General Chat normally — type, send, scroll. Nothing about it changes.
2. Press `⌥⌘I`. Hover General Chat: a highlight and the label `generalChat.thread #0` appear. Layout does not shift.
3. Hover away from any instrumented region: the highlight clears.
4. `⌥`-click the region: the highlight turns locked, the detail panel opens showing `generalChat.thread #0`, `Search/GeneralChatSurface.swift:37`, the frame, the window id, and a precision line.
5. Move the pointer while locked: the panel and highlight do not follow it.
6. Press Escape once: lock clears, panel closes, Inspect Mode is still on.
7. Press Escape again: Inspect Mode is off, no overlay, no panel.
8. Toggle on/off five times, and open/close General Chat while enabled: no duplicate overlays, no duplicate panels, no crash.
9. Move the General Chat window while an overlay is showing: the overlay follows.
10. With Inspect Mode off, confirm ordinary clicks and typing everywhere in DoraX are unchanged.
11. Confirm no `[Capture Bug]` button, no screenshot, and no new user-facing mode exists anywhere.

- [ ] **Step 5: Refresh the graph and validate the diff**

```bash
graphify update .
git diff --check
git status --short
```

Generated `graphify-out/` churn is expected and is not staged. Confirm every changed path belongs to this plan and that the pre-existing unrelated modifications listed in Global Constraints are still untouched.

- [ ] **Step 6: Final P1 approval gate**

Give the user the build result, the full-suite verdict and count, the manual checklist outcome, and the explicit path list. Stop. Do not begin P2. Optional approved commit:

```bash
git add Context-Dock/Developer/InspectorDetailPanel.swift \
        Context-Dock/App/ILauncherApp.swift
git commit -m "feat(inspector): toggle inspect mode and read a locked region"
```

---

## Plan Self-Review

- **Spec coverage.** Activation (Task 5), hover (Task 4), lock (Task 4), non-activating detail panel (Task 5), monitor and overlay teardown (Tasks 3-4), window/registry reconciliation (Tasks 1 and 4), focused tests (Tasks 1-4), and the General Chat manual proof (Task 5) each have an owner. The design's five-step delivery sequence maps onto these five tasks in order.
- **Scope exclusions.** No screenshot, note, state serialization, `sourceCandidates`, packet, DiagnosticsPanel, IPC, scenario, repair-session or CLI-handoff code appears anywhere, and Task 5's manual checklist explicitly verifies their absence.
- **Type consistency.** `InspectRegistryKey`, `InspectRegistration`, `InspectWindowID`, `InspectSource` are used exactly as P0 defines them. `InspectorHighlight` is produced in Task 3 and consumed in Task 4. `InspectorDetailPanelController` is referenced in Task 4 and defined in Task 5 — the only forward reference, and Task 4's build therefore completes only once Task 5 lands; if Tasks 4 and 5 are executed separately, stub `InspectorDetailPanelController` in Task 4 or execute the two together.
- **Placeholder scan.** No TBD, TODO, "handle edge cases", or "similar to Task N". Every code step carries real code and every verification step carries an expected result.
- **Cost.** Monitors, registry emission and overlay windows exist only while enabled; `acceptsMouseMovedEvents` on product windows is never touched.
- **Input safety.** No synthetic events. Only the Option-click and the Escape that Inspect Mode handles are consumed; every other event is returned unchanged.
- **Concurrent-work safety.** Every commit stages explicit paths; no broad stage, reset, stash, or checkout appears; Task 5 carries an explicit warning about `ILauncherApp.swift`.
