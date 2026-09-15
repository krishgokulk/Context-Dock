# Corner Dock Strip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The corner's Global Context pill rests as a Liquid Glass dock strip after 1 s idle — large running-app icons with a window row on hover, pinnable apps / global commands / CLI tools / files / folders — and the search field morphs back in on the first typed character.

**Architecture:** One new phase `.dock` on the existing `AppChatPromptPhase`; the pill draws field and strip as two `glassEffect` shapes inside one `GlassEffectContainer` so SwiftUI morphs them into each other. Pins live in a new `DockPinStore` persisted through `ContextDockStore`. Window thumbnails extend `AppWindowSnapshotService` from one image per app to one per window. Every size is a pure function in `AppChatPromptMetrics` / `CornerWindowRowMetrics`.

**Tech Stack:** Swift 5, SwiftUI (macOS 26 Liquid Glass: `GlassEffectContainer`, `.glassEffect`, `.glassEffectID`), AppKit (`NSEvent` local monitor, `NSWorkspace`), ScreenCaptureKit, swift-testing.

**Spec:** `docs/superpowers/specs/2026-09-15-corner-dock-strip-design.md`

## Global Constraints

- Surface: corner **Global Context only** — `model.isGlobalScope`. Never scoped app chat, General chat (`chatPresentation.mode == .general`), CLI scope, or the `.chat` phase.
- Setting key: `autoShrinkInputField`, default `true`. Off → behaviour identical to HEAD.
- Dwell: `AppChatPromptModel.dockDwell = 2` seconds. `.dock` has **no** idle timer.
- Strip geometry: icon 48 pt, gap 8 pt, inset 10 pt, divider span 17 pt (8 + 1 + 8), height 68 pt, max width `AppChatPromptMetrics.width * 1.6`.
- Window row: thumbnails 160 × 100, max 6, 250 ms show delay, 150 ms hide delay.
- Sizes come from metrics functions of model state only (memory `corner-pill-size-must-be-pure`).
- Arrow keys, Tab, Return, Esc, Backspace keep today's handlers in every phase. Only printable characters expand `.dock`.
- Build + relaunch after every code edit: `./scripts/dev-run.sh`. Tests: `./scripts/test.sh -only-testing:Context-DockTests/<Suite>` (quit the app first — the script refuses to run alongside it). Confirm tests ran **by name** in the output.
- Stage explicit paths only. Never `git add -A`.
- After code lands: `graphify update .`

## File map

| File | Responsibility |
|---|---|
| `Context-Dock/UI/AppChatPromptModel.swift` (modify) | `.dock` phase, `dockDwell`, `autoShrinkEnabled`, `hiddenRunningBundleIDs`, `stripIcons`, `expandFromDock`, `arrowRightFromDock`, `hoveredStripBundleID` |
| `Context-Dock/UI/AppChatPromptPill.swift` (modify) | `AppChatPromptMetrics` dock geometry; pill body morph between field and strip |
| `Context-Dock/UI/CornerDockStrip.swift` (new) | The strip: icons, magnify, divider, pins, context menus, drop/drag, click |
| `Context-Dock/UI/CornerWindowRow.swift` (new) | `CornerWindowRowMetrics` + thumbnail row |
| `Context-Dock/Services/DockPinStore.swift` (new) | `DockPinKind`, `DockPin`, `DockPinStore`, `DockPinKind.init?(document:)` / `init?(row:)` |
| `Context-Dock/Services/GlobalSearchService.swift` (modify) | `document(withID:)` |
| `Context-Dock/Services/AppWindowSnapshotService.swift` (modify) | `WindowCandidate`, `eligibleWindows`, `WindowSnapshot`, `windowSnapshots(for:)`, `refreshWindows(bundleID:)` |
| `Context-Dock/UI/CornerDockWindow.swift` (modify) | `promptSize` for `.dock`, key monitor for `.dock`, window-row slot |
| `Context-Dock/UI/AppChatListCard.swift` (modify) | "Pin to dock" context menu on rows |
| `Context-Dock/App/AppSettings.swift` (modify) | `autoShrinkInputField` |
| `Context-Dock/UI/LegacySettingsContent.swift` (modify) | General → toggle row |
| `Context-DockTests/CornerDockPhaseTests.swift` (new) | Phase machine |
| `Context-DockTests/AppChatPromptMetricsDockTests.swift` (new) | Geometry |
| `Context-DockTests/DockPinStoreTests.swift` (new) | Store + mapping |
| `Context-DockTests/WindowSnapshotFilterTests.swift` (new) | Window filter |

---

### Task 1: The `.dock` phase and its dwell

**Files:**
- Modify: `Context-Dock/UI/AppChatPromptModel.swift` (enum at ~L41, dwell constants ~L59, `touch()` ~L571, `hoverBegan()` ~L576, `standDown()` ~L626, `armForIdle()` ~L732)
- Test: `Context-DockTests/CornerDockPhaseTests.swift`

**Interfaces:**
- Consumes: `AppChatPromptModel(conversation:globalResultSource:)`, `summonGlobalContext()`, `scopeIntoApp(name:bundleID:)`, `set(_:)`, `standDown()`, `isGlobalScope`, `syncListPhase()`, `scopeIntoFirstRunningApp()`, `queryChanged()`.
- Produces:
  - `AppChatPromptPhase.dock`
  - `static let dockDwell: TimeInterval = 1`
  - `var autoShrinkEnabled: () -> Bool` (injectable; default reads `UserDefaults.standard` key `autoShrinkInputField`, missing → `true`)
  - `var canRestAsDock: Bool`
  - `@Published var hiddenRunningBundleIDs: Set<String>`
  - `var stripIcons: [MatchDockIcon]`
  - `@Published var hoveredStripBundleID: String?`
  - `@discardableResult func expandFromDock(seeding text: String?) -> Bool`
  - `@discardableResult func arrowRightFromDock() -> Bool`
  - `func hideRunningApp(_ bundleID: String)`

- [ ] **Step 1: Write the failing tests**

```swift
// Context-DockTests/CornerDockPhaseTests.swift
import Foundation
import Testing
@testable import Context_Dock

@MainActor
struct CornerDockPhaseTests {
    private func globalModel(autoShrink: Bool = true) -> AppChatPromptModel {
        let model = AppChatPromptModel(
            conversation: AppChatConversation(), globalResultSource: GlobalContextResultSource())
        model.autoShrinkEnabled = { autoShrink }
        model.summonGlobalContext()
        return model
    }

    @Test func idleGlobalPromptRestsAsDock() {
        let model = globalModel()
        #expect(model.phase == .prompt)
        model.standDown()
        #expect(model.phase == .dock)
    }

    @Test func dockNeverStandsDownFurther() {
        let model = globalModel()
        model.standDown()
        #expect(model.phase == .dock)
        model.standDown()
        model.standDown()
        #expect(model.phase == .dock)
    }

    @Test func settingOffKeepsTheMiniPath() {
        let model = globalModel(autoShrink: false)
        model.standDown()
        #expect(model.phase == .mini)
        model.standDown()
        #expect(model.phase == .hidden)
    }

    @Test func aScopedChatNeverDocks() {
        let model = globalModel()
        model.scopeIntoApp(name: "Safari", bundleID: "com.apple.Safari")
        model.set(.prompt)
        model.standDown()
        #expect(model.phase == .mini)
    }

    @Test func typedTextKeepsThePromptFromDocking() {
        let model = globalModel()
        model.query = "saf"
        model.standDown()
        #expect(model.phase == .mini)
    }

    @Test func pinnedAndAnsweringBlockTheDock() {
        let model = globalModel()
        model.togglePin()
        model.standDown()
        #expect(model.phase == .prompt)
        model.togglePin()
        model.set(.prompt)
        model.beginAnsweringForTests()
        model.standDown()
        #expect(model.phase == .prompt)
    }

    @Test func aPrintableCharacterExpandsAndSeeds() {
        let model = globalModel()
        model.standDown()
        #expect(model.expandFromDock(seeding: "s"))
        #expect(model.phase == .prompt)
        #expect(model.query == "s")
    }

    @Test func expandFromDockIsANoOpElsewhere() {
        let model = globalModel()
        #expect(!model.expandFromDock(seeding: "s"))
        #expect(model.query.isEmpty)
    }

    @Test func hoverDoesNotExpandTheDock() {
        let model = globalModel()
        model.standDown()
        model.hoverBegan()
        #expect(model.phase == .dock)
        model.hoverEnded()
        #expect(model.phase == .dock)
    }

    @Test func rightArrowFromDockScopesLikeAnEmptyPromptDoes() {
        let model = globalModel()
        model.standDown()
        // Whatever an empty Global prompt does on →, the dock does — and never seeds a character.
        let expected = globalModel().scopeIntoFirstRunningApp()
        let result = model.arrowRightFromDock()
        #expect(result == expected)
        #expect(model.query.isEmpty)
        #expect(model.phase != .dock)
    }

    @Test func removedRunningAppsLeaveTheStrip() {
        let model = globalModel()
        model.hideRunningApp("com.apple.Safari")
        #expect(model.stripIcons.allSatisfy { $0.bundleID != "com.apple.Safari" })
        #expect(model.hiddenRunningBundleIDs == ["com.apple.Safari"])
    }

    @Test func dockIsNotAnInputPhase() {
        #expect(!AppChatPromptPhase.dock.showsInput)
        #expect(AppChatPromptPhase.dock.isVisible)
    }
}
```

`beginAnsweringForTests()` does not exist yet — Step 3 adds a one-line `#if DEBUG` helper because `isAnswering` is `private(set)`. If `isAnswering` turns out to be settable, use it directly and drop the helper.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pkill -f "Context-Dock.app/Contents/MacOS/Context-Dock"; ./scripts/test.sh -only-testing:Context-DockTests/CornerDockPhaseTests`
Expected: compile failure — `.dock`, `autoShrinkEnabled`, `expandFromDock` undefined.

- [ ] **Step 3: Implement**

In `AppChatPromptPhase`:

```swift
enum AppChatPromptPhase: Equatable {
    case hidden
    /// Shrunk to the frontmost app's own icon, holding whatever was typed.
    case mini
    /// Global Context at rest: the field folded away, the running apps and the pins
    /// standing as a dock. Nothing typed, nothing waiting.
    case dock
    /// The input field alone: the user is writing a question.
    case prompt
    /// The input plus what this app can do, which is how it opens.
    case suggesting
    /// The conversation.
    case chat
    var isVisible: Bool { self != .hidden }
    /// Every one of these draws the same input row; only what sits under it differs.
    var showsInput: Bool { self == .prompt || self == .suggesting || self == .chat }
}
```

Constants and state, next to `idleDwell`:

```swift
    /// How long an untouched, empty Global field waits before folding into the dock.
    static let dockDwell: TimeInterval = 1

    /// Read through a closure so a test can flip it without touching UserDefaults. The
    /// key is the General settings toggle; absent means on.
    var autoShrinkEnabled: () -> Bool = {
        UserDefaults.standard.object(forKey: "autoShrinkInputField") as? Bool ?? true
    }

    /// Running apps the user took off the strip this session. Not persisted: like an icon
    /// dragged out of the Dock while its app runs, it comes back next launch.
    @Published var hiddenRunningBundleIDs: Set<String> = []

    /// The app whose icon the pointer is over in the strip, for the window row.
    @Published var hoveredStripBundleID: String?

    /// An empty Global field with the setting on is the only thing that rests as a dock.
    var canRestAsDock: Bool {
        isGlobalScope
            && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && autoShrinkEnabled()
    }

    /// The strip's running section: the dock's own running pills, minus the removed ones.
    var stripIcons: [MatchDockIcon] {
        globalMatchIcons.filter { icon in
            guard let bundleID = icon.bundleID else { return true }
            return !hiddenRunningBundleIDs.contains(bundleID)
        }
    }

    func hideRunningApp(_ bundleID: String) {
        hiddenRunningBundleIDs.insert(bundleID)
    }
```

`touch()` — a dock has no clock to put back:

```swift
    func touch() {
        guard !isPinned, !isAnswering, phase.isVisible, phase != .dock else { return }
        armForIdle()
    }
```

`hoverBegan()` — leave the `.mini` reopen as is; a dock stays a dock:

```swift
    func hoverBegan() {
        guard phase.isVisible else { return }
        isPointerInside = true
        if phase == .mini {
            set(hasPresentedConversation ? .chat : restingInputPhase)
        }
        cancel()
    }
```

`standDown()`:

```swift
    func standDown() {
        guard !isPinned, !isPointerInside, !isAnswering else { return }
        switch phase {
        case .suggesting:
            set(.prompt)
            armForIdle()
        case .prompt where canRestAsDock:
            // The dock has no timer of its own: it stays until Esc, a click outside, or a
            // Space switch, the way the Dock does.
            set(.dock)
        case .prompt, .chat:
            set(.mini)
            arm(after: Self.miniDwell)
        case .mini:
            dismiss()
        case .dock, .hidden:
            break
        }
    }
```

`armForIdle()`:

```swift
    private func armForIdle() {
        if phase == .suggesting { arm(after: Self.suggestionsDwell); return }
        arm(after: phase == .prompt && canRestAsDock ? Self.dockDwell : Self.idleDwell)
    }
```

Expanding and the arrow, placed after `standDown()`:

```swift
    /// The first printable character brings the field back and lands in it. Anything the
    /// field would have done with the key itself — arrows, Return, Esc — is not this.
    @discardableResult
    func expandFromDock(seeding text: String?) -> Bool {
        guard phase == .dock else { return false }
        set(.prompt)
        if let text, !text.isEmpty {
            query = text
            queryChanged()
        }
        armForIdle()
        return true
    }

    /// → on the dock does what → on an empty Global field does: step into the first
    /// running app. The caller falls through to the presentation's own right-arrow when
    /// there is nothing to step into.
    @discardableResult
    func arrowRightFromDock() -> Bool {
        guard phase == .dock else { return false }
        guard scopeIntoFirstRunningApp() else { return false }
        if phase == .dock {
            set(.prompt)
            syncListPhase()
        }
        return true
    }

    #if DEBUG
    func beginAnsweringForTests() { isAnswering = true }
    #endif
```

If `queryChanged()` is `private`, make it internal. If `isAnswering` is `private(set)`, the DEBUG helper above is needed; otherwise drop it.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh -only-testing:Context-DockTests/CornerDockPhaseTests`
Expected: `Test Suite 'CornerDockPhaseTests' passed`, 12 tests named in the output.

- [ ] **Step 5: Build the app and confirm nothing visible changed yet**

Run: `./scripts/dev-run.sh`
Expected: builds. The corner's Global field folds to a *blank* pill after 1 s — the strip is drawn in Task 5. Note this in the commit.

- [ ] **Step 6: Commit**

```bash
git add Context-Dock/UI/AppChatPromptModel.swift Context-DockTests/CornerDockPhaseTests.swift
git commit -m "feat(corner): Global Context rests as a dock phase after 1 s idle

The strip itself is not drawn yet; the phase, its dwell, the setting
hook and the expand/arrow rules are, with tests.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Dock geometry in `AppChatPromptMetrics`

**Files:**
- Modify: `Context-Dock/UI/AppChatPromptPill.swift:15-78` (`AppChatPromptMetrics`)
- Modify: `Context-Dock/UI/CornerDockWindow.swift:367-378` (`promptSize`)
- Test: `Context-DockTests/AppChatPromptMetricsDockTests.swift`

**Interfaces:**
- Consumes: `AppChatPromptMetrics.width`, `size(for:suggestions:messages:hasApproval:attachments:hasSelectionRow:)`, `AppChatPromptModel.stripIcons`, `DockPinStore.shared.pins` (Task 4 — until then pass `pinned: 0`).
- Produces:
  ```swift
  static let dockIconSize: CGFloat = 48
  static let dockIconGap: CGFloat = 8
  static let dockInset: CGFloat = 10
  static let dockDividerSpan: CGFloat = 17
  static let dockHeight: CGFloat = 68
  static var dockMaximumWidth: CGFloat
  struct DockLayout: Equatable { let shownRunning: Int; let overflow: Int; let width: CGFloat }
  static func dockLayout(running: Int, pinned: Int) -> DockLayout
  // size(for:) gains `running: Int = 0, pinned: Int = 0`
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// Context-DockTests/AppChatPromptMetricsDockTests.swift
import Foundation
import Testing
@testable import Context_Dock

struct AppChatPromptMetricsDockTests {
    typealias M = AppChatPromptMetrics

    @Test func oneRunningNoPins() {
        let layout = M.dockLayout(running: 1, pinned: 0)
        #expect(layout.width == 20 + 48)
        #expect(layout.shownRunning == 1)
        #expect(layout.overflow == 0)
    }

    @Test func fourRunningNoPins() {
        #expect(M.dockLayout(running: 4, pinned: 0).width == 20 + 4 * 48 + 3 * 8)
    }

    @Test func pinsAddADividerAndTheirOwnRun() {
        let layout = M.dockLayout(running: 4, pinned: 3)
        #expect(layout.width == 20 + (4 * 48 + 3 * 8) + 17 + (3 * 48 + 2 * 8))
    }

    @Test func zeroOfBothStillDrawsOneSlot() {
        // Finder is always running, but the arithmetic must not go negative either way.
        #expect(M.dockLayout(running: 0, pinned: 0).width == 20 + 48)
    }

    @Test func runningOverflowsIntoAPlusPill() {
        let layout = M.dockLayout(running: 12, pinned: 0)
        #expect(layout.width <= M.dockMaximumWidth)
        #expect(layout.overflow > 0)
        #expect(layout.shownRunning + 1 <= 12)  // the +N pill takes one slot
        #expect(layout.shownRunning + layout.overflow == 12)
    }

    @Test func pinsAreNeverOverflowed() {
        let layout = M.dockLayout(running: 12, pinned: 5)
        #expect(layout.width <= M.dockMaximumWidth)
        // Pins keep every slot; running gives way.
        let pinsWidth = 17 + 5 * 48 + 4 * 8
        #expect(layout.width >= 20 + 48 + pinsWidth)
    }

    @Test func sizeForDockUsesTheLayout() {
        let size = M.size(for: .dock, suggestions: 0, running: 4, pinned: 3)
        #expect(size.height == 68)
        #expect(size.width == M.dockLayout(running: 4, pinned: 3).width)
    }

    @Test func otherPhasesIgnoreTheStripCounts() {
        let a = M.size(for: .prompt, suggestions: 0)
        let b = M.size(for: .prompt, suggestions: 0, running: 9, pinned: 9)
        #expect(a == b)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh -only-testing:Context-DockTests/AppChatPromptMetricsDockTests`
Expected: compile failure — `dockLayout` undefined.

- [ ] **Step 3: Implement**

Inside `AppChatPromptMetrics`, after `chatHeight`:

```swift
    // MARK: Dock strip

    static let dockIconSize: CGFloat = 48
    static let dockIconGap: CGFloat = 8
    static let dockInset: CGFloat = 10
    /// gap + hairline + gap between the running section and the pins.
    static let dockDividerSpan: CGFloat = 17
    static let dockHeight: CGFloat = 68
    /// Wider than the field, never wider than the corner can hold.
    static var dockMaximumWidth: CGFloat { width * 1.6 }

    struct DockLayout: Equatable {
        /// Running icons actually drawn; the rest are the `+N` pill.
        let shownRunning: Int
        let overflow: Int
        let width: CGFloat
    }

    private static func runWidth(_ count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * dockIconSize + CGFloat(count - 1) * dockIconGap
    }

    /// Pure: counts in, geometry out. Pins are never dropped — the user chose them — so
    /// the running section is what gives way, keeping one slot for the `+N` pill.
    static func dockLayout(running: Int, pinned: Int) -> DockLayout {
        let pinsWidth = pinned > 0 ? dockDividerSpan + runWidth(pinned) : 0
        let available = dockMaximumWidth - 2 * dockInset - pinsWidth
        // How many running icons fit in what is left, at least one slot.
        let capacity = max(1, Int((available + dockIconGap) / (dockIconSize + dockIconGap)))
        let shownRunning: Int
        let overflow: Int
        if running <= capacity {
            shownRunning = running
            overflow = 0
        } else {
            shownRunning = max(0, capacity - 1)  // one slot for +N
            overflow = running - shownRunning
        }
        let runningSlots = shownRunning + (overflow > 0 ? 1 : 0)
        let width = 2 * dockInset + runWidth(max(1, runningSlots)) + pinsWidth
        return DockLayout(shownRunning: shownRunning, overflow: overflow, width: width)
    }
```

Extend `size(for:)`:

```swift
    static func size(
        for phase: AppChatPromptPhase,
        suggestions: Int,
        messages: Int = 0,
        hasApproval: Bool = false,
        attachments: Int = 0,
        hasSelectionRow: Bool = false,
        running: Int = 0,
        pinned: Int = 0
    ) -> CGSize {
        let sheet = sheetHeight(
            hasApproval: hasApproval, attachments: attachments, hasSelectionRow: hasSelectionRow)
        switch phase {
        case .hidden, .mini:
            return miniSize
        case .dock:
            return CGSize(
                width: dockLayout(running: running, pinned: pinned).width, height: dockHeight)
        case .prompt, .suggesting:
            return CGSize(width: width, height: inputHeight + sheet)
        case .chat:
            return CGSize(width: width, height: chatHeight(messages: messages) + sheet)
        }
    }
```

In `CornerDockController.promptSize` (`CornerDockWindow.swift` ~L372) pass the counts:

```swift
        return AppChatPromptMetrics.size(
            for: prompt.phase,
            suggestions: prompt.listRowCount,
            messages: prompt.messages.count,
            hasApproval: ApprovalCenter.shared.pending(for: .corner) != nil,
            attachments: prompt.attachments.count,
            running: prompt.stripIcons.count,
            pinned: 0)   // DockPinStore.shared.pins.count once Task 4 lands
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh -only-testing:Context-DockTests/AppChatPromptMetricsDockTests`
Expected: 8 tests pass, named.

- [ ] **Step 5: Build**

Run: `./scripts/dev-run.sh` — builds.

- [ ] **Step 6: Commit**

```bash
git add Context-Dock/UI/AppChatPromptPill.swift Context-Dock/UI/CornerDockWindow.swift Context-DockTests/AppChatPromptMetricsDockTests.swift
git commit -m "feat(corner): dock strip geometry as a pure metrics function

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: The General setting

**Files:**
- Modify: `Context-Dock/App/AppSettings.swift` (near L891 `showMenuBarIcon`)
- Modify: `Context-Dock/UI/LegacySettingsContent.swift:212-` (`launcherPanel`, "Smart Features" card)

**Interfaces:**
- Produces: `AppSettings.autoShrinkInputField: Bool` (`@AppStorage("autoShrinkInputField")`, default `true`) — the same key Task 1's default closure reads.

- [ ] **Step 1: Add the storage**

In `AppSettings`, next to `showMenuBarIcon`:

```swift
    /// The corner's Global field folds into the dock strip after a second untouched.
    @AppStorage("autoShrinkInputField") var autoShrinkInputField: Bool = true
```

- [ ] **Step 2: Add the row**

In `launcherPanel`, inside the `"Smart Features"` `CardSection`'s `VStack`, after the last `SettingsRow`:

```swift
                    SettingsDivider()
                    SettingsRow {
                        GeneralToggleLabel("Auto-shrink the search field",
                            caption: "After 1 second with nothing typed, the corner's search "
                                + "field folds into the dock strip. Typing brings it back.")
                        Toggle("", isOn: $settings.autoShrinkInputField).labelsHidden()
                    }
```

- [ ] **Step 3: Build and check by hand**

Run: `./scripts/dev-run.sh`. Open Settings → General → Launcher. The row is there, defaults on. Toggle off, summon the corner in Global: it must fold to `.mini` after 5 s as before. Toggle on: it folds after 1 s.

- [ ] **Step 4: Commit**

```bash
git add Context-Dock/App/AppSettings.swift Context-Dock/UI/LegacySettingsContent.swift
git commit -m "feat(settings): auto-shrink toggle for the corner's search field

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: `DockPinStore` and the pin mapping

**Files:**
- Create: `Context-Dock/Services/DockPinStore.swift`
- Modify: `Context-Dock/Services/GlobalSearchService.swift` (after `documents(forBundleId:limit:)` ~L218)
- Modify: `Context-Dock/UI/CornerDockWindow.swift` (`promptSize`, replace `pinned: 0`)
- Test: `Context-DockTests/DockPinStoreTests.swift`

**Interfaces:**
- Consumes: `ContextDockStore.shared.write(_:to:)`, `read(_:from:)`, `ContextDockStore.root`, `GlobalSearchService.SearchDocument`, `.ActionSpec`, `AppChatRow`, `DockPill.rankingKind / sourceBundleId / name`.
- Produces:
  ```swift
  enum DockPinKind: Codable, Equatable, Hashable {
      case app(bundleID: String)
      case globalCommand(id: String)
      case cliTool(name: String)
      case file(path: String)
      case folder(path: String)
  }
  struct DockPin: Codable, Identifiable, Equatable {
      let id: UUID; let kind: DockPinKind; var title: String; var order: Int
      /// GlobalSearchService document id for commands and tools, so a click can run the
      /// real document; nil for apps, files, folders.
      var documentID: String?
  }
  @MainActor final class DockPinStore: ObservableObject {
      static let shared: DockPinStore
      init(fileURL: URL)
      @Published private(set) var pins: [DockPin]
      func isPinned(_ kind: DockPinKind) -> Bool
      @discardableResult func pin(_ kind: DockPinKind, title: String, documentID: String? = nil) -> DockPin?
      func unpin(_ id: UUID)
      func move(from: Int, to: Int)
  }
  extension DockPinKind {
      init?(document: GlobalSearchService.SearchDocument)
      init?(row: AppChatRow)
      init?(fileURL: URL)
  }
  // GlobalSearchService
  nonisolated func document(withID id: String) -> SearchDocument?
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// Context-DockTests/DockPinStoreTests.swift
import AppKit
import Foundation
import Testing
@testable import Context_Dock

@MainActor
struct DockPinStoreTests {
    private func temporaryStore() -> (DockPinStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dock-pins-\(UUID().uuidString).json")
        return (DockPinStore(fileURL: url), url)
    }

    private func document(action: GlobalSearchService.ActionSpec, id: String = "doc",
                          filePath: String? = nil) -> GlobalSearchService.SearchDocument {
        GlobalSearchService.SearchDocument(
            id: id, title: "T", subtitle: "", bundleId: "", filePath: filePath,
            normalizedTitle: "t", titleWords: ["t"], acronym: "t", aliases: [], aliasWords: [],
            sourceKind: .installed, rankingBoost: 0, icon: nil, usageTrackingKey: id,
            action: action)
    }

    @Test func pinsPersistInOrderAndDedupeOnKind() {
        let (store, url) = temporaryStore()
        store.pin(.app(bundleID: "com.apple.Safari"), title: "Safari")
        store.pin(.folder(path: "/Users/x/Documents"), title: "Documents")
        #expect(store.pin(.app(bundleID: "com.apple.Safari"), title: "Safari") == nil)
        #expect(store.pins.count == 2)
        #expect(store.pins.map(\.order) == [0, 1])
        ContextDockStore.shared.flushNow()
        let reloaded = DockPinStore(fileURL: url)
        #expect(reloaded.pins.map(\.kind) == store.pins.map(\.kind))
    }

    @Test func moveRenumbersOrder() {
        let (store, _) = temporaryStore()
        store.pin(.app(bundleID: "a"), title: "A")
        store.pin(.app(bundleID: "b"), title: "B")
        store.pin(.app(bundleID: "c"), title: "C")
        store.move(from: 2, to: 0)
        #expect(store.pins.map(\.title) == ["C", "A", "B"])
        #expect(store.pins.map(\.order) == [0, 1, 2])
    }

    @Test func unpinOfAMissingIDIsANoOp() {
        let (store, _) = temporaryStore()
        store.pin(.app(bundleID: "a"), title: "A")
        store.unpin(UUID())
        #expect(store.pins.count == 1)
    }

    @Test func documentsMapToKinds() {
        #expect(DockPinKind(document: document(action: .launchBundleId("com.x", path: "/Applications/X.app")))
            == .app(bundleID: "com.x"))
        #expect(DockPinKind(document: document(action: .activatePID(1, bundleId: "com.y", path: nil)))
            == .app(bundleID: "com.y"))
        #expect(DockPinKind(document: document(action: .cliScope(command: "gh", displayName: "GitHub CLI")))
            == .cliTool(name: "gh"))
        #expect(DockPinKind(document: document(action: .systemCommandScope(commandKey: "lock")))
            == .globalCommand(id: "system:lock"))
        let ext = UUID()
        #expect(DockPinKind(document: document(action: .userExtension(id: ext)))
            == .globalCommand(id: "user:\(ext.uuidString)"))
        #expect(DockPinKind(document: document(action: .adapterAction(bundleId: "com.x", appName: "X", actionId: "a1")))
            == .globalCommand(id: "adapter:com.x:a1"))
        #expect(DockPinKind(document: document(action: .cachedMenu(
            bundleId: "com.x", appName: "X", path: ["File", "New"], shortcutChar: nil, shortcutModifiers: 0))) == nil)
        #expect(DockPinKind(document: document(action: .browserURL(
            url: URL(string: "https://a.b")!, browserBundleId: "com.apple.Safari",
            browserName: "Safari", kind: "tab", domain: "a.b"))) == nil)
    }

    @Test func fileURLsSplitOnDirectory() {
        let dir = FileManager.default.temporaryDirectory
        let file = dir.appendingPathComponent("pin-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        #expect(DockPinKind(fileURL: dir) == .folder(path: dir.path))
        #expect(DockPinKind(fileURL: file) == .file(path: file.path))
        #expect(DockPinKind(fileURL: file.appendingPathComponent("missing")) == nil)
    }

    @Test func rowsMapThroughTheSameRule() {
        #expect(DockPinKind(row: .file(FileManager.default.temporaryDirectory))
            == .folder(path: FileManager.default.temporaryDirectory.path))
        var pill = DockPill(id: "app", name: "X", icon: "app", badge: nil, execute: {})
        pill.rankingKind = "appLaunch"
        pill.sourceBundleId = "com.x"
        #expect(DockPinKind(row: .dock(pill)) == .app(bundleID: "com.x"))
        #expect(DockPinKind(row: .cliSuggestion("status")) == nil)
    }
}
```

`SearchDocument`'s memberwise init may not be reachable if it has extra `let`s with defaults — `learnedBoost` has a default, so the memberwise init takes it as optional; the call above omits it, which is allowed.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh -only-testing:Context-DockTests/DockPinStoreTests`
Expected: compile failure — `DockPinStore` undefined.

- [ ] **Step 3: Implement the store**

```swift
// Context-Dock/Services/DockPinStore.swift
import AppKit
import Foundation

/// What a pinned icon on the corner's dock strip stands for. Apps, files and folders are
/// self-describing; commands and tools name a `GlobalSearchService` document by id so a
/// click runs the real thing through the same path the list uses.
enum DockPinKind: Codable, Equatable, Hashable {
    case app(bundleID: String)
    case globalCommand(id: String)
    case cliTool(name: String)
    case file(path: String)
    case folder(path: String)
}

struct DockPin: Codable, Identifiable, Equatable {
    let id: UUID
    let kind: DockPinKind
    var title: String
    var order: Int
    var documentID: String?
}

@MainActor
final class DockPinStore: ObservableObject {
    static let shared = DockPinStore(
        fileURL: ContextDockStore.root.appendingPathComponent("dock-pins.json"))

    @Published private(set) var pins: [DockPin] = []
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        pins = (ContextDockStore.shared.read([DockPin].self, from: fileURL) ?? [])
            .sorted { $0.order < $1.order }
    }

    func isPinned(_ kind: DockPinKind) -> Bool { pins.contains { $0.kind == kind } }

    @discardableResult
    func pin(_ kind: DockPinKind, title: String, documentID: String? = nil) -> DockPin? {
        guard !isPinned(kind) else { return nil }
        let pin = DockPin(
            id: UUID(), kind: kind, title: title, order: pins.count, documentID: documentID)
        pins.append(pin)
        persist()
        return pin
    }

    func unpin(_ id: UUID) {
        guard let index = pins.firstIndex(where: { $0.id == id }) else { return }
        pins.remove(at: index)
        renumber()
        persist()
    }

    func move(from source: Int, to destination: Int) {
        guard pins.indices.contains(source), (0...pins.count).contains(destination),
            source != destination
        else { return }
        let pin = pins.remove(at: source)
        pins.insert(pin, at: destination > source ? destination - 1 : destination)
        renumber()
        persist()
    }

    private func renumber() {
        for index in pins.indices { pins[index].order = index }
    }

    private func persist() {
        ContextDockStore.shared.write(pins, to: fileURL)
    }
}

// MARK: - Mapping

extension DockPinKind {
    /// One rule for the context menu and the drop handler, so they agree on what can be
    /// pinned. Menus and browser tabs cannot: a menu item lives in one app's state, a tab
    /// is a moment.
    init?(document: GlobalSearchService.SearchDocument) {
        switch document.action {
        case .launchBundleId(let bundleID, _):
            self = .app(bundleID: bundleID)
        case .activatePID(_, let bundleID, _):
            self = .app(bundleID: bundleID)
        case .launchPath(let path):
            if path.hasSuffix(".app"), let bundleID = Bundle(path: path)?.bundleIdentifier {
                self = .app(bundleID: bundleID)
            } else if let kind = DockPinKind(fileURL: URL(fileURLWithPath: path)) {
                self = kind
            } else {
                return nil
            }
        case .cliScope(let command, _):
            self = .cliTool(name: command)
        case .systemCommandScope(let key):
            self = .globalCommand(id: "system:\(key)")
        case .userExtension(let id):
            self = .globalCommand(id: "user:\(id.uuidString)")
        case .adapterAction(let bundleID, _, let actionID):
            self = .globalCommand(id: "adapter:\(bundleID):\(actionID)")
        case .cachedMenu, .browserURL:
            return nil
        }
    }

    init?(fileURL: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
        else { return nil }
        self = isDirectory.boolValue ? .folder(path: fileURL.path) : .file(path: fileURL.path)
    }

    init?(row: AppChatRow) {
        switch row {
        case .global(let doc):
            self.init(document: doc)
        case .file(let url):
            self.init(fileURL: url)
        case .dock(let pill) where pill.rankingKind == "appLaunch" && !pill.sourceBundleId.isEmpty:
            self = .app(bundleID: pill.sourceBundleId)
        case .dock, .command, .action, .cliSuggestion:
            return nil
        }
    }

    /// The icon at draw time — never persisted, because apps update theirs.
    var icon: NSImage? {
        switch self {
        case .app(let bundleID):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        case .file(let path), .folder(let path):
            return FileManager.default.fileExists(atPath: path)
                ? NSWorkspace.shared.icon(forFile: path) : nil
        case .globalCommand, .cliTool:
            return nil  // the strip asks the document for its icon
        }
    }

    /// Whether what this stands for is still there.
    var isAvailable: Bool {
        switch self {
        case .app(let bundleID):
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        case .file(let path), .folder(let path):
            return FileManager.default.fileExists(atPath: path)
        case .globalCommand, .cliTool:
            return true  // the strip checks the document instead
        }
    }
}
```

In `GlobalSearchService`, after `documents(forBundleId:limit:)`:

```swift
    /// One document by its id — for a pinned command or tool, which stores the id rather
    /// than the document so it survives an index rebuild.
    nonisolated func document(withID id: String) -> SearchDocument? {
        lock.lock()
        defer { lock.unlock() }
        return documents.first { $0.id == id }
    }
```

In `CornerDockController.promptSize`, replace `pinned: 0` with `pinned: DockPinStore.shared.pins.count`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh -only-testing:Context-DockTests/DockPinStoreTests`
Expected: 6 tests pass, named. If `pinsPersistInOrderAndDedupeOnKind` fails on reload because the debounced write has not hit disk, `flushNow()` is the fix — confirm it is public; if not, make it so.

- [ ] **Step 5: Build and commit**

```bash
./scripts/dev-run.sh
git add Context-Dock/Services/DockPinStore.swift Context-Dock/Services/GlobalSearchService.swift Context-Dock/UI/CornerDockWindow.swift Context-DockTests/DockPinStoreTests.swift
git commit -m "feat(corner): DockPinStore — pinnable apps, commands, tools, files, folders

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: The strip and the morph

**Files:**
- Create: `Context-Dock/UI/CornerDockStrip.swift`
- Modify: `Context-Dock/UI/AppChatPromptPill.swift:101-150` (`body`)

**Interfaces:**
- Consumes: `AppChatPromptModel.phase / stripIcons / globalOverflowCount / hoveredStripBundleID / hideRunningApp / expandFromDock / run(_:) / scopeIntoApp(name:bundleID:)`, `DockPinStore.shared`, `DockPinKind.icon / isAvailable`, `GlobalSearchService.shared.document(withID:)`, `AppChatPromptMetrics.dock*`, `MatchDockIcon`.
- Produces: `struct CornerDockStrip: View { init(model: AppChatPromptModel) }`.

- [ ] **Step 1: Write the strip**

```swift
// Context-Dock/UI/CornerDockStrip.swift
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Global Context at rest: the running apps and the pins, at Dock size. It offers places
/// to go and never answers anything — typing is what brings the field back.
struct CornerDockStrip: View {
    @ObservedObject var model: AppChatPromptModel
    @ObservedObject private var pins = DockPinStore.shared
    @State private var hoveredID: String?
    @State private var isDropTarget = false

    private typealias M = AppChatPromptMetrics

    private var layout: M.DockLayout {
        M.dockLayout(running: model.stripIcons.count, pinned: pins.pins.count)
    }

    var body: some View {
        HStack(spacing: M.dockIconGap) {
            ForEach(Array(model.stripIcons.prefix(layout.shownRunning))) { icon in
                runningIcon(icon)
            }
            if layout.overflow > 0 {
                overflowPill(layout.overflow)
            }
            if !pins.pins.isEmpty {
                Rectangle()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 1, height: M.dockIconSize * 0.7)
                    .padding(.horizontal, (M.dockDividerSpan - 1) / 2 - M.dockIconGap / 2)
                ForEach(pins.pins) { pin in
                    pinnedIcon(pin)
                }
            }
        }
        .padding(.horizontal, M.dockInset)
        .frame(height: M.dockHeight)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            acceptDrop(providers)
        }
        .overlay {
            if isDropTarget {
                Capsule().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dock")
    }

    // MARK: Icons

    private func runningIcon(_ icon: MatchDockIcon) -> some View {
        DockStripIcon(
            image: icon.icon, title: icon.title, isRunning: icon.isRunning,
            isAvailable: true, scale: scale(for: icon.id))
        .onHover { inside in
            hoveredID = inside ? icon.id : (hoveredID == icon.id ? nil : hoveredID)
            model.hoveredStripBundleID = inside ? icon.bundleID : nil
        }
        .onTapGesture { activate(bundleID: icon.bundleID) }
        .contextMenu {
            if let bundleID = icon.bundleID {
                Button("Ask about \(icon.title)") {
                    model.expandFromDock(seeding: nil)
                    model.scopeIntoApp(name: icon.title, bundleID: bundleID)
                }
                Divider()
                if !pins.isPinned(.app(bundleID: bundleID)) {
                    Button("Pin to Dock") {
                        pins.pin(.app(bundleID: bundleID), title: icon.title)
                    }
                }
                Button("Remove from Strip") { model.hideRunningApp(bundleID) }
                Divider()
                Button("Quit \(icon.title)") {
                    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                        .forEach { $0.terminate() }
                }
            }
        }
        .accessibilityLabel(icon.title)
        .accessibilityAddTraits(.isButton)
    }

    private func pinnedIcon(_ pin: DockPin) -> some View {
        let document = pin.documentID.flatMap { GlobalSearchService.shared.document(withID: $0) }
        let image = pin.kind.icon ?? document?.icon
        let available: Bool = {
            switch pin.kind {
            case .globalCommand, .cliTool: return document != nil
            default: return pin.kind.isAvailable
            }
        }()
        let running: Bool = {
            if case .app(let bundleID) = pin.kind {
                return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
            }
            return false
        }()
        return DockStripIcon(
            image: image, title: pin.title, isRunning: running,
            isAvailable: available, scale: scale(for: pin.id.uuidString))
        .onHover { inside in
            hoveredID = inside ? pin.id.uuidString : (hoveredID == pin.id.uuidString ? nil : hoveredID)
            if case .app(let bundleID) = pin.kind {
                model.hoveredStripBundleID = inside ? bundleID : nil
            }
        }
        .onTapGesture { open(pin, document: document) }
        .onDrag {
            NSItemProvider(object: "dockpin:\(pin.id.uuidString)" as NSString)
        }
        .contextMenu {
            Button("Unpin") { pins.unpin(pin.id) }
            switch pin.kind {
            case .file(let path), .folder(let path):
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            default:
                EmptyView()
            }
        }
        .accessibilityLabel(pin.title)
        .accessibilityAddTraits(.isButton)
    }

    private func overflowPill(_ count: Int) -> some View {
        Text("+\(count)")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: M.dockIconSize, height: M.dockIconSize)
            .background(Color.primary.opacity(0.08), in: Circle())
            .onTapGesture { model.expandFromDock(seeding: nil) }
            .accessibilityLabel("\(count) more running apps")
    }

    /// Dock magnify: the hovered icon up, its neighbours a little, everything else at rest.
    private func scale(for id: String) -> CGFloat {
        guard let hoveredID else { return 1 }
        if hoveredID == id { return 1.25 }
        let ids = model.stripIcons.prefix(layout.shownRunning).map(\.id)
            + pins.pins.map(\.id.uuidString)
        guard let a = ids.firstIndex(of: hoveredID), let b = ids.firstIndex(of: id) else { return 1 }
        return abs(a - b) == 1 ? 1.1 : 1
    }

    // MARK: Actions

    private func activate(bundleID: String?) {
        guard let bundleID,
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return }
        app.activate()
    }

    private func open(_ pin: DockPin, document: GlobalSearchService.SearchDocument?) {
        switch pin.kind {
        case .app(let bundleID):
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                running.activate()
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
        case .file(let path), .folder(let path):
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
            }
        case .globalCommand, .cliTool:
            guard let document else { return }
            // Commands and tools run through the list's own path so a CLI scopes the field
            // and a system command opens its scope, exactly as choosing the row would.
            model.expandFromDock(seeding: nil)
            model.run(.global(document))
        }
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil),
                    let kind = DockPinKind(fileURL: url)
                else { return }
                Task { @MainActor in
                    DockPinStore.shared.pin(kind, title: url.lastPathComponent)
                }
            }
            accepted = true
        }
        return accepted
    }
}

/// One icon in the strip. The running dot sits under it, the way the Dock's does; an icon
/// whose target is gone draws dim rather than vanishing, so the user can unpin it.
struct DockStripIcon: View {
    let image: NSImage?
    let title: String
    let isRunning: Bool
    let isAvailable: Bool
    let scale: CGFloat

    var body: some View {
        VStack(spacing: 2) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .aspectRatio(contentMode: .fit)
            .frame(width: AppChatPromptMetrics.dockIconSize - 8,
                   height: AppChatPromptMetrics.dockIconSize - 8)
            .opacity(isAvailable ? 1 : 0.4)
            .scaleEffect(scale, anchor: .bottom)
            .animation(.snappy(duration: 0.18), value: scale)
            Circle()
                .fill(Color.primary.opacity(isRunning ? 0.6 : 0))
                .frame(width: 4, height: 4)
        }
        .frame(width: AppChatPromptMetrics.dockIconSize, height: AppChatPromptMetrics.dockIconSize)
        .contentShape(Rectangle())
        .help(title)
    }
}
```

`NSWorkspace.openApplication(at:configuration:)` takes `NSWorkspace.OpenConfiguration()`; if `.init()` is ambiguous, spell it out.

- [ ] **Step 2: Mount it in the pill with the morph**

Replace `AppChatPromptPill.body` (~L101-140). Keep the existing cross-fade for every non-Global scope; only Global gets the container, because only Global docks:

```swift
    @Namespace private var glassNamespace

    var body: some View {
        Group {
            if model.isGlobalScope {
                globalBody
            } else {
                legacyBody
            }
        }
        .onHover { pointerInside = $0 }
        .onAppear { syncFocus() }
        .onChange(of: keyboardState.owner) { _, _ in syncFocus() }
        .onChange(of: keyboardState.focusRequestToken) { _, _ in syncFocus() }
        .onReceive(NotificationCenter.default.publisher(for: .minimizedPanelsChanged)) { _ in
            model.updateGlobalTyping(for: model.query)
        }
    }

    /// Global Context: field and strip are two glass shapes in one container, so the
    /// field folds into the strip and buds back out of it — SwiftUI's own morph, keyed on
    /// the ids. Reduced motion gets a crossfade instead.
    private var globalBody: some View {
        GlassEffectContainer(spacing: 24) {
            ZStack(alignment: .bottomLeading) {
                if model.phase.showsInput {
                    inputStack
                        .frame(width: AppChatPromptMetrics.width, alignment: .bottomLeading)
                        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
                        .glassEffectID("field", in: glassNamespace)
                        .transition(reduceMotion ? .opacity : .identity)
                }
                if model.phase == .dock {
                    CornerDockStrip(model: model)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .glassEffectID("dock", in: glassNamespace)
                        .transition(reduceMotion ? .opacity : .identity)
                }
                if model.phase == .mini {
                    miniContent
                        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
                        .glassEffectID("field", in: glassNamespace)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .bottomLeading)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.45), value: model.phase)
        .shadow(color: .black.opacity(0.34), radius: 20, y: 10)
    }

    /// Everything that is not Global keeps the shell it had.
    private var legacyBody: some View {
        ZStack(alignment: .bottomLeading) {
            inputStack
                .frame(width: AppChatPromptMetrics.width, alignment: .bottomLeading)
                .opacity(model.phase.showsInput ? 1 : 0)
                .allowsHitTesting(model.phase.showsInput)
                .animation(.easeOut(duration: 0.11), value: model.phase)

            miniContent
                .opacity(model.phase == .mini ? 1 : 0)
                .allowsHitTesting(model.phase == .mini)
                .animation(.easeIn(duration: 0.16).delay(0.06), value: model.phase)
        }
        .frame(width: size.width, height: size.height, alignment: .bottomLeading)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.clear)
                .background(GlassBackground(cornerRadius: 22, isDark: true))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.34), radius: 20, y: 10)
        }
    }
```

Add `@Environment(\.accessibilityReduceMotion) private var reduceMotion` to the struct. `size` is the existing computed property; make sure it now passes `running: model.stripIcons.count, pinned: DockPinStore.shared.pins.count` into `AppChatPromptMetrics.size(for:…)` — find where `size` is computed in the pill and add the two arguments.

The `.mini` branch in `globalBody` is reachable only with the setting off; it reuses the `"field"` id so the old fold still animates.

- [ ] **Step 3: Build and check by hand**

Run: `./scripts/dev-run.sh`. Summon the corner in Global. Check, in this order:
1. After 1 s untouched, the field folds into a capsule of 48 pt icons — running apps, running dots, a `+N` pill if many.
2. Hover: icons magnify; neighbours a little.
3. Click a running icon: that app comes forward. Right-click: Ask about / Pin to Dock / Remove from Strip / Quit.
4. Pin one: the divider and the pinned section appear; the strip widens; the width matches `dockLayout` (no clipped icon, no empty margin).
5. Drop a Finder file onto the strip: it appears as a pin. Right-click → Unpin removes it.
6. Setting off (Settings → General): the old 52 × 44 mini fold still works in Global.
7. Toggle "Reduce motion" in System Settings → Accessibility: fold is a crossfade.

If the morph shows the field and strip crossfading rather than merging, the two shapes are not in the same container at transition time — the most likely cause is a `.frame` between the container and the `ZStack`; move the frame outside the container as written above.

- [ ] **Step 4: Commit**

```bash
git add Context-Dock/UI/CornerDockStrip.swift Context-Dock/UI/AppChatPromptPill.swift
git commit -m "feat(corner): the dock strip, and the field morphs into it

Two glass shapes in one GlassEffectContainer: the Global field folds
into the strip after a second and buds back out on the first typed
character. Icons at Dock size, magnify on hover, pins after a divider.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Keys on the dock

**Files:**
- Modify: `Context-Dock/UI/CornerDockWindow.swift:571-` (`handleChatNavigationKey`)

**Interfaces:**
- Consumes: `prompt.phase`, `prompt.expandFromDock(seeding:)`, `prompt.arrowRightFromDock()`, `prompt.dismiss()`, `chatPresentation.handleRightArrow(draft:)`, `handleLeftArrow(draft:)`, `chatPresentation.mode`, `requestComposerFocus()`.

- [ ] **Step 1: Add the dock branch at the top of `handleChatNavigationKey`, after the command-tap lines**

```swift
        // The dock has no field, so nothing below can answer for it. Printable characters
        // bring the field back with the character in it; every other key keeps doing what
        // it does on an empty Global field — → steps into the first running app, ← walks
        // back, Esc leaves. Nothing else has a field to act on and passes through.
        if let panel, event.window === panel,
            chatPresentation.isVisible, chatPresentation.mode != .general,
            prompt.phase == .dock,
            event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        {
            switch event.keyCode {
            case 53:  // Esc
                prompt.dismiss()
                return nil
            case 124:  // →
                if prompt.arrowRightFromDock() { return nil }
                return chatPresentation.handleRightArrow(draft: "") ? nil : event
            case 123:  // ←
                return chatPresentation.handleLeftArrow(draft: "") ? nil : event
            case 125, 126, 48, 36, 76, 51, 117:  // ↓ ↑ Tab Return Enter Backspace Delete
                return event
            default:
                guard let text = event.characters, !text.isEmpty,
                    text.unicodeScalars.allSatisfy({
                        !CharacterSet.controlCharacters.contains($0)
                            && !CharacterSet.newlines.contains($0)
                    })
                else { return event }
                prompt.expandFromDock(seeding: text)
                requestComposerFocus()
                return nil
            }
        }
```

Check the signature of `handleRightArrow` / `handleLeftArrow` in `CornerChatPresentation` — both are called with `draft: model.query` in the pill; here the draft is `""` because the dock has no query.

- [ ] **Step 2: Build and check by hand**

Run: `./scripts/dev-run.sh`. In Global, let it dock, then:
1. Type `s` → the field buds out with `s` in it and the caret after it; results for `s` show.
2. Dock again. Press → : same thing as → on the empty field before this work (steps into the first running app's scope). Press ← from there: back to Global.
3. Dock again. Esc → corner gone. ↑ ↓ Tab Return → nothing happens, no expand.
4. ⌘-tap still switches scope as before (the command-tap code above this branch is untouched).
5. With the Clipboard card holding the keyboard, typing does not expand the dock (`chatPresentation.isVisible` gate plus `mode`; if it does, add `!ClipboardPanelController.shared.model.isKeyboardArmed` to the guard, matching the ← branch below it).

- [ ] **Step 3: Commit**

```bash
git add Context-Dock/UI/CornerDockWindow.swift
git commit -m "feat(corner): typing on the dock brings the field back; arrows keep their empty-field meaning

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Window row on hover

**Files:**
- Modify: `Context-Dock/Services/AppWindowSnapshotService.swift`
- Create: `Context-Dock/UI/CornerWindowRow.swift`
- Modify: `Context-Dock/UI/CornerDockWindow.swift` (`currentSlots` list slot ~L322, the mount in the surface `VStack` ~L790, `showsAppChatList`)
- Test: `Context-DockTests/WindowSnapshotFilterTests.swift`

**Interfaces:**
- Consumes: `SCShareableContent`, `SCScreenshotManager`, `AppChatPromptModel.hoveredStripBundleID`, `AppChatListMetrics.size(rows:)`, `CornerDockLayout.slots(... list: ...)`.
- Produces:
  ```swift
  struct WindowCandidate: Equatable { let id: CGWindowID; let bundleID: String?; let title: String; let frame: CGRect; let isOnScreen: Bool; let layer: Int }
  struct WindowSnapshot: Identifiable, Equatable { let id: CGWindowID; let title: String; let image: NSImage? }
  extension AppWindowSnapshotService {
      static let windowRowLimit = 6
      static func eligibleWindows(_ all: [WindowCandidate], bundleID: String, limit: Int = windowRowLimit) -> [WindowCandidate]
      func windowSnapshots(for bundleID: String) -> [WindowSnapshot]
      func refreshWindows(bundleID: String)
  }
  enum CornerWindowRowMetrics { static let thumb = CGSize(width: 160, height: 100); static func size(count: Int) -> CGSize }
  struct CornerWindowRow: View { init(bundleID: String, hoveredIndex: Int, model: AppChatPromptModel) }
  ```

- [ ] **Step 1: Write the failing filter tests**

```swift
// Context-DockTests/WindowSnapshotFilterTests.swift
import Foundation
import Testing
@testable import Context_Dock

struct WindowSnapshotFilterTests {
    private func window(_ id: CGWindowID, bundle: String? = "com.x", title: String = "W",
                        w: CGFloat = 800, h: CGFloat = 600, onScreen: Bool = true, layer: Int = 0)
        -> WindowCandidate
    {
        WindowCandidate(id: id, bundleID: bundle, title: title,
                        frame: CGRect(x: 0, y: 0, width: w, height: h), isOnScreen: onScreen, layer: layer)
    }

    @Test func keepsOnlyThisAppsOnScreenNormalWindows() {
        let all = [
            window(1), window(2, bundle: "com.y"), window(3, onScreen: false),
            window(4, layer: 25), window(5, w: 40, h: 40), window(6, title: ""),
        ]
        #expect(AppWindowSnapshotService.eligibleWindows(all, bundleID: "com.x").map(\.id) == [1, 6])
    }

    @Test func keepsFrontToBackOrderAndCapsAtTheLimit() {
        let all = (1...10).map { window(CGWindowID($0)) }
        let kept = AppWindowSnapshotService.eligibleWindows(all, bundleID: "com.x")
        #expect(kept.map(\.id) == [1, 2, 3, 4, 5, 6])
    }

    @Test func rowSizeGrowsWithThumbnails() {
        let one = CornerWindowRowMetrics.size(count: 1)
        let three = CornerWindowRowMetrics.size(count: 3)
        #expect(one.height == three.height)
        #expect(three.width == one.width + 2 * (160 + 8))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh -only-testing:Context-DockTests/WindowSnapshotFilterTests`
Expected: compile failure.

- [ ] **Step 3: Extend the service**

Append to `AppWindowSnapshotService.swift`:

```swift
/// What the window filter needs from an `SCWindow`, as a value so the rule can be tested
/// without ScreenCaptureKit in the room.
struct WindowCandidate: Equatable {
    let id: CGWindowID
    let bundleID: String?
    let title: String
    let frame: CGRect
    let isOnScreen: Bool
    let layer: Int
}

struct WindowSnapshot: Identifiable, Equatable {
    let id: CGWindowID
    let title: String
    let image: NSImage?
}

extension AppWindowSnapshotService {
    static let windowRowLimit = 6

    /// This app's ordinary windows, front to back, at most `limit`. Layer 0 is a normal
    /// window; palettes, tooltips and menus sit above it. The size floor drops the
    /// one-line palettes that pass as layer 0.
    static func eligibleWindows(
        _ all: [WindowCandidate], bundleID: String, limit: Int = windowRowLimit
    ) -> [WindowCandidate] {
        Array(
            all.filter {
                $0.bundleID == bundleID && $0.isOnScreen && $0.layer == 0
                    && $0.frame.width > 80 && $0.frame.height > 80
            }
            .prefix(limit))
    }

    func windowSnapshots(for bundleID: String) -> [WindowSnapshot] {
        windowSets[bundleID] ?? []
    }

    /// Every eligible window of one app, captured one by one. The 2 s freshness rule is
    /// the single-window path's; walking the strip must not capture continuously.
    func refreshWindows(bundleID: String) {
        guard !bundleID.isEmpty, !windowsInFlight.contains(bundleID) else { return }
        if let last = windowsCaptured[bundleID],
            Date().timeIntervalSince(last) < Self.freshness
        {
            return
        }
        windowsInFlight.insert(bundleID)
        Task { [weak self] in
            let set = await Self.captureWindows(bundleID: bundleID)
            guard let self else { return }
            self.windowsInFlight.remove(bundleID)
            guard let set else { return }
            self.windowsCaptured[bundleID] = Date()
            self.isDenied = false
            self.windowSets[bundleID] = set
        }
    }

    private static func captureWindows(bundleID: String) async -> [WindowSnapshot]? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true)
            let candidates = content.windows.map {
                WindowCandidate(
                    id: $0.windowID, bundleID: $0.owningApplication?.bundleIdentifier,
                    title: $0.title ?? "", frame: $0.frame, isOnScreen: $0.isOnScreen,
                    layer: $0.windowLayer)
            }
            let wanted = Set(eligibleWindows(candidates, bundleID: bundleID).map(\.id))
            var result: [WindowSnapshot] = []
            for window in content.windows where wanted.contains(window.windowID) {
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                // A 160-point thumbnail: a quarter-size capture is already more than it shows.
                config.width = max(Int(window.frame.width / 4), 1)
                config.height = max(Int(window.frame.height / 4), 1)
                config.showsCursor = false
                let image = try? await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config)
                result.append(WindowSnapshot(
                    id: window.windowID, title: window.title ?? "",
                    image: image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }))
            }
            return result
        } catch {
            await MainActor.run { AppWindowSnapshotService.shared.isDenied = true }
            return nil
        }
    }
}
```

Add to the class body (stored properties cannot live in an extension):

```swift
    @Published private(set) var windowSets: [String: [WindowSnapshot]] = [:]
    fileprivate var windowsInFlight: Set<String> = []
    fileprivate var windowsCaptured: [String: Date] = [:]
```

and change `private static let freshness` to `fileprivate static let freshness`.

- [ ] **Step 4: Write the row**

```swift
// Context-Dock/UI/CornerWindowRow.swift
import AppKit
import ApplicationServices
import SwiftUI

enum CornerWindowRowMetrics {
    static let thumb = CGSize(width: 160, height: 100)
    static let gap: CGFloat = 8
    static let inset: CGFloat = 12
    static let titleHeight: CGFloat = 16
    /// Pure: count in, size out. The row is a corner slot and hit-tested by this number.
    static func size(count: Int) -> CGSize {
        let n = CGFloat(max(1, count))
        return CGSize(
            width: 2 * inset + n * thumb.width + (n - 1) * gap,
            height: 2 * inset + thumb.height + 4 + titleHeight)
    }
}

/// The hovered app's windows, one thumbnail each — the Dock's Exposé, at strip size. A
/// click raises that window. With Screen Recording refused the titles still show, so the
/// row says what is open rather than showing nothing and looking broken.
struct CornerWindowRow: View {
    let bundleID: String
    @ObservedObject var model: AppChatPromptModel
    @ObservedObject private var snapshots = AppWindowSnapshotService.shared

    private typealias M = CornerWindowRowMetrics

    var body: some View {
        let windows = snapshots.windowSnapshots(for: bundleID)
        HStack(spacing: M.gap) {
            if windows.isEmpty {
                placeholder
            }
            ForEach(windows) { window in
                VStack(spacing: 4) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                        if let image = window.image {
                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            Image(systemName: "macwindow")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: M.thumb.width, height: M.thumb.height)
                    Text(window.title.isEmpty ? "Untitled" : window.title)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .frame(width: M.thumb.width, height: M.titleHeight)
                }
                .contentShape(Rectangle())
                .onTapGesture { raise(window) }
                .accessibilityLabel(window.title)
                .accessibilityAddTraits(.isButton)
            }
        }
        .padding(M.inset)
        .frame(width: M.size(count: windows.count).width, height: M.size(count: windows.count).height)
        .onHover { inside in model.windowRowHovered(inside) }
        .onAppear { snapshots.refreshWindows(bundleID: bundleID) }
        .onChange(of: bundleID) { _, next in snapshots.refreshWindows(bundleID: next) }
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: snapshots.isDenied ? "eye.slash" : "macwindow")
                .font(.system(size: 24)).foregroundStyle(.secondary)
            Text(snapshots.isDenied ? "Allow Screen Recording to see windows" : "No windows")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(width: M.thumb.width, height: M.thumb.height + 4 + M.titleHeight)
    }

    /// Raise by window id through AX: the app's window elements carry `_AXWindowNumber`,
    /// which is the CGWindowID ScreenCaptureKit reports.
    private func raise(_ window: WindowSnapshot) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
            let windows = value as? [AXUIElement]
        {
            for element in windows {
                var number: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, "_AXWindowNumber" as CFString, &number) == .success,
                    let n = number as? Int, CGWindowID(n) == window.id
                {
                    AXUIElementPerformAction(element, kAXRaiseAction as CFString)
                    break
                }
            }
        }
        app.activate()
        model.dismiss()
    }
}
```

- [ ] **Step 5: The hover timing and the slot**

In `AppChatPromptModel`, next to `hoveredStripBundleID`:

```swift
    /// Which app the window row is showing, once the pointer has rested long enough. The
    /// strip sets `hoveredStripBundleID` on every icon; this follows it after 250 ms and
    /// lets go 150 ms after the pointer has left both the icon and the row.
    @Published private(set) var windowRowBundleID: String?
    private var windowRowTask: Task<Void, Never>?
    private var pointerInWindowRow = false

    func windowRowHovered(_ inside: Bool) {
        pointerInWindowRow = inside
        if !inside { scheduleWindowRowUpdate() }
        else { windowRowTask?.cancel() }
    }

    private func scheduleWindowRowUpdate() {
        windowRowTask?.cancel()
        let target = hoveredStripBundleID
        let delay: TimeInterval = target == nil ? 0.15 : 0.25
        windowRowTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if target == nil, self.pointerInWindowRow { return }
            self.windowRowBundleID = target
        }
    }
```

and give `hoveredStripBundleID` a `didSet { scheduleWindowRowUpdate() }`. In `dismiss()`, add `windowRowBundleID = nil; windowRowTask?.cancel()`.

In `CornerDockController`:

```swift
    /// The window row takes the list's slot: both sit directly above the field, and a
    /// docked pill has no list. Reusing the slot keeps the layout arithmetic in one place.
    var showsWindowRow: Bool {
        chatPresentation.isVisible && chatPresentation.mode != .general
            && prompt.phase == .dock && prompt.windowRowBundleID != nil
    }
```

In `currentSlots()` (and `dormantShelfRect()`), the `list:` argument becomes:

```swift
            list: showsAppChatList
                ? AppChatListMetrics.size(rows: prompt.listRowCount)
                : (showsWindowRow
                    ? CornerWindowRowMetrics.size(
                        count: max(1, AppWindowSnapshotService.shared
                            .windowSnapshots(for: prompt.windowRowBundleID ?? "").count))
                    : nil),
```

Where the surface `VStack` mounts the list card (find `AppChatListCard(` in `CornerDockWindow.swift`), add beside it:

```swift
                if CornerDockController.shared.showsWindowRow,
                    let bundleID = prompt.windowRowBundleID
                {
                    CornerWindowRow(bundleID: bundleID, model: prompt)
                        .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
```

The row is placed over the field's slot rather than over the hovered icon — the slot system anchors above the prompt, and a second anchor is not worth its own layout path. Noted as a deviation from the spec's "anchored over the hovered icon".

- [ ] **Step 6: Run the tests, build, check by hand**

Run: `./scripts/test.sh -only-testing:Context-DockTests/WindowSnapshotFilterTests` — 3 pass, named.
Run: `./scripts/dev-run.sh`. Dock the corner, rest on a running icon with two windows open: after ~¼ s the row appears above the strip with two thumbnails and titles. Move to the next icon: row follows. Move off both: gone after ~150 ms. Click a thumbnail: that window comes up, corner closes. Revoke Screen Recording for the app in System Settings: the row shows titles with the eye-slash placeholder, and no prompt appears on hover.

- [ ] **Step 7: Commit**

```bash
git add Context-Dock/Services/AppWindowSnapshotService.swift Context-Dock/UI/CornerWindowRow.swift Context-Dock/UI/CornerDockWindow.swift Context-Dock/UI/AppChatPromptModel.swift Context-DockTests/WindowSnapshotFilterTests.swift
git commit -m "feat(corner): hovering a strip icon shows that app's windows

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: Pin from a result row; drag out and reorder

**Files:**
- Modify: `Context-Dock/UI/AppChatListCard.swift:122-140` (row `ForEach`)
- Modify: `Context-Dock/UI/CornerDockStrip.swift` (drop of the internal payload, drag-out)

**Interfaces:**
- Consumes: `DockPinKind(row:)`, `DockPinStore.shared.pin/unpin/move/isPinned`, `AppChatRow`, `GlobalSearchService.SearchDocument.title/id`.

- [ ] **Step 1: Context menu on every row**

In `AppChatListCard`, wrap the `Group { switch row … }` so each row gets the menu:

```swift
                                Group {
                                    switch row { /* unchanged */ }
                                }
                                .contextMenu { pinMenu(for: row) }
                                .id(row.id)
```

and add:

```swift
    /// "Pin to dock" on any row that stands for something pinnable; nothing on the rest.
    /// One rule (`DockPinKind(row:)`) decides, the same one the strip's drop uses.
    @ViewBuilder
    private func pinMenu(for row: AppChatRow) -> some View {
        if let kind = DockPinKind(row: row) {
            if DockPinStore.shared.isPinned(kind) {
                Button("Unpin from Dock") {
                    if let pin = DockPinStore.shared.pins.first(where: { $0.kind == kind }) {
                        DockPinStore.shared.unpin(pin.id)
                    }
                }
            } else {
                Button("Pin to Dock") {
                    let (title, documentID): (String, String?) = {
                        switch row {
                        case .global(let doc): return (doc.title, doc.id)
                        case .file(let url): return (url.lastPathComponent, nil)
                        case .dock(let pill): return (pill.name, nil)
                        default: return ("", nil)
                        }
                    }()
                    DockPinStore.shared.pin(kind, title: title, documentID: documentID)
                }
            }
        }
    }
```

- [ ] **Step 2: Drag out to unpin, drag within to reorder**

In `CornerDockStrip`, extend `onDrop` to accept the internal payload and reorder, and track drag-out. Replace the `.onDrop` modifier with:

```swift
        .onDrop(of: [.fileURL, .plainText], isTargeted: $isDropTarget) { providers in
            acceptDrop(providers)
        }
```

and in `acceptDrop`, before the file loop:

```swift
        for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let text = object as? String, text.hasPrefix("dockpin:"),
                    let id = UUID(uuidString: String(text.dropFirst("dockpin:".count)))
                else { return }
                Task { @MainActor in
                    let store = DockPinStore.shared
                    guard let from = store.pins.firstIndex(where: { $0.id == id }) else { return }
                    // Dropped back on the strip: move to the end of the pins. Per-slot
                    // targets are a refinement the user has not asked for.
                    store.move(from: from, to: store.pins.count)
                }
            }
            accepted = true
        }
```

Drag-out: SwiftUI's `onDrag` cannot see where a drag ended. Track it with a drag-session flag: in `pinnedIcon`, replace `.onDrag { … }` with

```swift
        .onDrag {
            draggingPinID = pin.id
            return NSItemProvider(object: "dockpin:\(pin.id.uuidString)" as NSString)
        }
```

add `@State private var draggingPinID: UUID?`, and on the strip's root:

```swift
        .onChange(of: isDropTarget) { _, inside in
            // The pointer carried a pin off the strip and let go elsewhere: unpin. A drop
            // back on the strip clears `draggingPinID` in acceptDrop before this fires.
            if !inside, let id = draggingPinID {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if draggingPinID == id, NSEvent.pressedMouseButtons == 0 {
                        DockPinStore.shared.unpin(id)
                        draggingPinID = nil
                    }
                }
            }
        }
```

and set `draggingPinID = nil` at the top of `acceptDrop`.

This is the part a synthetic drag cannot prove (memory `synthetic-drags-do-not-start-real-drag-sessions`); it is checked by hand in Step 3. If the 300 ms heuristic misfires (unpins on a drag that returned to the strip), replace it with an AppKit `NSDraggingSource` on the icon, as `MultiItemDragSource` does for the clipboard — that is the fallback, not the first cut.

- [ ] **Step 3: Build and check by hand**

Run: `./scripts/dev-run.sh`.
1. Type `saf` in Global, right-click the Safari row → Pin to Dock. Dock: Safari is in the pinned section with its dot. Right-click the row again → Unpin from Dock.
2. Type a system command's name, right-click → Pin to Dock. Click the pinned icon: the field returns and the command's scope opens, same as choosing the row.
3. Right-click a menu-item row: no pin item.
4. Drag a pinned icon out and release on the desktop: it is gone. Drag it out and back onto the strip: it stays (moved to the end).

- [ ] **Step 4: Commit**

```bash
git add Context-Dock/UI/AppChatListCard.swift Context-Dock/UI/CornerDockStrip.swift
git commit -m "feat(corner): pin from any result row; drag a pin off the strip to unpin

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 9: Whole suite, graph, hand checks, brain

**Files:** none new.

- [ ] **Step 1: Full suite**

Run: `pkill -f "Context-Dock.app/Contents/MacOS/Context-Dock"; ./scripts/test.sh`
Expected: `TEST SUCCEEDED`; the count is the previous total (1126) + 29 new, minus nothing; the one pre-existing failure (`PriorityAdapterContractTests/priorityTypedCapabilitiesDeclareTheExpectedRisk`) is still the only failure. Confirm the four new suites by name in the output.

- [ ] **Step 2: Graph**

Run: `graphify update .`

- [ ] **Step 3: Manual checklist, recorded on brain issue #24 as a comment**

- Fold after 1 s in Global; never in a scoped chat, General, CLI, or mid-conversation.
- The morph reads as one shape folding, not two crossfading; reduced motion crossfades.
- Magnify, `+N`, divider, pins, dim state for a missing file (move a pinned file to the Trash and look).
- Window row: timing, titles, click raises, Screen Recording refused.
- Keys: printable expands with seed; → ← Esc as on the empty field; ↑ ↓ Tab Return inert.
- Setting off: HEAD behaviour.
- Light and dark, left / centre / right anchor.

- [ ] **Step 4: Brain**

`update_issue(24, status: done)` once the checklist is clean, `add_comment` with anything that had to deviate from the spec (the window row's slot is one), and rewrite the status doc.

---

## Self-review

**Spec coverage.** §1 state machine → Task 1 (+ Task 6 for keys). §2 shell/morph/metrics/magnify/window row → Tasks 2, 5, 7. §3 pins store, mapping, entry points, hidden running set, window snapshots → Tasks 4, 5, 7, 8. §4 setting → Task 3; failure states → Task 5 (`isAvailable` dim, missing-file reveal) and Task 7 (denied placeholder); tests → Tasks 1, 2, 4, 7; manual list → Task 9. Out-of-scope items untouched. One deliberate deviation: the window row uses the list slot (centred over the field) instead of anchoring over the hovered icon — called out in Task 7 and Task 9.

**Placeholders.** None: every step carries its code or its exact command.

**Type consistency.** `expandFromDock(seeding:)`, `arrowRightFromDock()`, `stripIcons`, `hiddenRunningBundleIDs`, `hoveredStripBundleID`, `windowRowBundleID`, `windowRowHovered(_:)` — defined in Tasks 1/7, used in 5/6/7. `dockLayout(running:pinned:)` / `DockLayout` — Task 2, used in 5. `DockPinStore.pin(_:title:documentID:)` returns `DockPin?` — Task 4, used in 5/8. `document(withID:)` — Task 4, used in 5. `eligibleWindows` / `windowSnapshots(for:)` / `refreshWindows(bundleID:)` — Task 7 only. `CornerWindowRowMetrics.size(count:)` — Task 7 test and controller.
