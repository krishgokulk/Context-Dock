# Corner AI Chat Functional Stabilization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Frontmost App AI and General AI reliable inside one right-corner assistant surface before undertaking the final visual redesign.

**Architecture:** `CornerChatPresentation` becomes the sole owner of visible, compact, expanded, mini, and hidden presentation state. Existing Frontmost App Chat and General Chat models remain the independent authorities for their conversations and execution; a shared SwiftUI shell renders mode-specific content, activity, approvals, and a bottom composer without creating another chat engine.

**Tech Stack:** Swift 5, SwiftUI, AppKit `NSPanel`, Combine, swift-testing, Xcode project targeting macOS 26.1.

**Spec:** `docs/superpowers/specs/2026-09-03-corner-ai-chat-shell-design.md`

## Global Constraints

- Preserve the architecture boundary: Context Dock Chat Mode is not General Chat Mode.
- Use one corner shell and one presentation state owner; do not introduce another floating panel or conversation store.
- Frontmost App AI must continue using the existing dock execution pipeline and `AppChatConversation.shared`.
- General AI must continue using `GeneralChatWindowModel.shared` and its existing session stores.
- Expose operational status/tool events, never private model chain-of-thought.
- Keep the current visual language except for layout changes needed to prevent clipping or blocked interaction.
- After every source edit, run `./scripts/dev-run.sh`; never launch a separately built app.
- Run the offline suite with `./scripts/test.sh` after stopping the exact worktree Debug app.
- Stage and commit only paths owned by the task; do not disturb Developer Inspector work or dirty graph outputs.

---

### Task 1: Make presentation state single-owned

**Files:**
- Modify: `Context-Dock/UI/CornerChatPresentation.swift`
- Modify: `Context-Dock/UI/AppChatPromptModel.swift`
- Modify: `Context-Dock/UI/CornerDockWindow.swift`
- Test: `Context-DockTests/CornerChatPresentationTests.swift`
- Test: `Context-DockTests/AppChatPromptTests.swift`

**Interfaces:**
- Produces: `CornerChatPhase { hidden, compact, expanded, mini }`.
- Produces: `CornerChatPresentation.phase: CornerChatPhase` as the only corner-chat visibility phase.
- Produces: `CornerChatPresentation.isVisible`, derived as `phase != .hidden`.
- Consumes: mode content state from `AppChatPromptModel` and `GeneralChatWindowModel` without allowing either to order out or resize the panel.

- [ ] **Step 1: Add failing single-owner lifecycle tests**

Add tests that express the screenshot failure directly:

```swift
@Test func hiddenNeverContributesAMiniSizedComposer() {
    let subject = makePresentation()
    subject.showFrontmostApp(target: code)
    subject.dismiss()

    #expect(subject.phase == .hidden)
    #expect(!subject.isVisible)
}

@Test func everyModeUsesTheSameStandDownSequence() {
    let subject = makePresentation()
    subject.showFrontmostApp(target: code)
    subject.standDown()
    #expect(subject.phase == .mini)
    subject.standDown()
    #expect(subject.phase == .hidden)

    subject.showGeneral()
    subject.standDown()
    #expect(subject.phase == .mini)
    subject.standDown()
    #expect(subject.phase == .hidden)
}
```

- [ ] **Step 2: Run focused tests and verify failure**

Run: `./scripts/test.sh -only-testing:Context-DockTests/CornerChatPresentationTests`

Expected: FAIL because App Chat and General Chat currently use different phase/visibility owners.

- [ ] **Step 3: Introduce the shared phase and remove duplicate General phase**

Replace `CornerGeneralPhase`, mutable `isVisible`, and mode-specific stand-down branches with:

```swift
enum CornerChatPhase: Equatable {
    case hidden
    case compact
    case expanded
    case mini

    var isVisible: Bool { self != .hidden }
}

@Published private(set) var phase: CornerChatPhase = .hidden
var isVisible: Bool { phase.isVisible }
```

Make `showFrontmostApp`, `showGeneral`, `standDown`, `hoverBegan`, `dismiss`, focus, pin, and generation protection mutate this phase. `AppChatPromptModel` may continue describing whether its content is prompt/suggestions/chat, but its `dismiss()` and timer must no longer independently control the corner panel.

- [ ] **Step 4: Derive panel slots and keyboard arming from the shared phase**

In `CornerDockController.currentSlots()` and `promptSize`, use `chatPresentation.phase`. A hidden phase must return no prompt slot; mini must always use `AppChatPromptMetrics.miniSize`; compact/expanded delegate content sizing to the active mode. Subscribe once to `$phase` for refresh and keyboard arm/disarm.

- [ ] **Step 5: Build/relaunch and run focused tests**

Run: `./scripts/dev-run.sh`

Run: `./scripts/test.sh -only-testing:Context-DockTests/CornerChatPresentationTests`

Expected: build succeeds; lifecycle tests pass; hiding cannot leave a clipped composer in the mini frame.

- [ ] **Step 6: Commit the state-machine repair**

```bash
git add Context-Dock/UI/CornerChatPresentation.swift Context-Dock/UI/AppChatPromptModel.swift Context-Dock/UI/CornerDockWindow.swift Context-DockTests/CornerChatPresentationTests.swift Context-DockTests/AppChatPromptTests.swift
git commit -m "fix(chat): single-own corner presentation state"
```

---

### Task 2: Protect active work and make focus deterministic

**Files:**
- Modify: `Context-Dock/UI/CornerChatPresentation.swift`
- Modify: `Context-Dock/UI/CornerDockKeyboardState.swift`
- Modify: `Context-Dock/UI/CornerDockWindow.swift`
- Test: `Context-DockTests/CornerChatPresentationTests.swift`
- Test: `Context-DockTests/CornerDockKeyboardTests.swift`

**Interfaces:**
- Produces: `CornerChatPresentation.setComposerFocused(_:)` for both modes.
- Produces: `CornerChatPresentation.setPickerPresented(_:)`.
- Produces: `CornerChatPresentation.hasPendingApproval` as an injected/read-only protection input.
- Consumes: `appChat.isAnswering`, `generalChat.isSending`, pointer state, and pin state.

- [ ] **Step 1: Write failing lifecycle-protection tests**

Cover focus, pointer, pin, generation, pending approval, and picker presentation:

```swift
@Test func pendingApprovalAndPickerPreventStandDown() {
    let subject = makePresentation()
    subject.showGeneral()
    subject.setPendingApprovalForTesting(true)
    subject.standDown()
    #expect(subject.phase == .expanded)

    subject.setPendingApprovalForTesting(false)
    subject.setPickerPresented(true)
    subject.standDown()
    #expect(subject.phase == .expanded)
}
```

Use an initializer dependency or internal test hook rather than mutating `ApprovalCenter.shared` globally.

- [ ] **Step 2: Run focused tests and verify failure**

Run: `./scripts/test.sh -only-testing:Context-DockTests/CornerChatPresentationTests`

Expected: FAIL because protection is currently split and does not cover approvals/pickers uniformly.

- [ ] **Step 3: Centralize interaction protection**

Implement one predicate:

```swift
private var preventsStandDown: Bool {
    isPinned || isPointerInside || isComposerFocused || isPickerPresented
        || isGenerating || hasPendingApproval
}
```

All interaction callbacks reset the same dwell timer. Generation or approval completion re-arms the timer instead of immediately hiding.

- [ ] **Step 4: Make the first click focus the active composer**

In `CornerDockController.requestComposerFocus()`, refresh interactive rectangles before removing `.nonactivatingPanel`, activating the app, making the panel key, and incrementing the focus token. On hidden/mini transition, restore `.nonactivatingPanel` and clear keyboard ownership.

- [ ] **Step 5: Build/relaunch and verify focused behavior**

Run: `./scripts/dev-run.sh`

Run: `./scripts/test.sh -only-testing:Context-DockTests/CornerDockKeyboardTests`

Expected: tests pass; the first click focuses either mode and no invisible key panel remains after dismissal.

- [ ] **Step 6: Commit focus and protection behavior**

```bash
git add Context-Dock/UI/CornerChatPresentation.swift Context-Dock/UI/CornerDockKeyboardState.swift Context-Dock/UI/CornerDockWindow.swift Context-DockTests/CornerChatPresentationTests.swift Context-DockTests/CornerDockKeyboardTests.swift
git commit -m "fix(chat): protect active corner interactions"
```

---

### Task 3: Introduce the functional shared shell

**Files:**
- Create: `Context-Dock/UI/CornerChatShell.swift`
- Modify: `Context-Dock/UI/AppChatPromptPill.swift`
- Modify: `Context-Dock/UI/CornerGeneralChatView.swift`
- Modify: `Context-Dock/UI/CornerDockWindow.swift`
- Test: `Context-DockTests/CornerGeneralChatTests.swift`
- Test: `Context-DockTests/CornerDockLayoutTests.swift`

**Interfaces:**
- Produces: `CornerChatShell<Content, Composer, Mini>: View` with one background, clipping boundary, and bottom composer layout.
- Produces: `CornerChatLayoutMetrics.height(contentHeight:composerHeight:maximumHeight:)`.
- Consumes: active `CornerChatPresentation.phase` and mode-specific content/composer closures.

- [ ] **Step 1: Write failing geometry tests**

Add pure metric tests proving compact height, capped expansion, icon-only mini, and reserved composer space:

```swift
@Test func expandedContentAlwaysReservesComposerHeight() {
    let height = CornerChatLayoutMetrics.height(
        contentHeight: 280, composerHeight: 72, maximumHeight: 620)
    #expect(height == 352)
}

@Test func oversizedContentCapsWithoutRemovingComposer() {
    let height = CornerChatLayoutMetrics.height(
        contentHeight: 900, composerHeight: 72, maximumHeight: 620)
    #expect(height == 620)
}
```

- [ ] **Step 2: Run geometry tests and verify failure**

Run: `./scripts/test.sh -only-testing:Context-DockTests/CornerGeneralChatTests`

Expected: FAIL because shared metrics do not exist.

- [ ] **Step 3: Implement the shared shell and pure metrics**

The shell renders exactly one of these mutually exclusive paths:

```swift
switch phase {
case .hidden:
    EmptyView()
case .mini:
    mini()
case .compact, .expanded:
    VStack(spacing: 0) {
        if phase == .expanded { content() }
        composer()
    }
}
```

Apply glass background, clip, outline, shadow, frame, and size animation once in this file. Do not redesign colors or typography in this milestone.

- [ ] **Step 4: Adapt both existing mode views**

Move their outer container/background responsibility into `CornerChatShell`. Keep existing App Chat suggestions/transcript and General Chat transcript/starter logic as mode content. Ensure the composer remains the final bottom element and scrollable content cannot paint below it.

- [ ] **Step 5: Build/relaunch and run layout tests**

Run: `./scripts/dev-run.sh`

Run: `./scripts/test.sh -only-testing:Context-DockTests/CornerDockLayoutTests`

Expected: build succeeds; compact and expanded modes share geometry; mini contains only its icon.

- [ ] **Step 6: Commit the shell**

```bash
git add Context-Dock/UI/CornerChatShell.swift Context-Dock/UI/AppChatPromptPill.swift Context-Dock/UI/CornerGeneralChatView.swift Context-Dock/UI/CornerDockWindow.swift Context-DockTests/CornerGeneralChatTests.swift Context-DockTests/CornerDockLayoutTests.swift
git commit -m "refactor(chat): share the functional corner shell"
```

---

### Task 4: Show live work, approvals, and durable outcomes

**Files:**
- Create: `Context-Dock/UI/CornerChatActivityView.swift`
- Modify: `Context-Dock/UI/AppChatPromptPill.swift`
- Modify: `Context-Dock/UI/CornerGeneralChatView.swift`
- Modify: `Context-Dock/AI/GeneralChatWindowModel.swift`
- Modify: `Context-Dock/Search/AIMessageViews.swift`
- Test: `Context-DockTests/AppChatPromptTests.swift`
- Test: `Context-DockTests/CornerGeneralChatTests.swift`

**Interfaces:**
- Produces: `CornerChatActivitySnapshot(steps: [String], activeStatus: String?, isRunning: Bool)`.
- Produces: shared `CornerChatActivityView` that renders named progress plus an optional active indicator.
- Consumes: `AppChatConversation.shared.liveSteps`, `GeneralChatWindowModel.activeProgress`, `activeStatus`, structured `EnableAppRequest`, route choices, and `ApprovalCenter` requests.

- [ ] **Step 1: Add failing activity-mapping tests**

```swift
@Test func generalProgressIsVisibleWithoutAnAssistantPlaceholder() {
    let snapshot = CornerChatActivitySnapshot(
        steps: ["Understanding your request", "Checking Reminders access"],
        activeStatus: "Waiting for approval",
        isRunning: true)

    #expect(snapshot.visibleRows == [
        "Understanding your request",
        "Checking Reminders access",
        "Waiting for approval"
    ])
}
```

Also verify adjacent duplicate statuses collapse while order is preserved.

- [ ] **Step 2: Run focused tests and verify failure**

Run: `./scripts/test.sh -only-testing:Context-DockTests/CornerGeneralChatTests`

Expected: FAIL because the shared activity snapshot does not exist.

- [ ] **Step 3: Implement shared activity rendering**

Render every available structured step and the current status. A `ProgressView` may accompany the final active row but cannot replace its label. Completed message traces continue through `AIChatMessageView` after the turn ends.

- [ ] **Step 4: Place approvals in the protected content region**

Render both structured app-enable/route cards already carried by `AIChatMessage` and the pending `ApprovalCenter` request in the same scroll-safe region above the composer. Notify `CornerChatPresentation` when an approval becomes pending so stand-down is blocked until it resolves.

- [ ] **Step 5: Build/relaunch and verify both pipelines**

Run: `./scripts/dev-run.sh`

Manual check: ask a multi-step Frontmost App question, then a General question requiring another app. Confirm named activity appears, the app/tool request appears once, approve or decline it, and the final answer retains its durable trace.

- [ ] **Step 6: Run focused automated tests and commit**

Run: `./scripts/test.sh -only-testing:Context-DockTests/AppChatPromptTests`

Run: `./scripts/test.sh -only-testing:Context-DockTests/CornerGeneralChatTests`

```bash
git add Context-Dock/UI/CornerChatActivityView.swift Context-Dock/UI/AppChatPromptPill.swift Context-Dock/UI/CornerGeneralChatView.swift Context-Dock/AI/GeneralChatWindowModel.swift Context-Dock/Search/AIMessageViews.swift Context-DockTests/AppChatPromptTests.swift Context-DockTests/CornerGeneralChatTests.swift
git commit -m "fix(chat): expose corner work and approvals"
```

---

### Task 5: Correct New Chat and scoped-app controls

**Files:**
- Modify: `Context-Dock/UI/CornerGeneralChatView.swift`
- Modify: `Context-Dock/UI/AppChatPromptPill.swift`
- Modify: `Context-Dock/AI/GeneralChatWindowModel.swift`
- Modify: `Context-Dock/Search/ExtensionPanelWindow.swift`
- Modify: `Context-Dock/Search/LauncherView+AIChat.swift`
- Modify: `Context-Dock/App/NotificationNames.swift`
- Test: `Context-DockTests/CornerGeneralChatTests.swift`

**Interfaces:**
- Consumes: `GeneralChatWindowModel.newChat()`, `attachApp(_:)`, and `removeApp(_:)`.
- Produces: composer `onNewChat: (() -> Void)?`; removes corner use of destructive `onClear`.
- Produces: `.newContextDockChatRequested`, handled by `LauncherView` through
  `clearContextDockChatConversation(keepScope: true)`.
- Preserves: selected General app workspace across New Chat.

- [ ] **Step 1: Write failing New Chat and app-removal tests**

```swift
@Test func newChatKeepsTheSelectedAppWorkspace() {
    let model = GeneralChatWindowModel()
    model.attachApp("Messages")
    model.messages = [AIChatMessage(role: .user, content: "hello")]

    model.newChat()

    #expect(model.messages.isEmpty)
    #expect(model.scopeAppNames.contains("Messages"))
}

@Test func removingAChipImmediatelyRemovesItsScope() {
    let model = GeneralChatWindowModel()
    model.attachApp("Terminal")
    model.removeApp("Terminal")
    #expect(!model.scopeAppNames.contains("Terminal"))
}
```

Use public model setup rather than assigning private-set state if the current declaration requires it.

- [ ] **Step 2: Run focused tests and verify the current mismatch**

Run: `./scripts/test.sh -only-testing:Context-DockTests/CornerGeneralChatTests`

Expected: at least the composer behavior test fails because the corner still wires `clearActiveThread()`.

- [ ] **Step 3: Replace Clear with New Chat**

Change the shared composer contract from destructive `onClear` to `onNewChat`, use a compose/new-chat symbol and accessibility label, and call `model.newChat()` in General mode. In Frontmost mode, post `.newContextDockChatRequested`; `LauncherView` handles it by calling `clearContextDockChatConversation(keepScope: true)`. Do not clear shared history merely because the corner hides.

- [ ] **Step 4: Keep `/app` lookup and chip removal on the real model**

Verify Return selects `ChatSlashAppPicker.pickLeadingMatch`, calls `attachApp`, empties only the slash query, and does not send. Each chip close action calls `removeApp` once and refreshes the active scope immediately. Picker presentation must use Task 2's stand-down protection.

- [ ] **Step 5: Build/relaunch and verify commands**

Run: `./scripts/dev-run.sh`

Manual check: select and remove `/message` and `/terminal`; create a New Chat; confirm the transcript resets, the chosen workspace remains, and no crash or duplicate send occurs.

- [ ] **Step 6: Run focused tests and commit**

Run: `./scripts/test.sh -only-testing:Context-DockTests/CornerGeneralChatTests`

```bash
git add Context-Dock/UI/CornerGeneralChatView.swift Context-Dock/UI/AppChatPromptPill.swift Context-Dock/AI/GeneralChatWindowModel.swift Context-Dock/Search/ExtensionPanelWindow.swift Context-Dock/Search/LauncherView+AIChat.swift Context-Dock/App/NotificationNames.swift Context-DockTests/CornerGeneralChatTests.swift
git commit -m "fix(chat): preserve corner chat workspaces"
```

---

### Task 6: Add the Corner AI Chat enable switch and hotkey guard

**Files:**
- Modify: `Context-Dock/App/AppSettings.swift`
- Modify: `Context-Dock/UI/Settings/HotkeysSettingsPage.swift`
- Modify: `Context-Dock/App/ILauncherApp.swift`
- Modify: `Context-Dock/UI/CornerChatPresentation.swift`
- Test: `Context-DockTests/CornerChatPresentationTests.swift`

**Interfaces:**
- Produces: `AppSettings.cornerAIChatEnabled: Bool`, default `true`.
- Consumes: existing App Chat hotkey registration and `activateAppChatPrompt()` entry point.

- [ ] **Step 1: Add a failing disabled-entry test**

Extract a pure guard usable by the hotkey handler:

```swift
@Test func disabledCornerChatRejectsExplicitPresentation() {
    #expect(!CornerChatAvailability.canPresent(isEnabled: false))
    #expect(CornerChatAvailability.canPresent(isEnabled: true))
}
```

- [ ] **Step 2: Run the focused test and verify failure**

Run: `./scripts/test.sh -only-testing:Context-DockTests/CornerChatPresentationTests`

Expected: FAIL because `CornerChatAvailability` and the setting do not exist.

- [ ] **Step 3: Add the setting and settings control**

Add:

```swift
@AppStorage("cornerAIChatEnabled") var cornerAIChatEnabled: Bool = true
```

Present `Enable Corner AI Chat` next to the existing App Chat hotkey configuration. Explain that disabling it leaves main-window conversations and data untouched.

- [ ] **Step 4: Guard and dismiss the corner entry point**

Before activating the panel in `activateAppChatPrompt()`, require `cornerAIChatEnabled`. When the setting changes to false while visible, call `CornerChatPresentation.dismiss()` and disarm the panel keyboard. Do not unregister or alter unrelated launcher hotkeys.

- [ ] **Step 5: Build/relaunch, test, and commit**

Run: `./scripts/dev-run.sh`

Run: `./scripts/test.sh -only-testing:Context-DockTests/CornerChatPresentationTests`

```bash
git add Context-Dock/App/AppSettings.swift Context-Dock/UI/Settings/HotkeysSettingsPage.swift Context-Dock/App/ILauncherApp.swift Context-Dock/UI/CornerChatPresentation.swift Context-DockTests/CornerChatPresentationTests.swift
git commit -m "feat(chat): add corner AI availability control"
```

---

### Task 7: Full regression and running-app acceptance

**Files:**
- Modify only if a verified defect requires a targeted repair.
- Update: `docs/superpowers/specs/2026-09-03-corner-ai-chat-shell-design.md` only to record verified deviations.

**Interfaces:**
- Consumes all behavior completed in Tasks 1–6.
- Produces a verified functional baseline for the later visual-polish milestone.

- [ ] **Step 1: Refresh static graphs and inspect owned changes**

Run: `graphify update .`

Run: `git status --short`

Run: `git diff --check`

Expected: no whitespace errors; only intentional source/tests/docs and expected graph outputs are changed.

- [ ] **Step 2: Run the complete offline suite**

Stop the exact Debug app built from this worktree, then run: `./scripts/test.sh`

Expected: all tests pass with zero failures.

- [ ] **Step 3: Relaunch the exact verified build**

Run: `./scripts/dev-run.sh`

Expected: the script builds into `.build/XcodeDerivedData` and relaunches that binary.

- [ ] **Step 4: Execute the functional acceptance matrix**

Verify in both light and dark appearance:

1. Hotkey opens focused Frontmost App AI for the external frontmost app.
2. Empty-field arrows/swipes switch modes; non-empty text retains cursor behavior.
3. Both modes preserve drafts and in-flight results independently.
4. Named progress replaces spinner-only feedback.
5. App-enable and execution approval cards resolve exactly once.
6. `/message`, `/terminal`, app removal, attachments, cancel, and New Chat work.
7. Composer remains visible and messages/approvals scroll above it.
8. Pointer, focus, pin, generation, approval, and picker prevent stand-down.
9. Unpinned idle state transitions expanded/compact to mini to fully hidden.
10. The mini phase is icon-only and the hidden phase has no hit target or key window.
11. Switching apps or Spaces retargets only Frontmost App AI and never selects Context-Dock.
12. Opening the main window shows the same conversation and no duplicated turn.

- [ ] **Step 5: Commit any acceptance-only repair separately**

If the acceptance matrix reveals a defect, first add a reproducing test, apply the smallest repair, run `./scripts/dev-run.sh`, rerun the focused test, and commit only those files with a `fix(chat): ...` message. If no defect is found, make no empty commit.

- [ ] **Step 6: Record the visual-polish boundary**

Report remaining aesthetic issues separately—materials, shadow tuning, typography, spacing, richer transitions, and result-card styling. Do not mix them into the functional stabilization commits.
