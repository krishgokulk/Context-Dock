# Corner Dual-Chat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the single corner chat reliably focusable and hotkey-switchable between complete Frontmost App Chat and complete General Chat, with screenshot-style slash-app chips above the bottom composer.

**Architecture:** Add a presentation-only `CornerChatPresentation` that cycles modes while leaving `AppChatPromptModel` and `GeneralChatWindowModel.shared` as separate state and execution owners. Render both inside the existing `CornerDockPanel`; reuse the shared General Chat model, message cards, approval inbox, provider settings, and app directory rather than cloning any pipeline.

**Tech Stack:** Swift 5, SwiftUI, AppKit `NSPanel`, Combine, swift-testing, Xcode macOS target.

**Spec:** `docs/superpowers/specs/2026-08-31-corner-dual-chat-design.md`

## Global Constraints

- Preserve one fixed `CornerDockPanel`; do not create another floating chat window.
- Keep Frontmost App Chat and General Chat as separate modes, scopes, drafts, histories, and execution owners.
- Use `GeneralChatWindowModel.shared` for every General Chat send, attachment, approval, progress update, and session mutation.
- Keep the composer at the bottom in both modes.
- `/` matches come from `ChatAppDirectory` and render as horizontal glass icon-and-name chips above the composer.
- A repeated corner hotkey cycles hidden -> Frontmost App Chat -> General Chat -> Frontmost App Chat.
- Never stage, reset, stash, overwrite, or commit unrelated Developer Inspector or adapter-contract work.
- After every code edit run `./scripts/dev-run.sh`; use `./scripts/test.sh` only after stopping the running debug app.
- Run `graphify update .` after code changes and `git diff --check` before each completion claim.

---

### Task 1: Presentation-only mode cycle

**Files:**
- Create: `Context-Dock/UI/CornerChatPresentation.swift`
- Modify: `Context-Dock/UI/CornerDockWindow.swift:53-70`
- Test: `Context-DockTests/CornerChatPresentationTests.swift`

**Interfaces:**
- Consumes: `AppChatPromptModel.phase`, `AppChatPromptModel.summon(app:bundleID:suggestions:summary:)`, `GeneralChatWindowModel.shared.reloadFromStore()`.
- Produces: `enum CornerChatMode { case frontmostApp, general }`; `CornerChatPresentation.shared`; `mode`; `isVisible`; `cycle(target:)`; `showFrontmostApp(target:)`; `dismiss()`.

- [ ] **Step 1: Write failing cycle and state-isolation tests**

```swift
import AppKit
import Testing
@testable import Context_Dock

@MainActor
struct CornerChatPresentationTests {
    @Test func hotkeyCyclesAppGeneralApp() {
        let app = AppChatPromptModel(conversation: AppChatConversation())
        let general = GeneralChatWindowModel()
        let subject = CornerChatPresentation(appChat: app, generalChat: general)
        let target = CornerChatTarget(name: "Code", bundleID: "com.microsoft.VSCode")

        subject.cycle(target: target)
        #expect(subject.mode == .frontmostApp)
        #expect(subject.isVisible)
        subject.cycle(target: target)
        #expect(subject.mode == .general)
        subject.cycle(target: target)
        #expect(subject.mode == .frontmostApp)
    }

    @Test func switchingModesKeepsIndependentDrafts() {
        let app = AppChatPromptModel(conversation: AppChatConversation())
        let general = GeneralChatWindowModel()
        let subject = CornerChatPresentation(appChat: app, generalChat: general)
        let target = CornerChatTarget(name: "Safari", bundleID: "com.apple.Safari")

        subject.cycle(target: target)
        app.query = "app draft"
        subject.cycle(target: target)
        general.input = "general draft"
        subject.cycle(target: target)

        #expect(app.query == "app draft")
        #expect(general.input == "general draft")
    }
}
```

- [ ] **Step 2: Run the focused tests and verify the missing types fail**

Run:

```bash
./scripts/test.sh -only-testing:Context-DockTests/CornerChatPresentationTests
```

Expected: compilation fails because `CornerChatPresentation`, `CornerChatMode`, and `CornerChatTarget` do not exist.

- [ ] **Step 3: Implement the presentation coordinator**

```swift
@MainActor
final class CornerChatPresentation: ObservableObject {
    static let shared = CornerChatPresentation()

    @Published private(set) var mode: CornerChatMode = .frontmostApp
    @Published private(set) var isVisible = false

    let appChat: AppChatPromptModel
    let generalChat: GeneralChatWindowModel

    init(
        appChat: AppChatPromptModel = AppChatPromptModel(),
        generalChat: GeneralChatWindowModel = .shared
    ) {
        self.appChat = appChat
        self.generalChat = generalChat
    }

    func cycle(target: CornerChatTarget) {
        if !isVisible {
            showFrontmostApp(target: target)
        } else if mode == .frontmostApp {
            mode = .general
            generalChat.reloadFromStore()
        } else {
            showFrontmostApp(target: target)
        }
    }

    func showFrontmostApp(target: CornerChatTarget) {
        mode = .frontmostApp
        isVisible = true
        appChat.summon(
            app: target.name,
            bundleID: target.bundleID,
            suggestions: target.suggestions,
            summary: target.summary)
    }

    func dismiss() {
        isVisible = false
        appChat.dismiss()
    }
}
```

Define `CornerChatTarget` with `name`, `bundleID`, `suggestions`, and `summary`, plus a convenience initializer used by tests. Make `GeneralChatWindowModel.init()` internal while retaining `.shared`, matching the existing `AppChatConversation` test seam.

- [ ] **Step 4: Build/relaunch and rerun the focused tests**

Run `./scripts/dev-run.sh`, stop that exact debug app, then rerun the Task 1 test command. Expected: all `CornerChatPresentationTests` pass.

- [ ] **Step 5: Commit only Task 1 files**

```bash
git add Context-Dock/UI/CornerChatPresentation.swift Context-Dock/UI/CornerDockWindow.swift Context-Dock/AI/GeneralChatWindowModel.swift Context-DockTests/CornerChatPresentationTests.swift
git commit -m "feat(chat): add corner mode cycle"
```

---

### Task 2: Reliable first-click keyboard activation

**Files:**
- Modify: `Context-Dock/UI/CornerDockWindow.swift:16-45,73-103,242-255`
- Modify: `Context-Dock/UI/AppChatPromptPill.swift:42-115`
- Test: `Context-DockTests/CornerDockKeyboardTests.swift`

**Interfaces:**
- Consumes: `CornerDockController.armKeyboard()`, `disarmKeyboard()`, current `CornerDockHostView.interactiveRects`.
- Produces: `CornerDockKeyboardState`; `CornerDockController.requestComposerFocus()`; `focusRequestToken`; `onComposerInteraction` callback used by both chat composers.

- [ ] **Step 1: Write failing keyboard-state tests**

```swift
@MainActor
struct CornerDockKeyboardTests {
    @Test func clickingComposerArmsKeyboardAndRequestsFocus() {
        let state = CornerDockKeyboardState()
        state.composerInteracted()
        #expect(state.isArmed)
        #expect(state.focusRequestToken == 1)
    }

    @Test func idleShrinkRestoresAmbientPanelState() {
        let state = CornerDockKeyboardState()
        state.composerInteracted()
        state.stoodDown()
        #expect(!state.isArmed)
    }
}
```

- [ ] **Step 2: Run the focused test and verify it fails for the missing state**

Run `./scripts/test.sh -only-testing:Context-DockTests/CornerDockKeyboardTests`.

- [ ] **Step 3: Implement a testable keyboard state and one controller path**

```swift
@MainActor
final class CornerDockKeyboardState: ObservableObject {
    @Published private(set) var isArmed = false
    @Published private(set) var focusRequestToken = 0

    func composerInteracted() {
        isArmed = true
        focusRequestToken &+= 1
    }

    func stoodDown() { isArmed = false }
}
```

`requestComposerFocus()` must refresh layout/interactive rectangles, call `armKeyboard()`, increment the token, and then schedule `panel.makeFirstResponder(panel.contentView)` on the next main-queue turn. App Chat's `TextField` observes the token with `@FocusState` and invokes `requestComposerFocus()` from a simultaneous mouse gesture so the first click is not discarded.

- [ ] **Step 4: Restore nonactivation only on real stand-down/dismissal**

Wire `AppChatPromptModel`/presentation phase changes so `.mini` and `.hidden` call `disarmKeyboard()`. Do not disarm merely because the mode changes; transfer focus to the new composer instead.

- [ ] **Step 5: Build/relaunch and verify focused tests**

Run `./scripts/dev-run.sh`, stop the app, then run:

```bash
./scripts/test.sh -only-testing:Context-DockTests/CornerDockKeyboardTests -only-testing:Context-DockTests/AppChatPromptTests
```

Expected: keyboard tests and existing App Chat tests pass.

- [ ] **Step 6: Commit only Task 2 files**

```bash
git add Context-Dock/UI/CornerDockWindow.swift Context-Dock/UI/AppChatPromptPill.swift Context-DockTests/CornerDockKeyboardTests.swift
git commit -m "fix(chat): focus corner composer on click"
```

---

### Task 3: Shared slash-app matching and screenshot-style chips

**Files:**
- Create: `Context-Dock/UI/ChatSlashAppPicker.swift`
- Modify: `Context-Dock/Search/ExtensionPanelWindow.swift:511-660`
- Test: `Context-DockTests/ChatSlashAppPickerTests.swift`

**Interfaces:**
- Consumes: `ChatAppDirectory.matching(_:)`, `ChatAppEntry`.
- Produces: `ChatSlashAppPicker.matches(for:) -> [ChatAppEntry]`; `ChatSlashAppChipStrip`; shared `pickLeadingMatch(text:onPick:) -> Bool`.

- [ ] **Step 1: Write failing slash parsing tests**

```swift
struct ChatSlashAppPickerTests {
    @Test func slashMessageAndTerminalReturnDirectoryMatches() {
        #expect(ChatSlashAppPicker.matches(for: "/message").first?.name == "Messages")
        #expect(ChatSlashAppPicker.matches(for: "/terminal").first?.name == "Terminal")
    }

    @Test func spaceEndsAppFiltering() {
        #expect(ChatSlashAppPicker.matches(for: "/terminal run tests").isEmpty)
    }

    @Test func plainTextDoesNotFilterApps() {
        #expect(ChatSlashAppPicker.matches(for: "terminal").isEmpty)
    }
}
```

- [ ] **Step 2: Run the focused test and verify the picker is missing**

Run `./scripts/test.sh -only-testing:Context-DockTests/ChatSlashAppPickerTests`.

- [ ] **Step 3: Extract matching logic from `AIComposerBar`**

```swift
enum ChatSlashAppPicker {
    static func matches(for text: String) -> [ChatAppEntry] {
        guard text.hasPrefix("/") else { return [] }
        let filter = String(text.dropFirst())
        guard !filter.contains(" ") else { return [] }
        return ChatAppDirectory.matching(filter.lowercased())
    }
}
```

Change the existing `AIComposerBar` to call this helper so full General Chat and corner General Chat cannot drift.

- [ ] **Step 4: Build the horizontal chip strip**

`ChatSlashAppChipStrip` renders a horizontal `ScrollView` above the composer. Every chip contains the real app icon, app name, and a green running indicator. The leading match uses an accent outline/fill; other chips use the shared glass/elevated material. Selecting a chip calls `GeneralChatWindowModel.attachApp(entry.name)` and clears `model.input`. Do not show an `All` chip because this strip is a scope picker, not a result filter.

- [ ] **Step 5: Build/relaunch and rerun slash tests**

Run `./scripts/dev-run.sh`, stop the app, then run the Task 3 test command. Expected: all slash picker tests pass and existing `AIComposerBar` compiles.

- [ ] **Step 6: Commit only Task 3 files**

```bash
git add Context-Dock/UI/ChatSlashAppPicker.swift Context-Dock/Search/ExtensionPanelWindow.swift Context-DockTests/ChatSlashAppPickerTests.swift
git commit -m "feat(chat): add slash app chip strip"
```

---

### Task 4: Complete corner General Chat presentation

**Files:**
- Create: `Context-Dock/UI/CornerGeneralChatView.swift`
- Modify: `Context-Dock/UI/CornerDockLayout.swift:14-64`
- Modify: `Context-Dock/UI/CornerDockWindow.swift:190-239,325-370`
- Modify: `Context-Dock/UI/AppChatPromptPill.swift` only if extracting shared compact controls is required
- Test: `Context-DockTests/CornerGeneralChatTests.swift`

**Interfaces:**
- Consumes: `GeneralChatWindowModel.shared`, `AIComposerBar`, `ChatSlashAppChipStrip`, `AIChatMessageView`, `ApprovalCenter.shared`, `GeneralChatWindowController.shared.show()`.
- Produces: `CornerGeneralChatView`; `CornerGeneralChatMetrics`; `CornerGeneralChatSnapshot` for deterministic state tests.

- [ ] **Step 1: Write failing shared-model snapshot tests**

```swift
@MainActor
struct CornerGeneralChatTests {
    @Test func snapshotUsesTheSharedModelsLiveState() {
        let model = GeneralChatWindowModel()
        model.input = "/terminal"
        model.attachments = [URL(fileURLWithPath: "/tmp/log.txt")]
        let snapshot = CornerGeneralChatSnapshot(model: model)

        #expect(snapshot.draft == "/terminal")
        #expect(snapshot.attachmentNames == ["log.txt"])
        #expect(snapshot.slashApps.first?.name == "Terminal")
    }

    @Test func pickingSlashAppScopesWithoutSendingText() {
        let model = GeneralChatWindowModel()
        model.input = "/message"
        let sent = CornerGeneralChatSnapshot.pickLeadingSlashApp(in: model)
        #expect(sent)
        #expect(model.input.isEmpty)
        #expect(model.scopeAppNames.contains("Messages"))
        #expect(model.messages.isEmpty)
    }
}
```

- [ ] **Step 2: Run the focused tests and verify the missing snapshot fails**

Run `./scripts/test.sh -only-testing:Context-DockTests/CornerGeneralChatTests`.

- [ ] **Step 3: Implement the compact transcript and live progress**

Render `model.messages` with `AIChatMessageView`; feed the active message `model.activeProgress` or `model.activeStatus` while `model.isSending`. Preserve scroll-to-bottom behavior and render the existing structured rows rather than flattening messages into strings.

- [ ] **Step 4: Implement complete compact composer behaviour**

Use `AIComposerBar` bound directly to `$model.input`. Wire `onSubmit` so a leading slash match is attached first; otherwise call `model.send()`. Wire file/image attachments, pasted images, provider menu, attached-app removal, clear thread, cancel while sending, and an overflow attach menu for folder, screenshot, area capture, and captured text.

- [ ] **Step 5: Add shared approvals and large-surface handoff**

Render `ApprovalCard` for `ApprovalCenter.shared.pending(for: .chatWindow)`. For terminal console, artifact preview, thread sidebar, or content that exceeds compact presentation, show `Open in General Chat`; it calls the existing window controller after persisting/reloading the same active session. Never instantiate another `GeneralChatWindowModel` in production.

- [ ] **Step 6: Match corner geometry and lifecycle**

Keep a 720-point maximum card height within the fixed host, pin the composer to the bottom, show slash chips immediately above it, and make transcript/suggestions the only scrolling region. General mode uses the same corner glass, radius, trailing expand button, pin button, hover, and idle-shrink rules as App mode.

- [ ] **Step 7: Build/relaunch and rerun focused tests**

Run `./scripts/dev-run.sh`, stop the app, then run:

```bash
./scripts/test.sh -only-testing:Context-DockTests/CornerGeneralChatTests -only-testing:Context-DockTests/ChatSlashAppPickerTests
```

- [ ] **Step 8: Commit only Task 4 files**

```bash
git add Context-Dock/UI/CornerGeneralChatView.swift Context-Dock/UI/CornerDockLayout.swift Context-Dock/UI/CornerDockWindow.swift Context-DockTests/CornerGeneralChatTests.swift
git commit -m "feat(chat): render general chat in corner"
```

---

### Task 5: Hotkey integration and frontmost-app correctness

**Files:**
- Modify: `Context-Dock/App/ILauncherApp.swift:1780-1832`
- Modify: `Context-Dock/UI/CornerDockWindow.swift:108-158`
- Modify: `Context-Dock/UI/CornerChatPresentation.swift`
- Test: `Context-DockTests/CornerChatPresentationTests.swift`

**Interfaces:**
- Consumes: `AppDelegate.menuBarOwningUserFacingApplication()`, `NSWorkspace.frontmostApplication`, `ContextDockEnvironment.frontmostAppUpdates`, `AppChatSuggestionProvider`.
- Produces: `AppDelegate.cycleCornerChat()` and `CornerChatPresentation.frontmostAppDidChange(target:)`.

- [ ] **Step 1: Add failing frontmost-update and duplicate-cycle tests**

```swift
@Test func generalModeIgnoresFrontmostChangesUntilReturningToApp() {
    let subject = makePresentation()
    subject.cycle(target: code)
    subject.cycle(target: code)
    subject.frontmostAppDidChange(target: safari)
    #expect(subject.mode == .general)
    subject.cycle(target: safari)
    #expect(subject.appChat.appBundleID == "com.apple.Safari")
}

@Test func duplicateHotkeyDoesNotDoubleCycle() {
    let gate = CornerChatHotkeyGate(minimumInterval: 0.15)
    #expect(gate.accept(at: 10.0))
    #expect(!gate.accept(at: 10.1))
    #expect(gate.accept(at: 10.2))
}
```

- [ ] **Step 2: Run focused tests and verify the new APIs fail**

Run `./scripts/test.sh -only-testing:Context-DockTests/CornerChatPresentationTests`.

- [ ] **Step 3: Replace direct App Chat summon with mode cycling**

Capture the user-facing target before activating Context-Dock. Use `menuBarOwningUserFacingApplication()` when Context-Dock is already frontmost from a prior corner click. Build one `CornerChatTarget`, call `CornerDockController.activate()`, and then call `CornerChatPresentation.shared.cycle(target:)`.

- [ ] **Step 4: Restrict live frontmost retargeting to App mode**

Store the latest valid target while General mode is visible but do not mutate General Chat. When cycling back to App mode, summon/retarget with that latest target and its current suggestions.

- [ ] **Step 5: Build/relaunch and run all corner tests**

Run `./scripts/dev-run.sh`, stop the app, then run:

```bash
./scripts/test.sh -only-testing:Context-DockTests/CornerChatPresentationTests -only-testing:Context-DockTests/CornerDockKeyboardTests -only-testing:Context-DockTests/CornerGeneralChatTests -only-testing:Context-DockTests/AppChatPromptTests -only-testing:Context-DockTests/AppChatControlsTests
```

- [ ] **Step 6: Commit only Task 5 files**

```bash
git add Context-Dock/App/ILauncherApp.swift Context-Dock/UI/CornerDockWindow.swift Context-Dock/UI/CornerChatPresentation.swift Context-DockTests/CornerChatPresentationTests.swift
git commit -m "feat(chat): cycle corner chat hotkey"
```

---

### Task 6: Full verification and manual acceptance

**Files:**
- Modify only files required by defects exposed in this task.
- Update: `graphify-out/` through `graphify update .`.

**Interfaces:**
- Consumes: completed Tasks 1-5.
- Produces: verified debug app for user acceptance; no feature commit until manual confirmation for any final repair batch.

- [ ] **Step 1: Check the entire scoped diff**

Run `git diff --check`, inspect `git status --short`, and compare every staged path against Tasks 1-5. Preserve all unrelated dirty files.

- [ ] **Step 2: Run the full offline suite**

Stop the debug app, then run `./scripts/test.sh`. Expected: all new corner tests pass. If the known baseline `PriorityAdapterContractTests.priorityTypedCapabilitiesDeclareTheExpectedRisk()` still fails, record it separately and confirm no new failures.

- [ ] **Step 3: Refresh the graph**

Run `graphify update .`. Do not run LLM labeling.

- [ ] **Step 4: Build and relaunch the exact debug product**

Run `./scripts/dev-run.sh`. Expected: `BUILD SUCCEEDED` and the launched path is `.build/XcodeDerivedData/Build/Products/Debug/Context-Dock.app`.

- [ ] **Step 5: Perform manual acceptance**

Verify:

1. First click types into App mode immediately.
2. Hotkey cycles App -> General -> App without a second window.
3. App and General drafts/history stay independent.
4. `/message` and `/terminal` show icon-and-name chips above the composer; Return scopes the app without sending slash text.
5. General Chat provider switching, files, images, app scope, streaming, structured results, approvals, and clear/cancel work.
6. Full General Chat shows the same thread once, including a pending or completed corner turn.
7. Frontmost app and Space changes affect only App mode.
8. Hover, pin, active-answer protection, and idle shrink work in both modes.

- [ ] **Step 6: Hand off for user verification**

Report focused/full test counts, the exact build result, the known unrelated baseline failure if present, and the eight manual checks. Wait for the user's confirmation before committing any final repair batch.
