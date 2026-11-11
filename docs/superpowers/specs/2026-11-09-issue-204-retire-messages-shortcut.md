# Specification: Issue #204 (P10 / E12) — Retire the Messages Pre-Model Shortcut (`DockShortcut.messages`)

- **Issue:** [#204](https://github.com/krishgokulk/Context-Dock/issues/204)
- **Plan Reference:** `docs/master/00-APP-AGENT-PLUGIN-PLAN.md` §2a, §2b (Messages worked examples), §8 (`P10` / `E12` — Retire the Dock's pre-model shortcuts into the ladder, one per PR)
- **Precedent:** PR #314 / #315 (Shortcut 1: `DockShortcut.notes` / `tryHandleNotesMCPQuery`); PR #402 (Shortcut 2: `DockShortcut.menuCommand` / `MenuIntentRouter`); PR #403 (Shortcut 3: `DockShortcut.mailQuestion` / `answerAttachedMailQuestion`).
- **Branch:** `claude/issue-204-retire-messages` (based on `origin/general-chat-agent`)
- **Date:** 2026-11-09

---

## 1. Context & Goals

### 1.1 Problem Statement
In `Context-Dock/Search/DockCore+AIChat.swift` (`handleL2Query`, lines 2555–2566), a pre-model keyword shortcut intercepts Messages-scoped turns (`dockScope.scopedBundleId == "com.apple.MobileSMS"`) before `ScopedRoutePolicy`, `AgentSourceAuthority`, `FrontmostAppTaskPlan`, `CapabilityIndex`, or any AI model can evaluate the request:

```swift
if dockScope.scopedBundleId == "com.apple.MobileSMS",
    let intent = messagesScopedSemanticIntent(for: rawScopedSearchQuery)
{
    dockShortcutStep(.messages)
    executeCrossAppIntent(
        intent,
        userMessage: query,
        unresolvedMessage:
            "❌ Couldn't resolve that Messages recipient. Try: message send \"hi\" to [name]"
    )
    return
}
```

This pre-model shortcut causes four concrete architectural and behavioural bugs:
1. **Bypasses the outbound approval gate (`docs/master/00-APP-AGENT-PLUGIN-PLAN.md` §2b & §9):**
   - `messagesScopedSemanticIntent(for:)` (`Context-Dock/Search/DockCore+ContextualActions.swift:951–955`) delegates to `CrossAppNLHandler.shared.parseMessagesScopedIntent(_:)` (`Context-Dock/Automation/CrossAppNLHandler.swift:142–181`), which regex-matches `send "<text>" to <recipient>` and `send <text> to <recipient>`.
   - `executeCrossAppIntent` (`Context-Dock/Search/DockCore+ContextualActions.swift:706–751`) executes immediately without showing any approval card, violating §2b (*"Composing opens Messages with the text filled in and **never presses Send** (`messages.compose`)"*, *"text Salman I'm running late → data → `messages.compose` → **yes**: outbound card"*) and §9 (*"Writes and outbound always ask"*).
2. **Drops the message body and leaves Corner Messages App Pet transcripts empty:**
   - Inside `CrossAppNLHandler.execute` (`Context-Dock/Automation/CrossAppNLHandler.swift:228–240`), `result.shareResolution ?? fallbackShareResolution(for: result)` always constructs a `ShareIntentResolution` for `.sendMessage` (`lines 252–316`), which discards `intent.messageBody` and calls `ShareIntentRouter.shared.executeMessages` (`Context-Dock/Automation/ShareIntentRouter.swift:195–225`) to share `axContext` (selected files/text/URL) instead of the user's message text.
   - `executeCrossAppIntent` only updates `DockActionFeedback` and never appends the user turn or assistant reply to `l2.chatMessages`, leaving the Corner's Messages App Pet transcript blank.
3. **Duplicate pill path (`makeMessagesSemanticIntentPill`):**
   - `Context-Dock/Search/DockCore+ContextualActions.swift:1109–1152` and `lines 3892–3900, 4209–4211` build a `messages-intent-send-*` pill from `messagesScopedSemanticIntent` that likewise invokes `executeCrossAppIntent` without approval.
4. **Downstream `CrossAppNLHandler` pre-emption on un-armed Messages turns (`DockCore+AIChat.swift:2586–2593`):**
   - When `shouldStayInScopedAIChat` is `false` (e.g., an explicit scoped query from Global search such as `"messages send \"hi\" to Salman"` or `"messages what did Salman text me today?"`), `CrossAppNLHandler.shared.parse(normalizedQuery)` runs at line 2588 with only `shouldSkipCrossAppMailRouting` guarding Mail questions. Because `ShareIntentRouter.shared.parse` matches `"send"`, `"message"`, `"messages"`, and `"text"` with `"to <name>"` even when no contextual selection payload word (`"this"`, `"that"`, `"file"`, etc.) is present, an un-armed Messages turn would be hijacked by `DockShortcut.crossApp` unless Messages-scoped non-share queries also skip `CrossAppNLHandler`.

Meanwhile, the ladder already has full first-party Messages capabilities (`Context-Dock/AI/AppleMessagesMCPCapabilities.swift`):
- `messages.recent` (`.low` risk — headless `MessagesChatDBReader.recent` read of `~/Library/Messages/chat.db`),
- `messages.search` (`.low` risk — headless `MessagesChatDBReader.search` read of `chat.db`),
- `messages.topContacts` (`.low` risk — headless `MessagesInsights.topCorrespondentsReport` count/ranking),
- `messages.compose` (`.medium` risk, `surface: .opensApp`, requires approval — opens Messages with draft filled in and never presses Send),
- `messages.send` (`.high` risk, requires approval — sends message via `MessagesAutomation.sendMessage`).

### 1.2 Goals
1. Retire `DockShortcut.messages`, `messagesScopedSemanticIntent`, `makeMessagesSemanticIntentPill`, and `CrossAppNLHandler.parseMessagesScopedIntent`.
2. Ensure in-scope Messages questions and non-share requests skip `CrossAppNLHandler` (`DockCore.shouldSkipCrossAppMessagesRouting(scopedBundleId:rawScopedQuery:)`).
3. Route all Messages-scoped queries through `ScopedRoutePolicy`, `AgentSourceAuthority`, `ReadOnlyDataRouter`, `FrontmostAppTaskPlan`, `ChatRouteResolver`, and `AppAdapterCapabilityCatalog`.
4. Pin the behaviour first in `Context-DockTests/RoutingPhrasebookTests.swift` (`.messagesChat` phrasebook rows + `MessagesShortcutRetirementTests`).

### 1.3 Non-Goals
- Retiring `DockShortcut.mailboxSearch` or `DockShortcut.crossApp` for genuine cross-app selection sharing (`"send this file to Salman"`). Each remaining shortcut in `DockCore+AIChat.swift` is retired in its own PR per Issue #204.
- Modifying `MessagesChatDBReader` SQLite queries or `MessagesAutomation` AppleScript templates.

---

## 2. Architectural Lane & Layer Alignment

- **Unified Dock Surface & Single Engine Rule (`AGENTS.md`, `docs/master/00-DOCK-AND-CORNER.md`):**
  Both `DockEngine` and the Corner's Messages App Pet execute turns through `DockCore.handleL2Query` and `ScopedRoutePolicy.decide`. Retiring `DockShortcut.messages` removes a pre-model fork and unifies both presentations onto the single ladder.
- **Data Lane vs. UI Lane (`docs/master/00-APP-AGENT-PLUGIN-PLAN.md` §2a & §2b):**
  - **Reads** (`"what did Salman text me today?"`, `"who do I message most?"`, `"do I have any unread messages?"`, `"find messages from Salman"`):
    - `RequestLane.decide(query) == .data`.
    - `FrontmostAppTaskPlan.make(query:bundleId: "com.apple.MobileSMS", appName: "Messages")` plans with `intent == .read` and `permitsUIAutomation == false`, including `get_messages_conversations` and `search_messages`.
    - Reads run headlessly against `~/Library/Messages/chat.db` without launching or activating `Messages.app`.
  - **Compose / Outbound Writes** (`"send \"hi\" to Salman"`, `"send I'm running late to Salman"`, `"text Salman I'm running late"`):
    - `ScopedRoutePolicy.decide` returns `.model` (`offer == nil`, no unapproved pre-model execution).
    - `AgentSourceAuthority.decide` returns `.action` (`requiresFreshRead == true`, `allowsMemoryEvidence == false`).
    - `FrontmostAppTaskPlan.make` plans with `intent == .act` and includes `compose_message` and `send_message`.
    - `AppAdapterCapabilityCatalog. candidate` surfaces `messages.compose` (`riskLevel: .medium`, `requiresApproval == true`) as the scoped adapter candidate.
  - **UI Lane Exact Menu Commands** (`"New Message"`, `"File > New Message"`):
    - `ScopedRoutePolicy.decide` returns `.exactCommand` (`offer?.title == "New Message"`).

---

## 3. Data Model, Invariants & Exact Code Changes

### 3.1 Retire `DockShortcut.messages` and `parseMessagesScopedIntent`
1. **`Context-Dock/Search/DockCore+AIChat.swift` (lines 2555–2593):**
   - Delete lines 2555–2566 (`if dockScope.scopedBundleId == "com.apple.MobileSMS", let intent = messagesScopedSemanticIntent(for: rawScopedSearchQuery) { ... }`).
   - Next to `shouldSkipCrossAppMailRouting` (line 2582), add:
     ```swift
     let shouldSkipCrossAppMessagesRouting = Self.shouldSkipCrossAppMessagesRouting(
         scopedBundleId: dockScope.scopedBundleId,
         rawScopedQuery: rawScopedSearchQuery
     )
     ```
     and guard `CrossAppNLHandler.shared.parse(normalizedQuery)` with `!shouldSkipCrossAppMessagesRouting`.
   - Define `nonisolated static func shouldSkipCrossAppMessagesRouting(scopedBundleId: String, rawScopedQuery: String) -> Bool` on `DockCore`:
     - Returns `false` unless `scopedBundleId.caseInsensitiveCompare("com.apple.MobileSMS") == .orderedSame`.
     - Returns `true` if `MailQuestionRouter.isQuestionShaped(rawScopedQuery)` is `true`.
     - Returns `false` if `rawScopedQuery` (lowercased word tokens) contains an explicit contextual share payload token (`"this"`, `"that"`, `"selected"`, `"selection"`, `"file"`, `"files"`, `"link"`, `"page"`, `"url"`, `"document"`, `"documents"`, `"pdf"`, `"image"`) or names another destination channel/app (`"email"`, `"mail"`, `"airdrop"`, `"safari"`, `"notes"`, `"reminders"`, `"calendar"`, `"finder"`, `"xcode"`, `"slack"`).
     - Otherwise returns `true` so in-scope Messages compose/read/search turns (`"send \"hi\" to Salman"`, `"send I'm running late to Salman"`, `"text Salman I'm running late"`, `"find messages from Salman"`) stay in the Messages ladder instead of being hijacked by `CrossAppNLHandler`.

2. **`Context-Dock/Search/DockCore+ContextualActions.swift`:**
   - Delete `func messagesScopedSemanticIntent(for scopedQuery: String) -> CrossAppIntent?` (lines 951–955).
   - Delete `func makeMessagesSemanticIntentPill(...) -> DockPill?` (lines 1109–1152).
   - Delete `let messagesSemanticIntentPill = ...` (lines 3892–3900) and `if let messagesSemanticIntentPill { pills.append(messagesSemanticIntentPill) }` (lines 4209–4211).

3. **`Context-Dock/Automation/CrossAppNLHandler.swift`:**
   - Delete `func parseMessagesScopedIntent(_ raw: String) -> CrossAppIntent?` (lines 142–181).

4. **`Context-Dock/Search/DockShortcut.swift` & `Context-DockTests/DockShortcutTests.swift`:**
   - Remove `case messages` from `enum DockShortcut`, `displayName`, and `matchedRule` (`Context-Dock/Search/DockShortcut.swift:25, 41, 60`).
   - Remove `@Test func messagesStep()` from `Context-DockTests/DockShortcutTests.swift` (lines 38–40).

### 3.2 Ladder Alignment for Messages Reads and Writes
5. **`Context-Dock/AI/AgentSourceAuthority.swift`:**
   - Update `AgentSourceDecision.promptRule` for `.liveState` (lines 22–30) to cite `messages.recent, messages.search, or messages.topContacts for Messages` alongside Notes and Mail.
   - In `AgentSourceAuthority.decide(query:scopeBundleId:)` (lines 73–80), add `|| (domain == .messages && isScopedMessagesQuestion(q))`.
   - Add `private static func isScopedMessagesQuestion(_ q: String) -> Bool`:
     - Returns `false` if `GeneralAIActionResolver.shared.requestsChange(q)` or `isProcedureOrAppQuestion(q)`.
     - Requires `MailQuestionRouter.isQuestionShaped(q)`.
     - Returns `true` when `q` contains any Messages record signal: `["message", "messages", "imessage", "text", "texts", "texted", "chat", "chatted", "conversation", "conversations", "unread", "who do i talk", "who i talk"]`.
   - In `isLiveStateQuestion(_ q: String)` (line 201), include `"text"`, `"texts"`, `"imessage"` in `liveObjects` so freshness + text queries (`"what did Salman text me today?"`) also classify as `.liveState` when `scopeBundleId` is `nil`.

6. **`Context-Dock/AI/ReadOnlyDataRouter.swift`:**
   - In `ReadOnlyDataRouter.domain(for:)` (line 80), expand the `.messages` keyword list from `["message", "imessage", "text from", "texts", "unread text"]` to `["message", "imessage", "text from", "text me", "texted me", "texts", "unread text"]` so `"what did Salman text me today?"` and `"did Salman text me yesterday?"` resolve to `.messages`.

7. **`Context-Dock/AI/FrontmostAppTaskPlan.swift`, `Context-Dock/AI/ChatRouteResolver.swift`, & `Context-Dock/AI/GeneralAIActionResolver.swift`:**
   - In `ScopedRecordRead.actionWords` (`Context-Dock/AI/FrontmostAppTaskPlan.swift:12–20`), add `"compose "`.
   - In `FrontmostAppTaskPlan.make` (`Context-Dock/AI/FrontmostAppTaskPlan.swift:225`), gate the UI-lane control tools (`find_menu_command`, `run_menu_command`, `send_keys`, `window_control`, `operate_app`, `ax_snapshot`, `ax_act`) on `!readsScopeRecords` (`if !bundleId.isEmpty && !readsScopeRecords`) so data-lane record reads in record-owning scopes (Notes, Mail, Messages) do not include UI-lane tools (plan §2a).
   - In `ChatRouteResolver.isActionRequest(_:)` (`Context-Dock/AI/ChatRouteResolver.swift:286–302`), add `"send"`, `"compose"`, `"draft"`, `"reply"` to `actionVerbs`, and match leading `"text "` or `"message "` (`lowered.hasPrefix("text ") || lowered.hasPrefix("message ")`) so imperative message requests (`"text Salman I'm running late"`, `"message Salman I'm running late"`, `"compose a message to Salman"`) return `isActionRequest == true` (`intent == .act` in `FrontmostAppTaskPlan`), without matching `"text"` or `"message"` as nouns inside read queries (`"find messages from Salman"` still has `ScopedRecordRead.matches == true` and `intent == .read`).
   - In `GeneralAIActionResolver.executeStarts` (`Context-Dock/AI/GeneralAIActionResolver.swift:920–924`), add `"compose "`, `"draft "`, `"text "`, `"message "` so polite requests (`"can you text Salman I'm running late?"`) return `asksOnly == false`.

8. **`Context-Dock/AI/AppAdapterCapabilityCatalog.swift`:**
   - In `messagesCandidate` (`lines 464–505`):
     - Match `messages.compose` when `lower.contains("compose") || lower.contains("send message") || lower.contains("send text") || lower.hasPrefix("text ") || lower.hasPrefix("message ") || (lower.hasPrefix("send ") && lower.contains(" to "))`.
     - For `messages.compose`, parse `send "<body" to <recipient>` and `send <body> to <recipient>` into `candidate.inputValues["recipient"]` and `candidate.inputValues["body"]`, falling back to `textAfterMarker(query, markers: ["text ", "message ", "to "])` for `recipient`.
     - For `messages.search`, add `"find messages from"`, `"find messages about"`, `"find messages"`, `"search messages from"` to `customPrefixes`, and add `" from "` to the preposition strip list in `extractSearchText` (`line 688`) so `"find messages from Salman"` extracts `query = "salman"`.

### 3.3 Thread Safety & State Invariants
- `DockCore.shouldSkipCrossAppMessagesRouting`, `AgentSourceAuthority.decide`, `ScopedRoutePolicy.decide`, `ScopedRecordRead.matches`, and `ChatRouteResolver.isActionRequest` are pure, deterministic value transformations with zero mutable shared state.
- `ReadOnlyDataRouter` and `AppAdapterCapabilityCatalog` remain `@MainActor`-isolated as before.
- No new `@State`, `@Published`, or `UserDefaults` keys are introduced.

---

## 4. Failure Modes & Error Handling

1. **Missing Full Disk Access (`~/Library/Messages/chat.db` unreadable):**
   - `messages.recent` and `messages.search` (`Context-Dock/AI/AppleMessagesMCPCapabilities.swift:72–82, 111–118`) and `messagesReadAnswer` (`Context-Dock/Search/DockCore+GeneralAIActions.swift:1258–1260`) explicitly report that `chat.db` could not be read and instruct the user to grant Full Disk Access in System Settings → Privacy & Security → Full Disk Access, without launching `Messages.app` or falling back to screenshot OCR (honouring `docs/master/00-APP-AGENT-PLUGIN-PLAN.md` §2b).
2. **Messages MCP Disabled (`AppSettings.shared.messagesMCPEnabled == false`):**
   - `AppleMessagesMCPCapabilities.ensureEnabled()` throws `AICapabilityError.blocked("Messages access is disabled in Settings.")`, which surfaces cleanly in the turn output.
3. **Outbound Approval Rejection / App Quit Before Approval:**
   - `messages.compose` (`.medium` risk) and `messages.send` (`.high` risk) require user approval via `PendingApprovalJournal` (Issue #157). If the user cancels or quits the app, no AppleScript or `imessage://` compose action runs.
4. **Task Cancellation:**
   - Submitting a new query in `handleL2Query` cancels any in-flight `l2.currentTask` (`DockCore+AIChat.swift:2501–2506`) before starting the new turn.

---

## 5. Acceptance Criteria & Offline Tests

1. **`Context-DockTests/RoutingPhrasebookTests.swift`:**
   - Add `case messagesChat = "Messages chat"` (`scopedApp: "Messages"`) to `Surface`, add `"Messages"` to `knownApps`, and add fixture `messagesCompose = capability("Messages", "messages.compose", "Open a Message for Review")`.
   - Append `.messagesChat` phrasebook rows covering:
     - `"what did Salman text me today?"` (`.messagesChat`, `found: [messagesCompose]`, `expected: .none`)
     - `"who do I message most?"` (`.messagesChat`, `found: [messagesCompose]`, `expected: .none`)
     - `"do I have any unread messages?"` (`.messagesChat`, `found: [messagesCompose]`, `expected: .none`)
     - `"did Salman text me yesterday?"` (`.messagesChat`, `found: [messagesCompose]`, `expected: .none`)
     - `"send \"hi\" to Salman"` (`.messagesChat`, `found: [messagesCompose]`, `expected: .model`)
     - `"send I'm running late to Salman"` (`.messagesChat`, `found: [messagesCompose]`, `expected: .model`)
     - `"text Salman I'm running late"` (`.messagesChat`, `found: [messagesCompose]`, `expected: .model`)
     - `"find messages from Salman"` (`.messagesChat`, `found: [messagesCompose]`, `expected: .model`)
     - `"New Message"` (`.messagesChat`, `found: [menu("Messages", ["File", "New Message"])]`, `expected: .exactCommand`)
   - Add `@MainActor struct MessagesShortcutRetirementTests` verifying:
     1. `messagesScopeQuestionsAreFreshLiveStateReads`: `AgentSourceAuthority.decide(query:scopeBundleId: "com.apple.MobileSMS")` returns `.liveState` (`requiresFreshRead == true`, `allowsMemoryEvidence == false`, `promptRule.contains("messages.search")`) for `"what did Salman text me today?"`, `"who do I message most?"`, `"do I have any unread messages?"`, `"did Salman text me yesterday?"`, while `"hi hello?"` stays `.conversation`.
     2. `messagesComposeAndSendRequestsAreGatedActions`: for `"send \"hi\" to Salman"`, `"send I'm running late to Salman"`, and `"text Salman I'm running late"`, `AgentSourceAuthority.decide(query:scopeBundleId: "com.apple.MobileSMS").primary == .action`, `FrontmostAppTaskPlan.make(query:bundleId: "com.apple.MobileSMS", appName: "Messages").intent == .act`, `DockCore.shouldSkipCrossAppMessagesRouting(scopedBundleId: "com.apple.MobileSMS", rawScopedQuery:)` is `true`, and `AppAdapterCapabilityCatalog.registeredCandidates` surfaces `messages.compose` (`requiresApproval == true`).
     3. `findInMessagesIsADataLaneRead`: `FrontmostAppTaskPlan.make(query: "find messages from Salman", bundleId: "com.apple.MobileSMS", appName: "Messages")` has `intent == .read`, `!permitsUIAutomation`, `RequestLane.decide == .data`, includes `search_messages` and `get_messages_conversations`, and excludes UI-lane tools (`operate_app`, `run_menu_command`, `find_menu_command`, `send_keys`).
     4. `messagesCapabilitiesRespectApprovalGates`: `CapabilityRegistry.shared` registers `messages.recent`, `messages.search`, and `messages.topContacts` with `requiresApproval == false`, and `messages.compose` and `messages.send` with `requiresApproval == true`.
     5. `messagesShortcutIsRetiredFromDockShortcut`: `!DockShortcut.allCases.map(\.rawValue).contains("messages")` and `ReadOnlyDataRouter.domain(for: "what did Salman text me today?") == .messages`.

2. **Zero remaining references to retired symbols:**
   - `grep -rn "messagesScopedSemanticIntent\|parseMessagesScopedIntent\|makeMessagesSemanticIntentPill\|messagesSemanticIntentPill\|\.messages\b" Context-Dock/Search/DockShortcut.swift Context-Dock/Search/DockCore+AIChat.swift Context-Dock/Search/DockCore+ContextualActions.swift Context-Dock/Automation/CrossAppNLHandler.swift Context-DockTests/DockShortcutTests.swift` returns 0 matches.

3. **Docs & Gate check:**
   - Add row `D19` in `docs/master/00-DOCK-PARITY-INVENTORY.md` documenting the retired `messages` pre-model shortcut.
   - `./scripts/check.sh` passes with 0 errors.
