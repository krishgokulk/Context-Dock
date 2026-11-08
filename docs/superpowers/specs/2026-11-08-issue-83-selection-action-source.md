# Issue #83: Extract SelectionActionSource Out of DockCore

> **Date:** 2026-11-08  
> **Status:** Specification / Revised (EGM Cycle - Iteration 3)  
> **Target Branch:** `claude/issue-83-selection-action-source` (bases on `general-chat-agent`)  
> **GitHub Issue:** #83 (Milestone 1.0)  
> **References:**  
> - `docs/master/00-NOW.md:13-17`  
> - `docs/master/00-DOCK-AND-CORNER.md` §4a rule 5, §5  
> - `AGENTS.md` (Unified Dock Surface rule, Engine reuse rule)  
> - `docs/master/00-ENGINEERING-OPERATING-MODEL.md`  
> - `Context-Dock/Services/SelectionActions.swift`  
> - `Context-Dock/Search/DockCore+SelectionActionProviding.swift`  
> - `Context-Dock/Search/DockCore+ContextualActions.swift`  
> - `Context-Dock/Search/DockCore+ContextDockPills.swift`  
> - `Context-DockTests/CornerSelectionActionsTests.swift`  

---

## 1. Context & Goals

### 1.1 Problem Statement
On 2026-09-25, the Corner's Selection Scope was bridged to the Dock's Selection builders via `SelectionActionProviding` (`Context-Dock/Services/SelectionActions.swift`). Currently, `DockCore` conforms to `SelectionActionProviding` in `Search/DockCore+SelectionActionProviding.swift`.

This architectural debt blocks the complete retirement of `DockCore` legacy UI paths (`docs/master/00-DOCK-AND-CORNER.md` §4a rule 5 and §5). Specifically:
1. `DockCore+ContextualActions.swift` and `DockCore+ContextDockPills.swift` interweave ~1,300 lines of Selection pill generation, ranking, and execution into `DockCore`.
2. To build selection rows from the Corner, `DockCore+SelectionActionProviding.swift` temporarily mutates `DockCore.selectionScopePayload` using `SelectionActions.withSwapped`, setting `SelectionActions.isScopedToCapturedSelection = true` so Dock helpers skip live-AX lookups. This mutable global state swap is fragile and unnecessary.
3. The Selection card cannot exist independently of the monolithic `DockCore` object.

### 1.2 Goals
1. Extract a standalone `SelectionActionSource` type conforming to `SelectionActionProviding`.
2. Feed `SelectionSnapshot` directly into `SelectionActionSource` methods instead of mutating `DockCore.selectionScopePayload`.
3. Extract `buildSelectionScopePills(query:includeShare:)` and its composed builders from `DockCore+ContextualActions.swift`, `DockCore+ContextDockPills.swift`, and `SystemExtensionActionSource.swift` into `SelectionActionSource`.
4. Provide a decoupled host environment/interface (`SelectionActionHost`) for external side-effects (selection chat navigation, copy feedback toasts, and custom launcher execution).
5. Extract text paste-back into `SelectionPasteback` helper (`Services/SelectionPasteback.swift`), consolidating `pasteNativeWritingToolOutput` and `postNativeWritingToolPasteShortcut` for reuse by both `SelectionActionSource` and `DockCore`.
6. Extract ranking and scoring into a pure static helper `DockPillRanking` (`Search/DockPillRanking.swift`) so `SelectionActionSource` evaluates ranking in the Data Lane without coupling to `DockCore` instance variables.
7. Retain 100% backward compatibility for `DockCore`: `DockCore` delegates its selection scope pills and execution directly to `SelectionActionSource`, ensuring zero duplicated logic.
8. Retain `SelectionActions.withSwapped`, `SelectionActions.isScopedToCapturedSelection`, and `DockCore.selectionRow(from:)` as forwarding aliases so existing unit tests compile and pass without modification.
9. Support standard macOS share picker opening directly from the Corner card for share actions.
10. Maintain 100% passing status for `Context-DockTests/CornerSelectionActionsTests.swift` and all related selection suites.

### 1.3 Non-Goals
1. Redesigning the visual Corner Selection card UI (`UI/SelectionScopeCard.swift`).
2. Modifying the `SelectionActionRow` or `SelectionSnapshot` public interfaces consumed by `SelectionScopeModel`.
3. Rewriting Finder menu extraction (`FinderContextualMenuActionSource`) or macOS extension discovery (`SystemExtensionActionSource`) from scratch; rather, re-root their invocation cleanly under `SelectionActionSource`.
4. Removing `DockCore` entirely in this PR (retiring the rest of `DockCore` belongs to milestone §5 once all sources are extracted).

---

## 2. Architectural Lane & Layer Alignment

### 2.1 Unified Engine Reuse Rule (`AGENTS.md`)
- **No duplicate builders:** The pill builders for text, URL, and file workflows, Ask AI, copy, macOS extensions, Quick Actions, Finder contextual menus, and sharing must exist in exactly one place: `SelectionActionSource`.
- When `DockCore.buildSelectionScopePills` is invoked (e.g. from `DockCore.buildDockPills(query:)`), it calls `SelectionActionSource.buildPills(...)` with its current snapshot.
- `DockEngine.register()` sets `SelectionActions.provider = SelectionActionSource(...)`.
- `DockCore` conforms to `SelectionActionHost` and delegates its `SelectionActionProviding` implementation directly to `SelectionActionSource`.

### 2.2 Data Lane vs. UI Lane Separation
- **Data Lane (Headless Source):** `SelectionActionSource` evaluates `SelectionSnapshot` and query strings in-memory. It computes and ranks `SelectionActionRow`s deterministically using pure static `DockPillRanking` without inspecting or mutating frontmost AX window trees during query filtering.
- **UI Lane (Host Actions):** Operations that require UI interactions (showing notifications, presenting the system share picker, activating Finder, or pasting text back to source apps) are delegated to `SelectionActionHost` or standard macOS services (`NSWorkspace`, `NSPasteboard`, `ShareActionCoordinator`, `SelectionPasteback`, `MenuExecutionCoordinator`).

---

## 3. Data Model, Invariants & Interface Design

### 3.1 Host Interface (`SelectionActionHost`)
To isolate `SelectionActionSource` from `DockCore` dependencies while supporting both headless testing and running app environments:

```swift
@MainActor
public protocol SelectionActionHost: AnyObject {
    /// Navigate or submit a question to the selection-scoped chat session
    func enterSelectionChat(prompt: String, snapshot: SelectionSnapshot)
    
    /// Display feedback notification (e.g. "Copied selected text")
    func showFeedback(title: String, icon: String, success: Bool)
    
    /// Present macOS native sharing picker or dispatch share intent
    func presentShare(items: [Any])
}
```

#### Host Implementations:
1. **`DefaultSelectionActionHost`:** Singleton `DefaultSelectionActionHost.shared` (`@MainActor public final class DefaultSelectionActionHost: SelectionActionHost`) used as the default host for headless or Corner contexts:
   - `enterSelectionChat(prompt:snapshot:)`: Posts notification `.appChatPromptSubmitted` with `userInfo` containing matching keys for `SelectionScopeModel`:
     ```swift
     NotificationCenter.default.post(
         name: .appChatPromptSubmitted,
         object: nil,
         userInfo: [
             "query": prompt,
             "prompt": prompt,
             "selectedText": snapshot.text,
             "appName": snapshot.appName,
             "bundleId": snapshot.bundleID,
             "attachments": snapshot.filePaths,
             "selectionQuestion": true,
         ]
     )
     ```
     This prevents query drops and ensures the AI pipeline preserves the captured selection text rather than falling back to live AX.
   - `showFeedback(title:icon:success:)`: Calls `DockActionFeedback.showResult(title, icon: icon, success: success)`.
   - `presentShare(items:)`: Dispatches to `ShareActionCoordinator.shared.presentSharingPicker(items: items) { _ in }`.
2. **`DockCore: SelectionActionHost`:** When `DockCore` delegates pill generation, it sets `source.host = self` so AI pills invoke its internal AI chat mode (`enterSelectionChat(initialQuery:)`).

`SelectionActionSource` holds a weak reference to avoid retain cycles when hosted by `DockCore`:
```swift
public weak var host: (any SelectionActionHost)?

private var effectiveHost: any SelectionActionHost {
    host ?? DefaultSelectionActionHost.shared
}
```
All host interactions in `SelectionActionSource` dispatch through `effectiveHost`.

### 3.2 Paste-back Extraction (`SelectionPasteback`)
Extracted from `DockCore+ContextualActions.swift:2642` into `Context-Dock/Services/SelectionPasteback.swift`:

```swift
@MainActor
public enum SelectionPasteback {
    /// Pastes replacement text into target process by coordinating window dismissal,
    /// activating target app, and posting synthetic Command-V keystroke.
    @discardableResult
    public static func pasteText(_ text: String, targetPID: pid_t, dismissLauncher: (() -> Void)? = nil) -> Bool {
        guard !text.isEmpty, targetPID != 0 else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        guard let targetApp = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == targetPID }),
              !targetApp.isTerminated
        else { return false }
        
        dismissLauncher?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            guard !targetApp.isTerminated else { return }
            targetApp.activate(options: [.activateIgnoringOtherApps])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                guard !targetApp.isTerminated else { return }
                postPasteShortcut(to: targetPID)
            }
        }
        return true
    }
    
    public static func postPasteShortcut(to pid: pid_t) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let keyCode: CGKeyCode = 9 // 'v'
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        if pid > 0 {
            keyDown?.postToPid(pid)
            keyUp?.postToPid(pid)
        } else {
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }
    }
}
```

### 3.3 Static Ranking Extraction (`DockPillRanking`)
Extracted from `DockCore+ContextDockPills.swift:2377-2560` into `Context-Dock/Search/DockPillRanking.swift`:

```swift
@MainActor
public enum DockPillRanking {
    public static func rank(
        _ pills: [DockPill],
        rawQuery: String,
        rankingQuery: String,
        scopedBundleId: String,
        scopedAppName: String,
        frontmostBundleId: String,
        isExplicitAppScope: Bool,
        includeNonMatching: Bool = false
    ) -> [DockPill]
    
    public static func dedupeRankedDockPills(_ pills: [DockPill]) -> [DockPill]
}
```
This isolates the scoring algorithm as a pure function over the input parameters, allowing `SelectionActionSource` to rank pills in the Data Lane without coupling to `DockCore` mutable state.

### 3.4 `SelectionActionProviding` Protocol Update & Backward Compatibility
In `Context-Dock/Services/SelectionActions.swift`:

```swift
@MainActor
public protocol SelectionActionProviding {
    func selectionRows(for snapshot: SelectionSnapshot, query: String) -> [SelectionActionRow]
    func selectionRows(for snapshot: SelectionSnapshot, query: String, includeShare: Bool) -> [SelectionActionRow]
    @discardableResult
    func runSelectionRow(id: String, query: String, for snapshot: SelectionSnapshot) -> Bool
    @discardableResult
    func replaceSelection(with text: String, for snapshot: SelectionSnapshot) -> Bool
}

public extension SelectionActionProviding {
    /// Default implementation ensures existing conformers (e.g. FakeDock in tests) that only implement
    /// selectionRows(for:query:) continue to compile and conform with zero changes.
    func selectionRows(for snapshot: SelectionSnapshot, query: String, includeShare: Bool) -> [SelectionActionRow] {
        selectionRows(for: snapshot, query: query)
    }
}
```

### 3.5 `SelectionActionSource` Implementation Specification
`SelectionActionSource` lives in `Context-Dock/Services/SelectionActionSource.swift`:

```swift
@MainActor
public final class SelectionActionSource: SelectionActionProviding {
    public weak var host: (any SelectionActionHost)?

    private var effectiveHost: any SelectionActionHost {
        host ?? DefaultSelectionActionHost.shared
    }

    public init(host: (any SelectionActionHost)? = nil) {
        self.host = host
    }

    public func selectionRows(for snapshot: SelectionSnapshot, query: String) -> [SelectionActionRow] {
        selectionRows(for: snapshot, query: query, includeShare: false)
    }

    public func selectionRows(
        for snapshot: SelectionSnapshot,
        query: String,
        includeShare: Bool
    ) -> [SelectionActionRow] {
        guard !snapshot.isEmpty else { return [] }
        let pills = buildPills(for: snapshot, query: query, includeShare: includeShare)
        return pills.filter { !$0.isSeparator }.map(Self.selectionRow(from:))
    }

    @discardableResult
    public func runSelectionRow(id: String, query: String, for snapshot: SelectionSnapshot) -> Bool {
        guard !snapshot.isEmpty else { return false }
        // includeShare is false: per-destination share items are handled inside the Corner card
        let pills = buildPills(for: snapshot, query: query, includeShare: false)
        guard let pill = pills.first(where: { $0.id == id })
            ?? buildPills(for: snapshot, query: "", includeShare: false).first(where: { $0.id == id }),
            pill.isEnabled
        else { return false }
        pill.execute()
        return true
    }

    @discardableResult
    public func replaceSelection(with text: String, for snapshot: SelectionSnapshot) -> Bool {
        guard !text.isEmpty, !snapshot.text.isEmpty,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: snapshot.bundleID).first(where: { !$0.isTerminated })
        else { return false }
        return SelectionPasteback.pasteText(text, targetPID: app.processIdentifier)
    }
    
    public static func selectionRow(from pill: DockPill) -> SelectionActionRow {
        let kind: SelectionActionRow.Kind
        if let prompt = pill.selectionAIPrompt {
            kind = .ask(prompt: prompt)
        } else if pill.isShareAction || isShareRowID(pill.id) {
            kind = .share
        } else {
            kind = .perform
        }
        return SelectionActionRow(
            id: pill.id, title: pill.name, icon: pill.icon, badge: pill.badge,
            accentColorName: pill.accentColorName, kind: kind, approval: pill.runApproval)
    }

    public static func isShareRowID(_ id: String) -> Bool {
        id == "selection-share" || id.hasPrefix("share-") || id.hasPrefix("sharing-action-")
    }
}
```

### 3.6 Complete List of Extracted Builder Pipelines
`SelectionActionSource` extracts and composes the following complete builder suite:

1. `buildPills(for snapshot: SelectionSnapshot, query: String, includeShare: Bool) -> [DockPill]`
2. `selectionScopeAskAIPill(for snapshot: SelectionSnapshot, query: String) -> DockPill`
3. `selectionScopeCopyPill(for snapshot: SelectionSnapshot, query: String) -> [DockPill]`
4. `selectionScopeBuiltInWorkflowPills(for snapshot: SelectionSnapshot, query: String) -> [DockPill]`
   - Text workflows: Rewrite, Bullets, Fix grammar, Shorten, Table.
   - URL workflows: Summarize Link, Extract Tasks, Note Summary.
   - File workflows: File utilities (`open`, `reveal`, `copy-path`), Document AI (`extract-text`, `make-summary`, `find-actions`), Media AI (`describe-image`, `ocr-image`, `alt-text`, `video-brief`, `extract-audio`), Image transforms (`sips`: JPEG, PNG, Compress), Archive (`zip`).
5. `buildFinderFilePills(for snapshot: SelectionSnapshot, query: String) -> [DockPill]` (builds standard file operation pills directly from `snapshot.filePaths`).
6. `buildContextDockSelectionAIPills(for snapshot: SelectionSnapshot, query: String) -> [DockPill]` ("Summarize", "Explain", "Key points", "Translate").
7. `buildNativeSelectionWritingToolPills(for snapshot: SelectionSnapshot, query: String) -> [DockPill]` (Writing Tools prefixed with `selection-writing-tool-`).
8. `buildCustomSelectionExtensionPills(for snapshot: SelectionSnapshot, query: String, excludingTitles: Set<String>) -> [DockPill]` (respects `SelectionActions.runApprovedInCard` for synchronous execution without double-prompting). Custom extension script execution uses a pure static helper `SelectionScopeExtensionPolicy.expandPlaceholders(in:for:)` (extracted from `DockCore+AIResponseHandling.swift:338`) that resolves all placeholder formats directly from `SelectionSnapshot` without depending on `DockCore`: both legacy/camelCase tokens (`{file}`, `{files}`, `{selectedText}`, `{text}`, `{appName}`, `{url}`, `{clipboard}`) and standard snake_case tokens (`{selection}`, `{selection_text}`, `{selection_paths}`, `{app_name}`, `{bundle_id}`).
9. `buildMacOSExtensionActionPills(for snapshot: SelectionSnapshot, query: String, excludingTitles: Set<String>, includeSharing: Bool) -> [DockPill]`
   - Services action pills
   - Finder Quick Actions pills
   - Sharing action pills
   - Shortcuts action pills
   - App Intents action pills
10. `buildFinderSelectionMenuPills(for snapshot: SelectionSnapshot, query: String, excludingTitles: Set<String>, allowedRootNames: Set<String>?) -> [DockPill]` (delegates execution directly to `FinderContextualMenuActionSource.shared.execute` or `MenuExecutionCoordinator.shared.executeDockMenuAction`). To prevent main-thread UI hitches during typing, keystroke filtering (`!query.isEmpty`) reads from `AXMenuReader.shared.cachedAllMenuItems(for: pid, maxDepth: 6)`, reserving live AX menu walking (`refreshAllMenuItems`) solely for initial presentation when `query.isEmpty`.
11. `buildGlobalSelectionSharePills(for snapshot: SelectionSnapshot, query: String) -> [DockPill]`
12. `buildShareQueryDestinationPills(for snapshot: SelectionSnapshot, query: String) -> [DockPill]`
13. `rankSelectionPills(_ pills: [DockPill], for snapshot: SelectionSnapshot, query: String) -> [DockPill]` (delegates to static `DockPillRanking.rank` and `DockPillRanking.dedupeRankedDockPills`).

### 3.7 Backward Compatibility & Test Safety Net
1. **`DockCore.selectionRow(from:)` Forwarding:**
   In `DockCore+SelectionActionProviding.swift`:
   ```swift
   public static func selectionRow(from pill: DockPill) -> SelectionActionRow {
       SelectionActionSource.selectionRow(from: pill)
   }
   ```
   This satisfies direct calls in `CornerSelectionActionsTests.swift:255-258`.
2. **Deprecated State Hooks:**
   In `SelectionActions.swift`:
   ```swift
   @available(*, deprecated, message: "Use SelectionActionSource with explicit SelectionSnapshot instead")
   public static var isScopedToCapturedSelection = false
   
   @available(*, deprecated, message: "Use SelectionActionSource with explicit SelectionSnapshot instead")
   public static func withSwapped<Value, Result>(
       _ value: Value, get: () -> Value, set: (Value) -> Void, _ body: () -> Result
   ) -> Result { ... }
   ```
   This preserves 100% source compatibility for `CornerSelectionActionsTests.swift:176-190`.

---

## 4. Failure Modes & Error Handling

1. **Empty Snapshot:** If `snapshot.isEmpty`, `selectionRows` returns `[]` immediately without evaluating any sub-builders or allocating resources.
2. **Missing Files on Disk:** File workflow operations (e.g. `sips`, `zip`, Reveal in Finder) verify file existence before execution; if files have been moved or deleted since capture, display non-crashing failure feedback via `host.showFeedback(title: "File not found", icon: "exclamationmark.triangle", success: false)`.
3. **App Terminated Prior to Replace:** If the source application terminated while the user was composing an answer in the Selection card, `replaceSelection` returns `false` safely without hanging or raising AX exceptions; `SelectionScopeModel` receives `false` and displays `say("Could not replace", false)`.
4. **Tool / Executable Missing:** For tools like `sips` or `ffmpeg`, path checks verify availability across standard search paths (`/usr/bin`, `/bin`, `/opt/homebrew/bin`, `/usr/local/bin`). If missing, either omit optional workflow pills (like audio extraction from video) or show a graceful error toast.
5. **Concurrent Query Changes:** `buildPills` is pure synchronous computation over the passed `SelectionSnapshot` and `query`. It holds no internal mutable state between calls, making it completely thread-safe on `@MainActor`.

---

## 5. Acceptance Criteria & Verification Plan

### 5.1 Machine-Verifiable Offline Acceptance
1. **Full Test Suite Retention:** `Context-DockTests/CornerSelectionActionsTests.swift` passes without regression to test expectations.
   - Dock rows minus Share match in exact same order for text and file selections.
   - In `CornerSelectionActionsTests.swift:143-146`, the test verifies `includeShare: false` parity against `selectionRows(for:query:includeShare:)`; with `SelectionActionProviding` providing this method directly, line 143 should be updated from `if let launcher = dock as? DockCore` to `let full = dock.selectionRows(for: snapshot, query: "", includeShare: true)` so it asserts against `any SelectionActionProviding` directly without downcasting.
   - Execution runs through `SelectionActionProviding`.
   - Execution operates strictly on captured snapshot, never live AX state.
   - Preset request generation produces identical queries.
   - Dismissal via ✕ and Esc remains intact.
   - Deprecated `withSwapped` assertions in `testTheSwapIsScopedToOneCall` continue to pass.
2. **Zero Inlined Selection Pill Builders in `DockCore`:**
   - `DockCore+SelectionActionProviding.swift` delegates to `SelectionActionSource`.
   - `buildSelectionScopePills` in `DockCore+ContextualActions.swift` delegates to `SelectionActionSource`.
3. **No Global State Swapping in Production:**
   - Production calls from Corner to provider do not touch `SelectionActions.withSwapped`.
4. **Gate Build & Lint:**
   - `./scripts/check.sh` passes with zero compiler errors, zero warnings in changed files, and under oversized-file limits.

### 5.2 Manual / Interactive Verification
1. Open TextEdit, select text "Hello DoraX EGM", press Selection Scope hotkey (⌘⇧S or configured).
   - Selection card displays "15 chars · TextEdit".
   - Actions list shows Ask AI, Copy Text, Rewrite, Share Selection.
2. Select files in Finder, open Selection card.
   - Shows file count and Finder context.
   - Actions show Open, Reveal in Finder, Compress to ZIP, Share.
3. Test filter queries: type "copy" or "zip" and verify real-time filtering and selection execution.
