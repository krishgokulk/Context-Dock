# Issue #83: Extract SelectionActionSource Out of DockCore

> **Date:** 2026-11-08  
> **Status:** Specification / Revised (EGM Cycle - Iteration 2)  
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
1. Extract a standalone `SelectionActionSource` type conforming to `SelectionActionProviding` (`Context-Dock/Services/SelectionActionSource.swift`).
2. Feed `SelectionSnapshot` directly into `SelectionActionSource` methods instead of mutating `DockCore.selectionScopePayload`.
3. Extract `buildSelectionScopePills(query:includeShare:)` and its composed builders from `DockCore+ContextualActions.swift`, `DockCore+ContextDockPills.swift`, and `SystemExtensionActionSource.swift` into `SelectionActionSource`.
4. Provide a decoupled host environment/interface (`SelectionActionHost`) for external side-effects (selection chat navigation, feedback toasts, menu actions, and share pickers).
5. Extract text paste-back into `SelectionPasteback` helper (`Context-Dock/Services/SelectionPasteback.swift`), consolidating `pasteNativeWritingToolOutput` and `postNativeWritingToolPasteShortcut` for reuse by both `SelectionActionSource` and `DockCore`.
6. Retain 100% backward compatibility for `DockCore`: `DockCore` delegates its selection scope pills and execution directly to `SelectionActionSource`, ensuring zero duplicated logic.
7. Retain `SelectionActions.withSwapped` and `SelectionActions.isScopedToCapturedSelection` marked as `@available(*, deprecated)` for test compatibility, but ensure `SelectionActionSource` itself operates without depending on them.
8. Retain `DockCore.selectionRow(from:)` as a public/internal forwarding wrapper to `SelectionActionSource.selectionRow(from:)` to guarantee compilation and pass `CornerSelectionActionsTests.swift:247-259`.
9. Maintain 100% passing status for `Context-DockTests/CornerSelectionActionsTests.swift` and all related selection suites.

### 1.3 Non-Goals
1. Redesigning the visual Corner Selection card UI (`UI/SelectionScopeCard.swift`).
2. Modifying the `SelectionActionRow` or `SelectionSnapshot` public interfaces consumed by `SelectionScopeModel`.
3. Rewriting Finder menu extraction (`FinderContextualMenuActionSource`) or macOS extension discovery (`SystemExtensionActionSource`) from scratch; rather, cleanly re-root their invocation under `SelectionActionSource`.
4. Removing `DockCore` entirely in this PR (retiring the rest of `DockCore` belongs to milestone §5 once all sources are extracted).

---

## 2. Architectural Lane & Layer Alignment

### 2.1 Unified Engine Reuse Rule (`AGENTS.md`)
- **No duplicate builders:** The pill builders for text, URL, and file workflows, Ask AI, copy, macOS extensions, Quick Actions, Finder contextual menus, and sharing must exist in exactly one place: `SelectionActionSource`.
- When `DockCore.buildSelectionScopePills` is invoked (e.g. from `DockCore.buildDockPills(query:)`), it calls `SelectionActionSource.buildPills(...)` with its current snapshot.
- `DockEngine.register()` sets `SelectionActions.provider = SelectionActionSource(...)`.

### 2.2 Data Lane vs. UI Lane Separation
- **Data Lane (Headless Source):** `SelectionActionSource` evaluates `SelectionSnapshot` and query strings in-memory. It computes and ranks `SelectionActionRow`s deterministically without inspecting or mutating frontmost AX window trees during query filtering.
- **UI Lane (Host Actions):** Operations that require UI interactions (showing notifications, presenting the system share picker, activating Finder, or pasting text back to source apps) are delegated to `SelectionActionHost` or standard macOS services (`NSWorkspace`, `NSPasteboard`, `ShareActionCoordinator`, `SelectionPasteback`).

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
    func presentShare(items: [Any], from rect: NSRect?)

    /// Execute a menu action (e.g. Finder contextual menu items)
    func executeMenuAction(
        sourcePID: pid_t,
        launchBundleId: String?,
        path: [String],
        shortcutChar: String?,
        shortcutModifiers: Int
    )
}

public extension SelectionActionHost {
    func executeMenuAction(
        sourcePID: pid_t,
        launchBundleId: String? = nil,
        path: [String],
        shortcutChar: String?,
        shortcutModifiers: Int
    ) {
        MenuExecutionCoordinator.shared.executeDockMenuAction(
            request: .init(
                sourcePID: sourcePID,
                launchBundleId: launchBundleId,
                path: path,
                shortcutChar: shortcutChar,
                shortcutModifiers: shortcutModifiers
            )
        )
    }
}
```

A `DefaultSelectionActionHost` singleton (`DefaultSelectionActionHost.shared`) implements standard system behaviors (`NSWorkspace`, `NSPasteboard`, `DockActionFeedback`, `ShareActionCoordinator`). `SelectionActionSource` holds a strong reference:
```swift
public var host: SelectionActionHost = DefaultSelectionActionHost.shared
```
This guarantees no accidental deallocation when initialized without a custom host override.

### 3.2 Paste-back Extraction (`SelectionPasteback`)
Extracted from `DockCore+ContextualActions.swift:2642` into `Context-Dock/Services/SelectionPasteback.swift`:

```swift
@MainActor
public enum SelectionPasteback {
    /// Pastes replacement text into target process by activating app and posting synthetic Command-V
    @discardableResult
    public static func pasteText(_ text: String, targetPID: pid_t) -> Bool {
        guard !text.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        let targetApp = NSWorkspace.shared.runningApplications.first { $0.processIdentifier == targetPID }
            ?? AppDelegate.shared?.previousFrontmostApp
        let pid = targetPID != 0 ? targetPID : (targetApp?.processIdentifier ?? 0)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            if let targetApp, !targetApp.isTerminated {
                targetApp.activate(options: [.activateIgnoringOtherApps])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                postPasteShortcut(to: pid)
            }
        }
        return true
    }
    
    public static func postPasteShortcut(to pid: pid_t) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let keyCode: CGKeyCode = 9 // Command-V
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

### 3.3 `SelectionActionProviding` Protocol
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
    func selectionRows(for snapshot: SelectionSnapshot, query: String) -> [SelectionActionRow] {
        selectionRows(for: snapshot, query: query, includeShare: false)
    }
}
```

### 3.4 `SelectionActionSource` Implementation Specification
`SelectionActionSource` lives in `Context-Dock/Services/SelectionActionSource.swift`:

```swift
@MainActor
public final class SelectionActionSource: SelectionActionProviding {
    public var host: SelectionActionHost

    public init(host: SelectionActionHost = DefaultSelectionActionHost.shared) {
        self.host = host
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
            id: pill.id,
            title: pill.name,
            icon: pill.icon,
            badge: pill.badge,
            accentColorName: pill.accentColorName,
            kind: kind,
            approval: pill.runApproval
        )
    }

    public static func isShareRowID(_ id: String) -> Bool {
        id == "selection-share" || id.hasPrefix("share-") || id.hasPrefix("sharing-action-")
    }
}
```

### 3.5 Complete List of Extracted Builder Pipelines & URL Classification
`SelectionActionSource` extracts and composes the following builder suite:

1. `buildPills(for snapshot: SelectionSnapshot, query: String, includeShare: Bool) -> [DockPill]`
2. `selectionScopeAskAIPill(for snapshot: SelectionSnapshot, query: String) -> DockPill`
3. `selectionScopeCopyPill(for snapshot: SelectionSnapshot, query: String) -> [DockPill]`
4. `selectionScopeBuiltInWorkflowPills(for snapshot: SelectionSnapshot, query: String) -> [DockPill]`
   - **Classification Rule:**
     ```swift
     if !snapshot.filePaths.isEmpty {
         return selectionScopeFileWorkflowPills(for: snapshot.filePaths.map { URL(fileURLWithPath: $0) }, query: query)
     }
     let trimmed = snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
     if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
         return selectionScopeURLWorkflowPills(for: trimmed, query: query)
     }
     return selectionScopeTextWorkflowPills(for: trimmed, query: query)
     ```
   - Text workflows: Rewrite, Bullets, Fix grammar, Shorten, Table.
   - URL workflows: Summarize Link, Extract Tasks, Note Summary.
   - File workflows: File utilities (`open`, `reveal`, `copy-path`), Document AI (`extract-text`, `make-summary`, `find-actions`), Media AI (`describe-image`, `ocr-image`, `alt-text`, `video-brief`, `extract-audio`), Image transforms (`sips`: JPEG, PNG, Compress), Archive (`zip`).
5. `buildFinderFilePills(for snapshot: SelectionSnapshot, query: String) -> [DockPill]` (builds standard file operation pills directly from `snapshot.filePaths`).
6. `buildContextDockSelectionAIPills(for snapshot: SelectionSnapshot, query: String) -> [DockPill]` ("Summarize", "Explain", "Key points", "Translate").
7. `buildNativeSelectionWritingToolPills(for snapshot: SelectionSnapshot, query: String) -> [DockPill]` (Writing Tools prefixed with `selection-writing-tool-`).
8. `buildCustomSelectionExtensionPills(for snapshot: SelectionSnapshot, query: String, excludingTitles: Set<String>) -> [DockPill]` (respects `SelectionActions.runApprovedInCard` for synchronous execution without double-prompting).
9. `buildMacOSExtensionActionPills(for snapshot: SelectionSnapshot, query: String, excludingTitles: Set<String>, includeSharing: Bool) -> [DockPill]`
   - Services action pills
   - Finder Quick Actions pills
   - Sharing action pills
   - Shortcuts action pills
   - App Intents action pills
10. `buildFinderSelectionMenuPills(for snapshot: SelectionSnapshot, query: String, excludingTitles: Set<String>, allowedRootNames: [String]) -> [DockPill]` (delegates execution directly to `host.executeMenuAction` or `FinderContextualMenuActionSource.shared.execute`).
11. `buildGlobalSelectionSharePills(for snapshot: SelectionSnapshot, query: String) -> [DockPill]`
12. `buildShareQueryDestinationPills(for snapshot: SelectionSnapshot, query: String) -> [DockPill]`
13. `rankSelectionPills(_ pills: [DockPill], for snapshot: SelectionSnapshot, query: String) -> [DockPill]` (uses shared engine ranking utilities `rankDockPills` and `dedupeRankedDockPills`).

### 3.6 Backward Compatibility & Deprecation
1. In `SelectionActions.swift`:
   - Maintain `SelectionActions.isScopedToCapturedSelection` and `SelectionActions.withSwapped` marked as `@available(*, deprecated, message: "Use SelectionActionSource with explicit SelectionSnapshot instead")`.
   - This preserves 100% source-compatibility for `CornerSelectionActionsTests.swift:176-190` (`theSwapIsScopedToOneCall`).
2. In `DockCore+SelectionActionProviding.swift`:
   - Keep `DockCore.selectionRow(from:)` as a public/internal forwarding wrapper:
     ```swift
     public static func selectionRow(from pill: DockPill) -> SelectionActionRow {
         SelectionActionSource.selectionRow(from: pill)
     }
     ```
   - This guarantees `CornerSelectionActionsTests.swift:247-259` (`dockRowsAreClassified`) compiles and passes without alteration.
3. In `DockCore`:
   - `DockCore.buildSelectionScopePills(query:includeShare:)` forwards to `SelectionActionSource`:
     ```swift
     func buildSelectionScopePills(query q: String, includeShare: Bool = true) -> [DockPill] {
         guard let snapshot = currentSelectionSnapshot else { return [] }
         return SelectionActionSource.shared.buildPills(for: snapshot, query: q, includeShare: includeShare)
     }
     ```

---

## 4. Phased Implementation Plan

1. **Phase 1: Paste-back Extraction (`Context-Dock/Services/SelectionPasteback.swift`)**
   - Extract `pasteNativeWritingToolOutput` and `postNativeWritingToolPasteShortcut` into `SelectionPasteback`.
   - Update `DockCore+ContextualActions.swift` to forward to `SelectionPasteback`.
2. **Phase 2: Protocol & Host Seams (`Context-Dock/Services/SelectionActions.swift`)**
   - Add `includeShare: Bool` to `SelectionActionProviding` with default implementation.
   - Define `SelectionActionHost` and `DefaultSelectionActionHost`.
   - Deprecate (but retain) `SelectionActions.isScopedToCapturedSelection` and `withSwapped`.
3. **Phase 3: Standalone `SelectionActionSource` (`Context-Dock/Services/SelectionActionSource.swift`)**
   - Implement `SelectionActionSource` conforming to `SelectionActionProviding`.
   - Move/compose selection pill builders: `selectionScopeAskAIPill`, `selectionScopeCopyPill`, `selectionScopeBuiltInWorkflowPills` (with explicit URL detection), `buildFinderFilePills`, `buildContextDockSelectionAIPills`, `buildNativeSelectionWritingToolPills`, `buildCustomSelectionExtensionPills`, `buildMacOSExtensionActionPills`, `buildFinderSelectionMenuPills`, `buildGlobalSelectionSharePills`, `buildShareQueryDestinationPills`, and ranking.
   - Implement `SelectionActionSource.selectionRow(from:)`.
4. **Phase 4: Delegate `DockCore` to `SelectionActionSource`**
   - Forward `DockCore+SelectionActionProviding.swift` methods directly to `SelectionActionSource`.
   - Forward `DockCore.buildSelectionScopePills` to `SelectionActionSource`.
   - Forward `DockCore.selectionRow(from:)` to `SelectionActionSource.selectionRow(from:)`.
   - Set `SelectionActions.provider = SelectionActionSource()` in `DockEngine`.
5. **Phase 5: Verification & Safety Nets**
   - Run `CornerSelectionActionsTests.swift` (all 50 tests).
   - Run `./scripts/check.sh` to verify build, types, and file size limits.

---

## 5. Failure Modes & Error Handling

1. **Empty Snapshot:** If `snapshot.isEmpty`, `selectionRows` returns `[]` immediately without evaluating any sub-builders or allocating resources.
2. **Missing Files on Disk:** File workflow operations (e.g. `sips`, `zip`, Reveal in Finder) verify file existence before execution; if files have been moved or deleted since capture, display non-crashing failure feedback via `host.showFeedback(title: "File not found", icon: "exclamationmark.triangle", success: false)`.
3. **App Terminated Prior to Replace:** If the source application terminated while the user was composing an answer in the Selection card, `replaceSelection` returns `false` safely without hanging or raising AX exceptions; `SelectionScopeModel` receives `false` and displays `say("Could not replace", false)`.
4. **Tool / Executable Missing:** For tools like `sips` or `ffmpeg`, path checks verify availability across standard search paths (`/usr/bin`, `/bin`, `/opt/homebrew/bin`, `/usr/local/bin`). If missing, either omit optional workflow pills (like audio extraction from video) or show a graceful error toast.
5. **Concurrent Query Changes:** `buildPills` is pure synchronous computation over the passed `SelectionSnapshot` and `query`. It holds no internal mutable state between calls, making it completely thread-safe on `@MainActor`.

---

## 6. Acceptance Criteria & Verification Plan

### 6.1 Machine-Verifiable Offline Acceptance
1. **Full Test Suite Retention:** `Context-DockTests/CornerSelectionActionsTests.swift` passes without modification to test expectations.
   - Dock rows minus Share match in exact same order for text and file selections.
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

### 6.2 Manual / Interactive Verification
1. Open TextEdit, select text "Hello DoraX EGM", press Selection Scope hotkey (⌘⇧S or configured).
   - Selection card displays "15 chars · TextEdit".
   - Actions list shows Ask AI, Copy Text, Rewrite, Share Selection.
2. Select files in Finder, open Selection card.
   - Shows file count and Finder context.
   - Actions show Open, Reveal in Finder, Compress to ZIP, Share.
3. Test filter queries: type "copy" or "zip" and verify real-time filtering and selection execution.
