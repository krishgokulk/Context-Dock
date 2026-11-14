# Issue #204 (P10 / E12): Retire the Menu Command Pre-Model Shortcut into the Ladder

> **Date:** 2026-11-08
> **Status:** Shipped (PR #402)
> **Target Branch:** `claude/issue-204-retire-menu-command` (bases on `general-chat-agent`)  
> **GitHub Issue:** #204 (Milestone 1.0 — P10 / E12: Retire the Dock's pre-model shortcuts into the ladder, one per PR)  
> **References:**  
> - `AGENTS.md` (DoraX architecture rule: Unified Dock Surface rule, windowless `DockEngine`, Task 17 `ScopedRoutePolicy`)  
> - `docs/master/00-APP-AGENT-PLUGIN-PLAN.md` (§2, §2a, §8 P10 #204, §9 Rules this must not break)  
> - `docs/master/00-DOCK-AND-CORNER.md` (§3 Same engine, same navigation)  
> - `docs/master/00-DOCK-PARITY-INVENTORY.md` (D2, D12, D16)  
> - `Context-Dock/Search/DockCore+AIChat.swift`  
> - `Context-Dock/Search/DockCore+GeneralAIActions.swift`  
> - `Context-Dock/Search/DockCore+ContextualActions.swift`  
> - `Context-Dock/Search/DockCore+ContextLifecycle.swift`  
> - `Context-Dock/Search/DockCore+GlobalContextActions.swift`  
> - `Context-Dock/Search/DockCore+StateBridges.swift`  
> - `Context-Dock/Search/DockCore.swift`  
> - `Context-Dock/Search/DockShortcut.swift`  
> - `Context-Dock/Search/DockModels.swift`  
> - `Context-Dock/Search/FeatureViewModels.swift`  
> - `Context-Dock/Automation/MenuIntentRouter.swift`  
> - `Context-Dock/AI/ScopedRoutePolicy.swift`  
> - `Context-DockTests/RoutingPhrasebookTests.swift`  
> - `Context-DockTests/DockShortcutTests.swift`  
> - `Context-DockTests/MenuPickRuleTests.swift`  

---

## 1. Context & Goals

### 1.1 Problem Statement
In `Context-Dock/Search/DockCore+AIChat.swift` (lines 2540–2649), `handleL2Query(_:skipMenuRouter:isSelectionQuestion:)` contains a legacy pre-model **Menu Intent Router** shortcut (`DockShortcut.menuCommand`) that predates the Task 17 routing ladder (`offerScopedNativeAppAction` → `ScopedRoutePolicy.decide`):

1. **Violates Task 17 ("Exact command or the model"):** `MenuIntentRouter` (`Context-Dock/Automation/MenuIntentRouter.swift:137-340`) scores live and cached menu items using a substring/token heuristic where any single query token (`> 2` characters) matching a menu item title receives `+40` points (`autoClickThreshold = 40`). Consequently, natural-language requests that merely share a word with a menu title (e.g., `"copy the passport pdf to the desktop"` matching `Edit > Copy`, or `"find my passport pdf"` matching `File > Find`) qualify for pre-model interception, or trigger an extra pre-turn `LanguageModelSession` / `AIProviderRouter.shared.send` disambiguation call (`score < 40`).
2. **Dead-End Result Sheet / Pill Strip Output:** When `MenuIntentRouter` matches an item, it records `dockShortcutStep(.menuCommand)`, assigns `self.pendingAIMenuProposal = AIMenuProposal(...)`, clears `searchState.query`, and returns **without appending any message to `l2.chatMessages`**. `pendingAIMenuProposal` was only rendered as a pill (`id: "ai-proposal-..."`) inside `buildDockPills(query:)` (`Context-Dock/Search/DockCore+ContextualActions.swift:3646-3678`) on the retired Dock's pre-model result sheet (#257). In the Corner shell and windowless `DockEngine`, any query claimed by `.menuCommand` produces no chat message or action card.
3. **Duplicate Pre-Model Execution on Miss:** When `MenuIntentRouter` finds no match (`matched == nil`), line 2645 invokes `self.handleL2QuerySkippingMenuRouter(query)`, re-entering `handleL2Query` from the top and re-executing earlier pre-model checks (`tryExecuteTriggerRuleByName`, `trySystemCommand`, `tryHandleGitHubInstallRequest`, `resolvedFindIntent`) a second time.
4. **Already Superseded by the Ladder:** Further down in `handleL2Query` (lines 3507–3531), `offerScopedNativeAppAction` (`Context-Dock/Search/DockCore+GeneralAIActions.swift:291-380`) already resolves live and cached menu commands alongside adapter capabilities, shortcuts, and CLI/MCP routes via `GeneralAIActionResolver.shared.resolve` and filters them through `ScopedRoutePolicy.decide`:
   - Exact menu commands (`ExactCommand.matches`, e.g., `"copy"`, `"new folder"`, `"empty trash"`, `"File > New Folder"`) return `.exactCommand` and present a visible Computer Use action offer in `l2.chatMessages` (shared by Dock and Corner).
   - Non-exact sentences that overlap menu words return `.model` and pass matching menu commands to the model via `ScopedRoutePolicy.modelCandidatesBlock`.
   - Question-shaped sentences return `.none`.

### 1.2 Goals
1. **Retire the `.menuCommand` Pre-Model Shortcut:** Delete the `MenuIntentRouter` dispatch block (lines 2540–2649) in `Context-Dock/Search/DockCore+AIChat.swift` and remove `case menuCommand` from `DockShortcut` (`Context-Dock/Search/DockShortcut.swift`).
2. **Retire `AIMenuProposal` and `pendingAIMenuProposal`:** Remove `struct AIMenuProposal` (`Context-Dock/Search/DockModels.swift:110-120`), `@Published var pendingAIProposal: AIMenuProposal?` (`Context-Dock/Search/FeatureViewModels.swift:171`), `var pendingAIMenuProposal: AIMenuProposal?` (`Context-Dock/Search/DockCore+StateBridges.swift:556-559`), and the `if q.isEmpty, let proposal = pendingAIMenuProposal` branch in `buildDockPills(query:)` (`Context-Dock/Search/DockCore+ContextualActions.swift:3645-3678`).
3. **Remove `MenuIntentRouter` Class While Preserving `MenuPickRule`:** Delete `final class MenuIntentRouter` (`Context-Dock/Automation/MenuIntentRouter.swift:136-340`), which has zero remaining callers, while preserving `MenuPick` and `MenuPickRule` (`Context-Dock/Automation/MenuIntentRouter.swift:31-131`), which are unit-tested by `Context-DockTests/MenuPickRuleTests.swift`.
4. **Simplify `handleL2Query` Entry Signature:** Remove the obsolete `skipMenuRouter: Bool` parameter from `handleL2Query` in `Context-Dock/Search/DockCore+AIChat.swift` so `func handleL2Query(_ query: String, isSelectionQuestion: Bool = false)` is the single implementation; retain `func handleL2QuerySkippingMenuRouter(_ query: String, isSelectionQuestion: Bool = false)` as a thin forwarding alias calling `handleL2Query(query, isSelectionQuestion: isSelectionQuestion)`.
5. **Pin Routing Behavior in `RoutingPhrasebookTests`:** Add phrasebook rows and `MenuCommandShortcutRetirementTests` in `Context-DockTests/RoutingPhrasebookTests.swift` verifying that exact menu commands (`"minimize"`, `"new tab"`, `"zoom in"`, `"File > New Folder"`) route to `.exactCommand`, token-overlapping requests (`"copy the passport pdf to the desktop"`, `"new folder for the tax documents"`, `"export this document as a summary"`, `"how do I export as pdf?"`) route to `.model` with `modelCandidates`, and read/questions (`"where is the sidebar?"`) route to `.none`.
6. **Update Parity Inventory:** Add row `D17` to `docs/master/00-DOCK-PARITY-INVENTORY.md` recording the retirement of the `.menuCommand` shortcut.

### 1.3 Non-Goals
1. Retiring any other shortcut in `DockShortcut` (each shortcut is retired one per PR under Issue #204).
2. Modifying `ScopedRoutePolicy.decide`, `ExactCommand.matches`, or `offerScopedNativeAppAction` (they already implement the target ladder behavior).
3. Deleting `MenuPickRule` or `Context-DockTests/MenuPickRuleTests.swift`.

---

## 2. Architectural Lane & Layer Alignment

### 2.1 DoraX Unified Dock Surface Rule (`AGENTS.md`)
- Both the Corner shell and headless `DockEngine` execute app-scoped turns through `DockCore.handleL2Query` and `ScopedRoutePolicy.decide`.
- Removing the `.menuCommand` pre-model shortcut eliminates a divergence where callers invoking `handleL2Query(_:)` without `skipMenuRouter: true` (such as `handleL2Query()` at line 1195, `handleL2Query(rerunQuery)` at line 1917, and the explicit-scope rerun at line 2796) bypassed `offerScopedNativeAppAction` and wrote to `pendingAIMenuProposal` instead of `l2.chatMessages`.

### 2.2 Data Lane vs. UI Lane & Task 17 Rule
- **Task 17 Rule (`ScopedRoutePolicy`):** A pre-model action offer may claim the turn **only** when the user's sentence is an exact command (`ExactCommand.matches`). Everything else goes to the model (`.model`) or is answered as a read/question (`.none`).
- **Lane Discipline (`FrontmostAppTaskPlan` & `LaneCoordinator`):** In `handleL2Query` (line 3516), `offerScopedNativeAppAction` is gated by `frontmostTaskPlan.permitsUIAutomation`. Data-lane reads (such as `"find notes with links"` in Notes) have `permitsUIAutomation == false` and never offer UI menu commands; UI-lane exact commands (`"minimize"`, `"show sidebar"`, `"new folder"`) have `permitsUIAutomation == true` and are offered through `offerScopedNativeAppAction` with Computer Use consent.

---

## 3. Data Model & Invariants

### 3.1 `DockShortcut` Enum (`Context-Dock/Search/DockShortcut.swift`)
- Remove `case menuCommand` from `enum DockShortcut: String, CaseIterable, Sendable`.
- Remove `case .menuCommand: return "Menu Command"` from `displayName`.
- Remove `case .menuCommand: return "an app menu command"` from `matchedRule`.
- **Invariant:** `DockShortcut.allCases` has 13 distinct cases, each starting with `"Shortcut: "` and tested by `DockShortcutTests`.

### 3.2 `DockCore+AIChat.swift` (`handleL2Query`)
- Replace:
  ```swift
  /// Called when MenuIntentRouter found no menu match — skips menu routing to avoid recursion.
  func handleL2QuerySkippingMenuRouter(_ query: String, isSelectionQuestion: Bool = false) {
      handleL2Query(query, skipMenuRouter: true, isSelectionQuestion: isSelectionQuestion)
  }

  func handleL2Query(_ query: String) {
      handleL2Query(query, skipMenuRouter: false)
  }
  ```
  and
  ```swift
  func handleL2Query(_ query: String, skipMenuRouter: Bool, isSelectionQuestion: Bool = false)
  ```
  With:
  ```swift
  func handleL2QuerySkippingMenuRouter(_ query: String, isSelectionQuestion: Bool = false) {
      handleL2Query(query, isSelectionQuestion: isSelectionQuestion)
  }

  func handleL2Query(_ query: String, isSelectionQuestion: Bool = false)
  ```
- At line 2796 (inside the `isExplicitScopedApp` delayed re-run closure), update:
  ```swift
  self.handleL2Query(fullQueryForRerun, isSelectionQuestion: isSelectionQuestion)
  ```
- Delete lines 2540–2649 (the `// ── Menu Intent Router ──` block).

### 3.3 Removal of `AIMenuProposal` State
1. `Context-Dock/Search/DockModels.swift`: Delete `struct AIMenuProposal` (lines 110–120).
2. `Context-Dock/Search/FeatureViewModels.swift`: Delete `@Published var pendingAIProposal: AIMenuProposal?` (line 171) from `ContextDockViewModel`.
3. `Context-Dock/Search/DockCore+StateBridges.swift`: Delete `var pendingAIMenuProposal: AIMenuProposal?` (lines 556–559).
4. `Context-Dock/Search/DockCore+ContextualActions.swift`: Delete the `if q.isEmpty, let proposal = pendingAIMenuProposal { ... }` block (lines 3645–3678) inside `buildDockPills(query:)`.

### 3.4 Removal of `MenuIntentRouter` Class (`Context-Dock/Automation/MenuIntentRouter.swift`)
- Delete `final class MenuIntentRouter` (lines 136–340).
- Retain `MenuPick` (under `#if canImport(FoundationModels)`) and `enum MenuPickRule` (lines 31–131).

### 3.5 Thread Safety & Isolation
- `handleL2Query`, `offerScopedNativeAppAction`, and `ScopedRoutePolicy` remain `@MainActor`-isolated.
- Removing the unstructured `Task` inside the deleted `MenuIntentRouter` block eliminates an asynchronous hop and recursion point (`handleL2QuerySkippingMenuRouter`) in the middle of `handleL2Query`.

---

## 4. Failure Modes & Error Handling

1. **Closed App with Cached Menu Snapshot:**
   - *Before:* `MenuIntentRouter.findCachedMatch` created a `pendingAIMenuProposal` with `sourcePID: 0`.
   - *After:* `offerScopedNativeAppAction` calls `GeneralAIActionResolver.shared.resolve`, which reads `AppMenuCapabilityCache` when the app is not running. If `ScopedRoutePolicy.decide` selects `.exactCommand`, the offered action launches/restores the app and live-verifies the menu path only after user confirmation (or runs via `LaneCoordinator` with the UI-lane plan card).
2. **Token-Overlapping Natural Language Queries:**
   - *Before:* A sentence such as `"copy the passport pdf to the desktop"` or `"new folder for the tax documents"` matched the single token `"copy"` or `"folder"` with score `>= 40` in `MenuIntentRouter` if invoked with `skipMenuRouter: false`.
   - *After:* `ExactCommand.matches` rejects partial token overlap; `ScopedRoutePolicy.decide` returns `.model` and supplies `Edit > Copy` or `File > New Folder` in `modelCandidates` so the model has the menu path available without preempting the turn.
3. **Question-Shaped Queries:**
   - *Before:* Filtered by an ad-hoc `looksLikeQuestion` prefix list in `handleL2Query`.
   - *After:* Filtered both by `ScopedRoutePolicy.considersActions(query)` (`QuestionClassifier` / read-intent rules) and `FrontmostAppTaskPlan.permitsUIAutomation`, returning `.none` with `offer == nil`.
4. **Task Cancellation:**
   - Removing the intermediate `MenuIntentRouter` `Task` means `l2.currentTask` is only created once at the actual execution stage, preventing a race where cancelling a turn during `MenuIntentRouter.findMatch` could still trigger the fallback `handleL2QuerySkippingMenuRouter` call.

---

## 5. Acceptance Criteria & Offline Tests

1. **Phrasebook Tests (`Context-DockTests/RoutingPhrasebookTests.swift`):**
   - Append new `Phrase` rows to `RoutingPhrasebookTests.phrasebook` covering:
     - Exact menu commands in scoped chats: `"minimize"` (`Window > Minimize`), `"new tab"` (`File > New Tab`), `"zoom in"` (`View > Zoom In`), `"File > New Folder"` (`File > New Folder`) → `.exactCommand`.
     - Token-overlapping requests that `MenuIntentRouter` previously scored `>= 40`: `"copy the passport pdf to the desktop"` (with `Edit > Copy`), `"new folder for the tax documents"` (with `File > New Folder`), `"export this document as a summary"` (with `File > Export as PDF…`), `"how do I export as pdf?"` (with `File > Export as PDF…`) → `.model`.
     - Questions overlapping menu words without change verbs: `"where is the sidebar?"` → `.none`.
   - Add `struct MenuCommandShortcutRetirementTests` in `Context-DockTests/RoutingPhrasebookTests.swift` asserting:
     - Token-overlapping sentences route to `.model` with `offer == nil` and populate `modelCandidates` with the matching menu item.
     - Exact menu titles and explicit menu paths (`"New Tab"`, `"Window > Minimize"`) route to `.exactCommand` with the matching menu candidate as `offer`.
     - `DockShortcut.allCases` does not contain `"menuCommand"`.
2. **Shortcut Trace Tests (`Context-DockTests/DockShortcutTests.swift`):**
   - Remove `menuCommandStep()` and verify `everyFamilyHasADistinctShortcutLine()` passes for all remaining `DockShortcut` cases.
3. **Zero Residual References:**
   - `grep -rn "MenuIntentRouter.shared\|pendingAIMenuProposal\|pendingAIProposal\|AIMenuProposal" Context-Dock/` returns 0 matches.
4. **Build & Test Gate:**
   - `./scripts/check.sh` passes with `build OK`.
   - `MenuPickRuleTests`, `DockShortcutTests`, and `RoutingPhrasebookTests` pass 100% offline.
