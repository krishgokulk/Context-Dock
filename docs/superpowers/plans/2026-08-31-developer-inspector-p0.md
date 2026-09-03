# Developer Inspector P0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Stop after each task so the user can build, test, and approve the next task.

**Goal:** Build the invisible, tested foundation for identifying important DoraX UI regions by stable semantic ID, source location, runtime instance, window, and measured bounds.

**Architecture:** `InspectID` is the shipping vocabulary and also supplies accessibility identifiers. DEBUG builds add a main-actor `InspectRegistry`, whose identity is `(windowID, InspectID, instanceToken)` and whose geometry is stored in window-root coordinates. A lightweight SwiftUI modifier owns its UUID for its view lifetime and registers geometry without publishing every frame change; P0 proves the integration on the General Chat container only.

**Tech Stack:** Swift 5, SwiftUI, AppKit, swift-testing, macOS 26.1, Xcode filesystem-synchronized groups.

**Spec:** `docs/superpowers/specs/2026-08-26-developer-inspector-design.md`

## Global Constraints

- P0 only: vocabulary, registry, coordinate conversion, modifier, tests, and one real-surface proof.
- Do not add the inspector overlay, bug packet, CLI handoff, repair session, IPC channel, or scenarios from P1-P5.
- Preserve the product-layer boundaries in `AGENTS.md`; developer infrastructure observes General Chat and does not become a chat mode.
- `InspectID` and `.accessibilityIdentifier(id.rawValue)` compile in all configurations; registry and geometry collection compile only under `#if DEBUG`.
- Registry identity is exactly `(windowID, InspectID, instanceToken)`; ordinals are derived at read time and are never identity.
- Geometry is stored in the owning window's root coordinate space. Never treat SwiftUI `.global` coordinates as macOS screen coordinates.
- Geometry updates do not publish through `ObservableObject`; only an explicit inspector-enabled revision hook may notify a future P1 overlay.
- Do not touch or stage existing unrelated changes, especially `Context-Dock/AI/AppAdapterCapabilityCatalog.swift` and `Context-DockTests/CapabilityMatchEvalTests.swift`.
- After every code-edit task, run `./scripts/dev-run.sh`; run `./scripts/test.sh` only after stopping the running app with `./scripts/dev-stop.sh`.
- Stage only the explicit paths listed in the completed task, and commit only after the user has manually verified and approved that task.

---

## File Map

- Create `Context-Dock/Developer/InspectID.swift`: stable, enumerable semantic vocabulary that ships in release builds.
- Create `Context-Dock/Developer/InspectRegistry.swift`: DEBUG-only keys, metadata, snapshots, lifecycle, ordinal derivation, coordinate conversion, and hit-testing.
- Create `Context-Dock/Developer/InspectModifier.swift`: shipping accessibility identifier plus DEBUG-only view-instance lifetime and geometry registration.
- Modify `Context-Dock/Search/GeneralChatSurface.swift`: establish one named inspection root and instrument the General Chat surface as the P0 integration proof.
- Create `Context-DockTests/InspectIDTests.swift`: vocabulary uniqueness and expected P0 IDs.
- Create `Context-DockTests/InspectRegistryTests.swift`: repeated-ID lifecycle, stale removal, window purge, replacement, last-value-wins, ordinal order, and notification gating.
- Create `Context-DockTests/InspectCoordinateTests.swift`: coordinate conversion and smallest-region hit-testing.
- Create `Context-DockTests/InspectModifierTests.swift`: source-default and stable-instance seam tests without snapshot/UI-test dependencies.

### Public P0 Interfaces

```swift
struct InspectID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String
    init(rawValue: String)
    static let allCases: [InspectID]
}

#if DEBUG
struct InspectWindowID: RawRepresentable, Hashable, Sendable {
    let rawValue: Int
}

struct InspectSource: Equatable, Sendable {
    let file: String
    let line: Int
    let type: String
}

struct InspectRegistryKey: Hashable, Sendable {
    let windowID: InspectWindowID
    let id: InspectID
    let instanceToken: UUID
}

struct InspectRegistration: Equatable, Sendable {
    let key: InspectRegistryKey
    var frameInWindowRoot: CGRect
    var source: InspectSource
    var depth: Int
}

@MainActor
final class InspectRegistry {
    static let shared: InspectRegistry
    var emitsChanges: Bool { get set }
    private(set) var revision: UInt64

    func upsert(_ registration: InspectRegistration)
    func remove(windowID: InspectWindowID, id: InspectID, instanceToken: UUID)
    func purge(windowID: InspectWindowID)
    func registrations(in windowID: InspectWindowID) -> [InspectRegistration]
    func ordinal(for key: InspectRegistryKey) -> Int?
    func hitTest(rootPoint: CGPoint, in windowID: InspectWindowID) -> InspectRegistration?
}

enum InspectCoordinateConverter {
    static func windowRootPoint(
        fromScreenPoint screenPoint: CGPoint,
        window: NSWindow,
        rootView: NSView
    ) -> CGPoint
}
#endif

extension View {
    func doraxInspect(
        _ id: InspectID,
        file: String = #fileID,
        line: Int = #line,
        type: String = #function
    ) -> some View
}
```

---

### Task 1: Typed InspectID Vocabulary

**Files:**
- Create: `Context-Dock/Developer/InspectID.swift`
- Create: `Context-DockTests/InspectIDTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `InspectID`, nested `generalChat`, `contextDockChat`, and `shared` namespaces, plus `allCases`.

- [ ] **Step 1: Write the failing vocabulary tests**

Add tests that compile against typed members and fail because `InspectID` does not exist yet:

```swift
import Testing
@testable import Context_Dock

struct InspectIDTests {
    @Test func p0VocabularyIsUnique() {
        let values = InspectID.allCases.map(\.rawValue)
        #expect(Set(values).count == values.count)
    }

    @Test func p0VocabularyContainsTheApprovedFeatureBoundaries() {
        #expect(InspectID.allCases.contains(.generalChat.thread))
        #expect(InspectID.allCases.contains(.generalChat.input))
        #expect(InspectID.allCases.contains(.generalChat.send))
        #expect(InspectID.allCases.contains(.contextDockChat.thread))
        #expect(InspectID.allCases.contains(.shared.messageBubble))
        #expect(InspectID.allCases.contains(.shared.codeBlock))
    }
}
```

- [ ] **Step 2: Run only the new tests and confirm the expected compile failure**

Run:

```bash
./scripts/dev-stop.sh
./scripts/test.sh -only-testing:Context-DockTests/InspectIDTests
```

Expected: non-zero exit because `InspectID` is undefined. If the runner reports zero passing tests with an unnamed failure, treat that as infrastructure failure, not the intended red test.

- [ ] **Step 3: Implement the shipping vocabulary**

Define `InspectID` without `#if DEBUG`. Use nested namespaces so call sites are `.doraxInspect(.generalChat.thread)`, and define `allCases` explicitly from the same typed constants. Include only the approved P0 IDs:

```text
generalChat.thread
generalChat.message
generalChat.message.assistant
generalChat.message.user
generalChat.toolCard
generalChat.toolTimeline
generalChat.input
generalChat.attachments
generalChat.providerPicker
generalChat.sidebar
generalChat.send
contextDockChat.thread
contextDockChat.input
contextDockChat.header
contextDockChat.actionRow
shared.messageBubble
shared.markdownBody
shared.codeBlock
shared.streamingCursor
```

Do not accept arbitrary string literals at call sites beyond the public `RawRepresentable` initializer; all app instrumentation must use typed members.

- [ ] **Step 4: Run the focused tests**

Run the two commands from Step 2 again. Expected: both tests pass and `scripts/test.sh` exits 0.

- [ ] **Step 5: Build, relaunch, and manually verify no visible behavior changed**

Run `./scripts/dev-run.sh`. Confirm General Chat still opens and renders normally. This task has no visible Inspector UI.

- [ ] **Step 6: Review checkpoint**

Show the user the focused test result, build result, and exact diff for the two new files. Wait for approval before Task 2. After approval, the optional explicit-path commit is:

```bash
git add Context-Dock/Developer/InspectID.swift Context-DockTests/InspectIDTests.swift
git commit -m "feat(inspector): add stable developer UI identifiers"
```

---

### Task 2: Per-Instance Registry Lifecycle and Read-Time Ordinals

**Files:**
- Create: `Context-Dock/Developer/InspectRegistry.swift`
- Create: `Context-DockTests/InspectRegistryTests.swift`

**Interfaces:**
- Consumes: `InspectID` from Task 1.
- Produces: `InspectWindowID`, `InspectSource`, `InspectRegistryKey`, `InspectRegistration`, and the `@MainActor InspectRegistry` API shown above.

- [ ] **Step 1: Write the failing registry tests**

Use a fresh registry instance per test; keep its initializer internal so `@testable` can construct it. Cover these exact cases:

```swift
@MainActor @Test func twentyInstancesOfOneIDCoexist()
@MainActor @Test func removingOneInstanceLeavesTheOtherNineteen()
@MainActor @Test func staleRemovalCannotDeleteAReplacementInstance()
@MainActor @Test func purgingAWindowRemovesOnlyThatWindowsEntries()
@MainActor @Test func recreatingAWindowDoesNotRevivePurgedEntries()
@MainActor @Test func repeatedUpsertKeepsOnlyTheLatestGeometry()
@MainActor @Test func ordinalsFollowVerticalThenHorizontalFrameOrder()
@MainActor @Test func geometryDoesNotAdvanceRevisionWhileEmissionIsDisabled()
@MainActor @Test func enabledEmissionAdvancesRevisionOnlyForRealChanges()
```

The stale-removal test must use two different UUID tokens for the same window and ID. The ordinal test must register in deliberately scrambled order and expect top-to-bottom, then left-to-right ordering.

- [ ] **Step 2: Run the registry test target and confirm it fails to compile**

Run:

```bash
./scripts/dev-stop.sh
./scripts/test.sh -only-testing:Context-DockTests/InspectRegistryTests
```

Expected: non-zero exit because registry types are undefined.

- [ ] **Step 3: Implement registry identity and storage**

Implement `InspectRegistry` as a plain `@MainActor final class`, not `ObservableObject`. Store registrations in `[InspectRegistryKey: InspectRegistration]`. `upsert` replaces only the exact key; `remove` removes only the exact token; `purge` filters by window. Return snapshots sorted deterministically.

`revision` is an opt-in future-overlay seam:

```swift
private(set) var revision: UInt64 = 0
var emitsChanges = false

private func recordMutation(changed: Bool) {
    guard changed, emitsChanges else { return }
    revision &+= 1
}
```

Do not add `@Published`, Combine subjects, notification posts, geometry history, timers, or persistence in P0.

- [ ] **Step 4: Implement ordinal derivation**

For registrations sharing `(windowID, InspectID)`, sort by `frame.minY`, then `frame.minX`, then `instanceToken.uuidString` for deterministic ties. Return the zero-based index of the exact key. Never store an ordinal.

- [ ] **Step 5: Run focused tests and then the complete suite**

Run:

```bash
./scripts/test.sh -only-testing:Context-DockTests/InspectRegistryTests
./scripts/test.sh
```

Expected: the focused tests and full offline suite pass with zero failed tests and a truthful exit code.

- [ ] **Step 6: Build, relaunch, and checkpoint**

Run `./scripts/dev-run.sh`; expect no visible change. Show the user test/build results and the explicit two-file diff, then wait. Optional approved commit:

```bash
git add Context-Dock/Developer/InspectRegistry.swift Context-DockTests/InspectRegistryTests.swift
git commit -m "feat(inspector): track UI regions by runtime instance"
```

---

### Task 3: Explicit Coordinate Conversion and Deterministic Hit Testing

**Files:**
- Modify: `Context-Dock/Developer/InspectRegistry.swift`
- Create: `Context-DockTests/InspectCoordinateTests.swift`

**Interfaces:**
- Consumes: registry snapshots from Task 2, `NSWindow.convertPoint(fromScreen:)`, and `NSView.convert(_:from:)`.
- Produces: `InspectCoordinateConverter.windowRootPoint(fromScreenPoint:window:rootView:)` and `InspectRegistry.hitTest(rootPoint:in:)`.

- [ ] **Step 1: Write pure hit-test failures first**

Add tests for:

- the smallest-area containing region wins over its ancestor;
- equal-area ties prefer greater registration depth;
- a remaining tie is deterministic by ID then token;
- a point outside every region returns `nil`;
- registrations from another window never match.

- [ ] **Step 2: Write coordinate-conversion tests**

Create borderless `NSWindow` and root `NSView` fixtures on `@MainActor`. Verify:

- non-zero screen origin converts into the expected window point;
- an offset root view converts from window coordinates correctly;
- two windows with different origins produce different root points for one screen point;
- `window.convertPoint(toScreen:)` followed by the helper round-trips within `0.001` points.

These tests must exercise AppKit conversion APIs rather than reimplementing the arithmetic in the test.

- [ ] **Step 3: Run the focused tests and verify red results**

Run:

```bash
./scripts/dev-stop.sh
./scripts/test.sh -only-testing:Context-DockTests/InspectCoordinateTests
```

Expected: compile failures for the missing helper and hit-test method.

- [ ] **Step 4: Implement conversion and hit testing**

The production conversion order is exactly:

```swift
let windowPoint = window.convertPoint(fromScreen: screenPoint)
return rootView.convert(windowPoint, from: nil)
```

Document that the registry accepts only the returned root-space point. In `hitTest`, filter by window and `frame.contains(rootPoint)`, then sort by ascending area, descending depth, `id.rawValue`, and `instanceToken.uuidString`.

- [ ] **Step 5: Run focused tests, full suite, and build**

Run:

```bash
./scripts/test.sh -only-testing:Context-DockTests/InspectCoordinateTests
./scripts/test.sh
./scripts/dev-run.sh
git diff --check
```

Expected: all tests pass, Debug app launches, and diff check is clean.

- [ ] **Step 6: Review checkpoint**

Show the coordinate fixtures and hit-test ordering to the user. Wait before Task 4. Optional approved commit:

```bash
git add Context-Dock/Developer/InspectRegistry.swift Context-DockTests/InspectCoordinateTests.swift
git commit -m "feat(inspector): resolve window coordinates and UI hits"
```

---

### Task 4: Modifier Lifetime and One Real-Surface Proof

**Files:**
- Create: `Context-Dock/Developer/InspectModifier.swift`
- Create: `Context-DockTests/InspectModifierTests.swift`
- Modify: `Context-Dock/Search/GeneralChatSurface.swift`

**Interfaces:**
- Consumes: typed IDs and DEBUG registry APIs from Tasks 1-3.
- Produces: `.doraxInspect(_:file:line:type:)`, stable per-modifier UUID ownership, and the first real registration on `GeneralChatSurface`.

- [ ] **Step 1: Add testable modifier seams and failing tests**

Keep SwiftUI rendering itself for manual verification, but make the failure-prone values unit-testable:

```swift
#if DEBUG
struct InspectModifierIdentity {
    let instanceToken: UUID
    init(instanceToken: UUID = UUID()) { self.instanceToken = instanceToken }
}

struct InspectCallSite: Equatable {
    let source: InspectSource
}
#endif
```

Tests must prove that an injected token remains unchanged through repeated registration updates, that two modifier identities receive different default tokens, and that explicit `file`, `line`, and `type` values flow unchanged into `InspectSource`.

- [ ] **Step 2: Run focused tests and confirm the missing-type failure**

Run:

```bash
./scripts/dev-stop.sh
./scripts/test.sh -only-testing:Context-DockTests/InspectModifierTests
```

- [ ] **Step 3: Implement the modifier**

The release path applies only `.accessibilityIdentifier(id.rawValue)`. The DEBUG modifier owns its token in `@State`, measures in a named window-root coordinate space, and performs exact-key upsert/removal. It must not create `UUID()` inside `body`, publish on every geometry update, install a global mouse monitor, or capture screenshots.

Use a private environment value for the current `InspectWindowID` and a private named coordinate-space constant owned by the root. If no window ID is available, accessibility identity still applies and DEBUG registration fails closed—do not invent window `0`.

- [ ] **Step 4: Instrument only the General Chat container**

In `GeneralChatSurface.body`, establish the named inspection coordinate space at the outer container and add:

```swift
.doraxInspect(.generalChat.thread)
```

Resolve the real `NSWindow.windowNumber` through a tiny `NSViewRepresentable` bridge local to `InspectModifier.swift`, then inject it into the surface environment. Do not edit `LauncherView+AIChat.swift`, `AIMessageViews.swift`, Context Dock Chat, or any other surface in P0.

- [ ] **Step 5: Run focused tests and full suite**

Run:

```bash
./scripts/test.sh -only-testing:Context-DockTests/InspectModifierTests
./scripts/test.sh
```

Expected: all tests pass. Confirm the full-suite verdict and counts together.

- [ ] **Step 6: Build and perform the P0 manual proof**

Run `./scripts/dev-run.sh`, open General Chat, and verify:

- the surface looks and behaves exactly as before;
- Accessibility Inspector exposes `generalChat.thread` on the container;
- repeated open/close does not crash or retain an obviously stale surface;
- no Inspector overlay, panel, hover tracking, screenshot capture, or new user-facing mode exists.

- [ ] **Step 7: Refresh navigation graphs and validate the final diff**

Run:

```bash
graphify update .
git diff --check
git status --short
```

Treat generated `graphify-out/` dirt as expected and do not stage it. Confirm every modified source/test path belongs to this P0 plan and all pre-existing unrelated changes remain untouched.

- [ ] **Step 8: Final P0 approval gate**

Give the user the build result, focused/full test result, manual checklist, and explicit path list. Stop for their verification; do not begin P1. Optional approved commit:

```bash
git add Context-Dock/Developer/InspectModifier.swift Context-Dock/Search/GeneralChatSurface.swift Context-DockTests/InspectModifierTests.swift
git commit -m "feat(inspector): instrument the General Chat surface"
```

---

## Plan Self-Review

- Spec coverage: P0 vocabulary, per-instance identity, lifecycle removal, window purge, coordinate conversion, smallest-region hit testing, non-invalidating geometry, stable modifier identity, accessibility reuse, and one surface proof are each assigned to a task.
- Scope exclusions: P1-P5 artifacts are explicitly prohibited in Global Constraints and Task 4 verification.
- Type consistency: all later tasks use the interfaces declared under Public P0 Interfaces; ordinals remain derived and window identity remains explicit.
- Placeholder scan: the plan contains no TBD/TODO steps; each implementation and verification action has an expected result.
- Concurrent-work safety: every commit uses explicit paths; no broad stage/reset/stash/checkout operation appears.
