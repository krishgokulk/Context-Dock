# Specification: Issue #204 (P10 / E12) — Retire the Mail Question Pre-Model Shortcut (`DockShortcut.mailQuestion`)

- **Issue:** [#204](https://github.com/krishgokulk/Context-Dock/issues/204)
- **Status:** Shipped (PR #403)
- **Plan Reference:** `docs/master/00-APP-AGENT-PLUGIN-PLAN.md` §10 (`P10` / `E12` — Retire the Dock's pre-model shortcuts into the ladder, one per PR)
- **Precedent:** PR #314 / #315 (Shortcut 1: `DockShortcut.notes` / `tryHandleNotesMCPQuery` retired into `ScopedRoutePolicy` + `AgentSourceAuthority` + `AppleNotesMCPCapabilities`); PR #402 (Shortcut 2: `DockShortcut.menuCommand` / `MenuIntentRouter` retired into `ScopedRoutePolicy`).
- **Branch:** `claude/issue-204-retire-mail-question` (stacked on `claude/issue-204-retire-menu-command`, targeting `general-chat-agent`)
- **Date:** 2026-11-08

---

## 1. Objective & Problem Statement

In `Context-Dock/Search/DockCore+AIChat.swift` (`handleL2Query`, lines 2568–2609), two pre-model branches inside `if dockScope.scopedBundleId == "com.apple.mail"` intercept Mail-scoped questions before any model or `ScopedRoutePolicy` / `AgentSourceAuthority` / `AppleMailMCPCapabilities` ladder runs:

1. **The orphaned "Attach Mail context with the + button first" gate (`DockCore+AIChat.swift:2574–2589`):**
   - Calls `MailQuestionRouter.needsAttachedMailContext(query: rawScopedSearchQuery, isMailContextAttached: isCurrentMailContextAttached())`.
   - `isCurrentMailContextAttached()` (`Context-Dock/Search/DockCore+FinderAttachment.swift:7–13`) reads `@AppStorage("isMailContextAttached") var isMailContextAttached: Bool = false` (`Context-Dock/Search/DockCore.swift:87`).
   - Because the old Dock window and its `+` menu item that toggled `isMailContextAttached` were deleted in Issue #257 E3b (`e71c27db64`), nothing in the codebase ever sets `isMailContextAttached = true`.
   - Consequently, whenever Mail is frontmost (`frontmost.bundleID == "com.apple.mail"`), asking any mailbox question in the Corner's Mail App Pet (`"any unread mail?"`, `"who sent this message?"`, `"what's the subject line?"`, `"do i have any attachments from sarah?"`) is blocked before the model and answered with:
     `"Attach Mail context with the + button first, then ask again. That keeps Mail questions local and targeted to the current mailbox."` — demanding a `+` button that does not exist in the Corner shell.
2. **The pre-model `answerAttachedMailQuestion` keyword shortcut (`DockCore+AIChat.swift:2591–2598`, `DockShortcut.mailQuestion`):**
   - When `isMailContextAttached` was `true` (e.g., persisted in `UserDefaults` from before `#257`), `answerAttachedMailQuestion(for: rawScopedSearchQuery)` (`Context-Dock/Search/DockCore+MailFindActions.swift:312–386`) claimed the turn (`dockShortcutStep(.mailQuestion)`), parsed ad-hoc `from`/`sender`/`subject`/`unread`/`today`/`yesterday` tokens via `mailQuestionFilters` (`lines 248–310`), scanned 150 inbox headers via `MailAutomation.mailboxSnapshotData`, and returned a canned header list without reading message bodies or letting the model use `mail.recent`, `mail.read`, `mail.search`, `mail.unread`, or `mail.currentMessage`.

Meanwhile, the ladder already has full first-party Mail read capabilities (`Context-Dock/AI/AppleMailMCPCapabilities.swift` and `Context-Dock/AI/MailMessageReader.swift`, Issue #178):
- `mail.recent` (recent inbox headers + newest message body, fenced via `UntrustedContent.fenced` and capped at 8,000 characters),
- `mail.read` (one message's body by id or newest),
- `mail.search` (filtered mailbox search by `query`, `sender`, `subject`, `unreadOnly`, `day` = `"today"` / `"yesterday"`),
- `mail.unread` (unread emails with optional `sender` / `subject` filter),
- `mail.currentMessage` (the message selected on screen in Mail).

This task retires `DockShortcut.mailQuestion` (`answerAttachedMailQuestion` and its `needsAttachedMailContext` gate) into the shared ladder so both DockEngine and the Corner's Mail App Pet route Mail questions through `ScopedRoutePolicy`, `AgentSourceAuthority`, `FrontmostAppTaskPlan`, `AppleLiveDataContext`, and `AppleMailMCPCapabilities`.

---

## 2. Exact Behavioural Contract in the Ladder

When a user submits a query in Mail scope (`scopedBundleId == "com.apple.mail"`):

1. **Exact Mailbox Search commands stay on `DockShortcut.mailboxSearch` (untouched by this PR; separate shortcut):**
   - Exact commands claimed by `MailboxSearchCommand.claims(rawScopedSearchQuery)` (e.g., `"search mail from SBI"`) continue to run `executeMailMailboxSearch(intent:userMessage:)` (`DockCore+AIChat.swift:2604–2608`).
   - `MailboxSearchCommand.claims` continues to call `MailQuestionRouter.isQuestionShaped(sentence)` (`Context-Dock/AI/MailboxSearchCommand.swift:80`) so question-shaped sentences are never claimed as bare search commands.

2. **Cross-app NL routing continues to skip Mail questions (`DockCore+AIChat.swift:2613–2615`):**
   - `shouldSkipCrossAppMailRouting` (`dockScope.scopedBundleId == "com.apple.mail" && isQuestionStyleMailQuery(rawScopedSearchQuery)`) remains intact so questions in Mail scope are not hijacked by `CrossAppNLHandler`.

3. **Action Offer Policy (`ScopedRoutePolicy.decide`):**
   - **Questions / Read-only queries** (`"any unread mail?"`, `"is there any mail from sarah today?"`, `"did i get mail from SBI yesterday?"`, `"who sent this message?"`, `"what's the subject line?"`, `"do i have any attachments from sarah?"`, `"check my recent mail from sarah and summarize it"`):
     - `GeneralAIActionResolver.shared.asksOnly(query)` is `true` → `ScopedRoutePolicy.decide` returns `.none` (`offer == nil`, `modelCandidates == []`). No menu command or draft action is offered.
   - **Imperative record reads & write requests** (`"find mail from SBI today"`, `"any mail from sarah today"`, `"draft an email to alex about the invoice"`):
     - Not an exact command title (`ExactCommand.matches` is `false`), and `asksOnly` is `false` → `ScopedRoutePolicy.decide` returns `.model` (`offer == nil`).
     - In `FrontmostAppTaskPlan.make(query:bundleId: "com.apple.mail", appName: "Mail")`, imperative record reads matching `ScopedRecordRead.matches` (`"find mail from SBI today"`, `"search mail from sarah yesterday"`) plan with `intent == .read`, `permitsUIAutomation == false`, `RequestLane.decide(query) == .data`, and include Mail's read tools (`search_mail`, `read_unread_mail`).

4. **Source Authority (`AgentSourceAuthority.decide`):**
   - In `Context-Dock/AI/AgentSourceAuthority.swift`:
     - `ReadOnlyDataDomain(scopeBundleId: "com.apple.mail")` is `.mail` (`Context-Dock/AI/ReadOnlyDataRouter.swift:53`).
     - Currently, `AgentSourceAuthority.asksAboutScopedRecords(_:)` (`AgentSourceAuthority.swift:114–152`) checks `agenda` and `readSignals`, which missed `"yesterday"` (in `agenda`) and `"did i"` (in `readSignals`), as well as Mail-specific question subjects (`"who sent"`, `"subject line"`, `"from "` in a question) that `MailQuestionRouter.mentionsMailbox(_:)` recognizes.
     - We update `MailQuestionRouter` (`Context-Dock/AI/MailQuestionRouter.swift`) to expose `static func isMailboxQuestion(_ query: String) -> Bool` (`isQuestionShaped(query) && mentionsMailbox(query)`), replacing the retired `needsAttachedMailContext(query:isMailContextAttached:)`.
     - We update `AgentSourceAuthority.asksAboutScopedRecords(_:)` to include `"yesterday"` in `agenda` and `"did i"` in `readSignals`, and in `AgentSourceAuthority.decide(query:scopeBundleId:)`, when `ReadOnlyDataDomain(scopeBundleId: scopeBundleId) == .mail`, also treat non-reference, non-change `MailQuestionRouter.isMailboxQuestion(q)` as a live-state record read (`primary: .liveState, requiresFreshRead: true, allowsMemoryEvidence: false`).
     - We update `AgentSourceDecision.promptRule` for `.liveState` (`AgentSourceAuthority.swift:24–25`) to name Mail's typed read tools alongside Notes (`for example notes.search or notes.count for Notes; mail.search, mail.unread, mail.read, or mail.currentMessage for Mail`).
     - We also add `"yesterday"` to `ReadOnlyDataRouter.domain(for:)`'s `readSignals` (`Context-Dock/AI/ReadOnlyDataRouter.swift:71–76`) so `"mail from sarah yesterday"` is recognized as `.mail` alongside `"today"` and `"tomorrow"`.

5. **Pre-fetched Live Context for Tool-less Providers (`AppleLiveDataContext`):**
   - In `Context-Dock/AI/AppleLiveDataContext.swift:146`, the Mail header prefetch currently checks `["email", "mail", "inbox", "message from"].contains(where: q.contains)`.
   - We widen this condition via a pure helper `AppleLiveDataContext.wantsMailContext(_ query: String) -> Bool` that matches `["email", "mail", "e-mail", "inbox", "mailbox", "message from", "subject line"].contains(where: q.contains)` so Mail questions naming `"e-mail"`, `"mailbox"`, or `"subject line"` also receive the pre-fetched inbox header block and `mail.read` / `mail.currentMessage` pointer.

---

## 3. Files to Modify

1. **`Context-Dock/Search/DockCore+AIChat.swift`**
   - In `handleL2Query` (lines 2568–2609), remove `let isMailQuestion = isQuestionStyleMailQuery(rawScopedSearchQuery)`, the `if frontmost.bundleID == "com.apple.mail", MailQuestionRouter.needsAttachedMailContext(...)` block (lines 2574–2589), and the `if isMailQuestion, let answer = answerAttachedMailQuestion(for: rawScopedSearchQuery)` block (lines 2591–2598).
   - Keep `if dockScope.scopedBundleId == "com.apple.mail", let intent = shouldExecuteMailMailboxSearch(for: rawScopedSearchQuery)` (lines 2604–2608) and `shouldSkipCrossAppMailRouting` (lines 2613–2615).

2. **`Context-Dock/Search/DockCore+MailFindActions.swift`**
   - Remove `struct MailQuestionFilters` (lines 248–254), `func mailFieldFilter(from:triggers:)` (lines 256–281), `func mailQuestionFilters(for:)` (lines 283–310), and `func answerAttachedMailQuestion(for:)` (lines 312–386).
   - Keep `func isQuestionStyleMailQuery(_:)` (lines 225–227) and `func shouldExecuteMailMailboxSearch(for:)` (lines 233–246) and all other Mail find helpers.

3. **`Context-Dock/Search/DockCore+FinderAttachment.swift` & `Context-Dock/Search/DockCore.swift`**
   - Remove dead `func isCurrentMailContextAttached() -> Bool` (`DockCore+FinderAttachment.swift:7–13`).
   - Remove dead `@AppStorage("isMailContextAttached") var isMailContextAttached: Bool = false` (`DockCore.swift:87`).

4. **`Context-Dock/Search/DockShortcut.swift`**
   - Remove `case mailQuestion` from `enum DockShortcut`, `displayName`, and `matchedRule`.

5. **`Context-Dock/AI/MailQuestionRouter.swift`**
   - Replace `static func needsAttachedMailContext(query: String, isMailContextAttached: Bool) -> Bool` with `static func isMailboxQuestion(_ query: String) -> Bool` (`isQuestionShaped(query) && mentionsMailbox(query)`), and update the file header comment to reflect that Mail questions route to the live Mail readers rather than demanding an attached mailbox.

6. **`Context-Dock/AI/AgentSourceAuthority.swift` & `Context-Dock/AI/ReadOnlyDataRouter.swift` & `Context-Dock/AI/AppleLiveDataContext.swift`**
   - In `AgentSourceAuthority.swift`:
     - Update `.liveState` `promptRule` to cite `mail.search, mail.unread, mail.read, or mail.currentMessage for Mail`.
     - In `decide(query:scopeBundleId:)`, for `ReadOnlyDataDomain(scopeBundleId: scopeBundleId) == .mail`, also match `isScopedMailQuestion(q)` (`!GeneralAIActionResolver.shared.requestsChange(q) && !isProcedureOrAppQuestion(q) && MailQuestionRouter.isMailboxQuestion(q)`).
     - In `asksAboutScopedRecords(_:)`, add `"yesterday"` to `agenda` and `"did i"` to `readSignals`.
   - In `ReadOnlyDataRouter.swift`:
     - Add `"yesterday"` to `readSignals`.
   - In `AppleLiveDataContext.swift`:
     - Extract `nonisolated static func wantsMailContext(_ query: String) -> Bool` matching `["email", "mail", "e-mail", "inbox", "mailbox", "message from", "subject line"]` and use it at line 146.

7. **`Context-DockTests/MailQuestionRouterTests.swift`**
   - Update tests from `MailQuestionRouter.needsAttachedMailContext(query:isMailContextAttached:)` to `MailQuestionRouter.isMailboxQuestion(_:)`, verifying that ordinary conversation (`"hi hello?"`, `"how are you?"`, `"what's 2+2?"`, `"can you help?"`, `"?"`) returns `false` while real mailbox questions (`"any unread mail?"`, `"who sent this message?"`, `"what's the subject line?"`, `"do i have any attachments from sarah?"`, `"any drafts?"`) return `true`.

8. **`Context-DockTests/DockShortcutTests.swift`**
   - Remove `@Test func mailQuestionStep()`.

9. **`Context-DockTests/RoutingPhrasebookTests.swift`**
   - Add `case mailChat = "Mail chat"` (`scopedApp: "Mail"`) to `Surface`, add `"Mail"` to `knownApps`, and add fixture `mailCreateDraft = capability("Mail", "mail.createDraft", "Create Mail Draft")`.
   - Append Mail chat phrasebook rows covering:
     - `"any unread mail?"` (`.mailChat`, `found: [mailCreateDraft]`, `expected: .none`)
     - `"is there any mail from sarah today?"` (`.mailChat`, `found: [mailCreateDraft]`, `expected: .none`)
     - `"did i get mail from SBI yesterday?"` (`.mailChat`, `found: [mailCreateDraft]`, `expected: .none`)
     - `"who sent this message?"` (`.mailChat`, `found: [mailCreateDraft]`, `expected: .none`)
     - `"what's the subject line?"` (`.mailChat`, `found: [mailCreateDraft]`, `expected: .none`)
     - `"find mail from SBI today"` (`.mailChat`, `found: [mailCreateDraft]`, `expected: .model`)
     - `"any mail from sarah today"` (`.mailChat`, `found: [mailCreateDraft]`, `expected: .model`)
     - `"draft an email to alex about the invoice"` (`.mailChat`, `found: [mailCreateDraft]`, `expected: .model`)
   - Add `struct MailQuestionShortcutRetirementTests` verifying:
     1. `mailScopeQuestionsAreFreshLiveStateReads`: `AgentSourceAuthority.decide(query:scopeBundleId: "com.apple.mail")` returns `.liveState` (`requiresFreshRead == true`, `allowsMemoryEvidence == false`) for `"any unread mail?"`, `"is there any mail from sarah today?"`, `"did i get mail from SBI yesterday?"`, `"who sent this message?"`, `"what's the subject line?"`, and `"do i have any attachments from sarah?"`, while `"hi hello?"` in Mail scope stays `.conversation`.
     2. `findInMailIsADataLaneRead`: `FrontmostAppTaskPlan.make(query: "find mail from SBI today", bundleId: "com.apple.mail", appName: "Mail")` has `intent == .read`, `!permitsUIAutomation`, `RequestLane.decide == .data`, and includes `search_mail` and `read_unread_mail`.
     3. `mailCapabilitiesAreRegisteredAndReadCapabilitiesAreFree`: `CapabilityRegistry.shared` registers `mail.recent`, `mail.read`, `mail.search`, `mail.unread`, and `mail.currentMessage` with `requiresApproval == false`.
     4. `mailQuestionShortcutIsRetiredFromDockShortcut`: `!DockShortcut.allCases.map(\.rawValue).contains("mailQuestion")` and `AppleLiveDataContext.wantsMailContext` matches Mail questions.

10. **`docs/master/00-DOCK-PARITY-INVENTORY.md`, `docs/master/00-NOW.md`, `MEMORY.md`**
    - Add row `D18` in `docs/master/00-DOCK-PARITY-INVENTORY.md` documenting the retired `mailQuestion` pre-model shortcut and dead `isMailContextAttached` gate.
    - Update `docs/master/00-NOW.md` and `MEMORY.md`.

---

## 4. Verification & Acceptance Criteria

1. **Zero remaining references to retired symbols:**
   - `grep -rn "answerAttachedMailQuestion\|mailQuestionFilters\|MailQuestionFilters\|mailFieldFilter\|isCurrentMailContextAttached\|isMailContextAttached\|needsAttachedMailContext\|\.mailQuestion" Context-Dock/ Context-DockTests/` returns 0 matches.
2. **Offline test suite passes:**
   - `./scripts/test.sh -only-testing:Context-DockTests/RoutingPhrasebookTests -only-testing:Context-DockTests/MailQuestionShortcutRetirementTests -only-testing:Context-DockTests/MailQuestionRouterTests -only-testing:Context-DockTests/DockShortcutTests` passes with 0 failures.
3. **Build & Gate check:**
   - `./scripts/check.sh` passes with 0 errors.
   - `./scripts/dev-run.sh` builds and launches the updated binary from `.build/XcodeDerivedData`.
