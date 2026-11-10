# Specification: Issue #204 (P10 / E12) — Retire the Mailbox Search Pre-Model Shortcut (`DockShortcut.mailboxSearch`)

- **Issue:** [#204](https://github.com/krishgokulk/Context-Dock/issues/204)
- **Status:** Goldfish-reviewed (round 1 findings folded in) — awaiting owner sign-off
- **Plan reference:** `docs/master/00-APP-AGENT-PLUGIN-PLAN.md` §2a (lanes), §2b (Mail example), §10 (P10 / E12: one shortcut per PR, phrasebook tests first)
- **Precedent:** `docs/superpowers/specs/2026-11-08-issue-204-retire-mail-question-shortcut.md` (shortcut 3, PR #403)
- **Branch:** `claude/issue-204-retire-mailbox-search-f9190a`, base `general-chat-agent`
- **Date:** 2026-11-10

---

## 1. Context and goals

### 1.1 What exists today

In `handleL2Query` (`Context-Dock/Search/DockCore+AIChat.swift:2568–2578`), when the chat is
scoped to Mail (`dockScope.scopedBundleId == "com.apple.mail"`), this block runs before any model
and before `ScopedRoutePolicy`:

```swift
if dockScope.scopedBundleId == "com.apple.mail",
    let intent = shouldExecuteMailMailboxSearch(for: rawScopedSearchQuery)
{
    dockShortcutStep(.mailboxSearch)
    executeMailMailboxSearch(intent: intent, userMessage: query)
    return
}
```

- `shouldExecuteMailMailboxSearch(for:)` (`Context-Dock/Search/DockCore+MailFindActions.swift:232–246`)
  maps `MailboxSearchCommand.claims(_:)` to a `MailSearchIntent`.
- `MailboxSearchCommand` (`Context-Dock/AI/MailboxSearchCommand.swift`, whole file) is a keyword
  parser: a search verb (`search`, `search for`, `find`, `look for`, `look up`, `lookup`), optional
  scope words, one optional field word, then a value of at most 4 words with no date, qualifier or
  second clause. It has no other caller.
- `executeMailMailboxSearch(intent:userMessage:)` (`DockCore+MailFindActions.swift:530–580`) calls
  `MailAutomation.mailboxSnapshot(senderContains:subjectContains:)` headlessly and appends the raw
  snapshot text as the assistant message. Its own comment records the defect: a search with field
  "any" or "attachment" is matched against the **subject only**.

So `search mail for invoice` never looks at senders, `search mail for attachment report` searches
subjects for "report", no date or unread filter is possible, and the answer is an unformatted header
dump. The ladder already has the better tool: `mail.search` (`Context-Dock/AI/AppleMailMCPCapabilities.swift:71`,
title "Search Mail", inputs `query`, `sender`, `subject`, `unreadOnly`, `day`; a read, no approval)
and the provider tool `search_mail`.

### 1.2 Goal

Delete the pre-model Mailbox Search shortcut. Every sentence it claimed goes through the shared
ladder that every other Mail sentence already uses: `ScopedRoutePolicy.decide` →
`AgentSourceAuthority.decide` → `FrontmostAppTaskPlan.make` → the model, which calls
`mail.search` / `search_mail` in the data lane.

### 1.3 Non-goals

- No new router, keyword list for Mail, or deterministic "exact search" fast path. A search with a
  value is a request, not a command title (`ExactCommand` allows only a trailing number as a value).
- `executeMailMailboxSearch`, `MailSearchIntent`, `mailSemanticSearchIntent` and
  `makeMailSemanticSearchPill` (`DockCore+ContextualActions.swift:1154–1184`) stay. The "Search Mail
  for …" suggestion pill is an explicit click, not a pre-model claim of a typed sentence.
- `isQuestionStyleMailQuery` and `shouldSkipCrossAppMailRouting` (`DockCore+AIChat.swift:2582–2584`) stay.
- The `App Find` shortcut that runs earlier in `handleL2Query` (`DockCore+AIChat.swift:2519–2530`) is
  untouched and is its own retirement PR under #204. It already ran before Mailbox Search. When
  `findIntentMustBeExplicit` is false (the first sentence of a Mail chat that is not yet active, no
  linked CLI, not question-shaped) it claims find/search/look-for sentences with a UI search in
  Mail, exactly as it does today. **The contract in §3 therefore holds for turns App Find does not
  claim — in practice an already-active Mail chat (`wasContextDockChatActive == true`).**
- No change to `mail.search` itself, to `AppAdapterCapabilityCatalog.mailCandidate`, or to any
  write / outbound path.
- PR #404 (Messages shortcut, same issue) is open against the same base and edits neighbouring
  lines of the same files. Whichever merges second rebases; this spec does not depend on it.

---

## 2. Lane and layer alignment

- **One code path.** `handleL2Query` is the engine both the Corner App Chat and `DockEngine` run.
  The change deletes a branch from it; nothing is added per shell. Corner bottom dock and the
  centred launcher both submit through the same function, so there is no shell-specific behaviour.
- **Data lane.** A Mail search is a headless read. The plan for these sentences must have
  `intent == .read`, `permitsUIAutomation == false`, and `RequestLane.decide == .data`; no menu,
  key or window tool is offered. Mail's window is never raised or typed into (owner, 2026-10-10).
- **No second copy.** The retired parser is deleted, not moved. The one rule that survives — a
  look-up verb makes a record read — is added to the existing shared predicate
  `ScopedRecordRead` (`Context-Dock/AI/FrontmostAppTaskPlan.swift:10–34`), which the task plan,
  the source authority and `AppScopedChatService` already share.
- **Task 17 ("exact command or the model").** `ScopedRoutePolicy` is not modified. For these
  sentences it returns `.model` (the `mail.search` candidate is passed to the model as a hint)
  or `.none` (when `GeneralAIActionResolver.asksOnly` reads the sentence as read-only). In both
  classes no action is offered and the model answers with Mail's read tools.
- **Untrusted content.** Mail text reaches the model only through the existing readers, which
  fence it (`UntrustedContent.fenced`). Nothing in this change reads mail itself.

---

## 3. Behavioural contract

The **retired sentences** are the ones `MailboxSearchCommand.claims` accepted. The fixed list
used by the tests:

| # | Sentence |
|---|---|
| 1 | `search mail from SBI` |
| 2 | `search for invoice` |
| 3 | `Search mail for quarterly report` |
| 4 | `find mail from Gokula kannan J` |
| 5 | `look for emails from SBI` |
| 6 | `look up mail from SBI` |
| 7 | `search my inbox for subject payslip` |
| 8 | `please search mail from SBI` |
| 9 | `search from SBI` |
| 10 | `search mail for "invoice and receipt"` |

For every one of them, in Mail scope (`com.apple.mail`):

1. **No pre-model claim.** `handleL2Query` has no Mail-specific branch that answers before the
   model. `DockShortcut` has no `mailboxSearch` case; the trace line "Shortcut: Mailbox Search — …"
   can no longer appear.
2. **Cross-app parser does not claim it.** The next branch in `handleL2Query` calls
   `CrossAppNLHandler.shared.parse(normalizedQuery)` when `!shouldStayInScopedAIChat`. Its
   `searchAppQuery` reads "search mail …" / "find mail …" as `.searchInApp` with target `mail`
   (rows 1, 3, 4, 10) — a UI search of Mail's window, which the retired block used to pre-empt.
   New rule (§3.1a): an intent that searches the app the chat is already scoped to is not
   cross-app and is skipped. For every row, `parse(sentence.lowercased())` is either `nil` or an
   intent for which `searchesScopedApp(intent, scopedBundleId: "com.apple.mail")` is true.
3. **Route policy.** `ScopedRoutePolicy.decide(query:scopedApp: "Mail", namedApp: nil, candidates: [mail.search])`
   returns `.model` or `.none`, never `.exactCommand` or `.crossAppOffer`, and `offer == nil`.
   The phrasebook pins the exact class per row (§5.1).
4. **Source authority.** `AgentSourceAuthority.decide(query:scopeBundleId: "com.apple.mail")`
   returns `primary == .liveState`, `requiresFreshRead == true`, `allowsMemoryEvidence == false`.
5. **Task plan.** `FrontmostAppTaskPlan.make(query:bundleId: "com.apple.mail", appName: "Mail")`
   returns `intent == .read`, `permitsUIAutomation == false`, `complexity != .direct` (a tool round
   is required), and `allowedToolNames` contains `search_mail`.

### 3.1 The one rule change: look-up verbs are record reads

Today `ScopedRecordRead.matches` requires one of `"find "`, `"search "`, `"list "`. Sentences 5
and 6 ("look for …", "look up …") were claimed by the retired parser and match none of them, so
after deletion they would plan as `.answer` or `.act` and ground on conversation.

- Add `static let lookupVerbs = ["find ", "search ", "list ", "look for ", "look up ", "lookup "]`
  to `ScopedRecordRead` and use it in `matches`. All other conditions of `matches` are unchanged:
  the bundle must have a `ReadOnlyDataDomain`, `RequestLane.decide(query) == .data`, and there is
  no explicit action word.
- In `FrontmostAppTaskPlan.make`, `hasRead` becomes `readsScopeRecords || readWords.contains(…)`,
  so a record read always plans as `.read` and never adds the `.memory` source.
- This applies to every app with a `ReadOnlyDataDomain` (Notes, Reminders, Calendar, Messages,
  Contacts, Mail …), by design: "look up notes about tax" in Notes is the same kind of read.
- Guard cases that must stay as they are: `look for the sidebar` (UI lane → not a record read);
  `look for mail from SBI and reply to it` (explicit action word `reply ` → not a record read).

### 3.1a The second rule change: a search of the scoped app is not cross-app

- Add `CrossAppNLHandler.searchesScopedApp(_ intent: CrossAppIntent, scopedBundleId: String) -> Bool`:
  true only when `intent.action == .searchInApp`, `intent.targetAppName` (lower-cased) is a key of
  the handler's existing `appAliases`, and that alias's bundle id equals `scopedBundleId`
  case-insensitively. A nil target, an unknown alias or an empty `scopedBundleId` gives false.
- In `handleL2Query`, the cross-app branch claims the turn only when
  `dockScope.isGlobalScope || isGlobalContextActive || !searchesScopedApp(intent, scopedBundleId: scopedBundleId)`.
  `scopedBundleId` is the function's merged scope (the locked chat scope when a chat is active,
  otherwise the resolved one).
- **When the rule is reachable.** The cross-app branch runs only when `shouldStayInScopedAIChat`
  is false, i.e. the chat is not yet active (or Global Context is active). So the rule changes
  exactly one situation: the **first** sentence of an app-scoped chat, not typed from Global
  Context, that App Find did not claim (question-shaped, or a linked CLI exists, so
  `findIntentMustBeExplicit` is true and the sentence is not an explicit App Find command).
  Before this PR the Mailbox Search block answered that turn in Mail; without this rule the
  cross-app parser would take it and run a UI search. In an already-active chat neither branch
  runs and the sentence reaches the model directly.
- **Global Context is unchanged.** `resolveDockScope` resolves an explicit target there, so
  "search notes tax return" typed in Global Context has `scopedBundleId == com.apple.Notes`; the
  `isGlobalScope || isGlobalContextActive` guard keeps it a cross-app search, as today.
- Scope-neutral in app chats by design (behaviour follows intent and lane, not scope): the first
  sentence "search notes groceries" in Notes' own chat goes to the model as a record read. A
  search of a *different* app and every non-search cross-app intent are unchanged.
- The pure predicate is unit-tested; the scope guard in `handleL2Query` needs a live `DockCore`
  and is covered by the hand check (§5.4), not by an offline test.

### 3.2 What the user sees (accepted changes)

- The answer is written by the model from `mail.search` results instead of the raw snapshot text,
  and the trace shows the tool step instead of "Shortcut: Mailbox Search".
- The turn now costs one model round trip; with no provider configured, or offline, the turn
  fails the way every other Mail sentence already does (the existing provider error message).
  There is no offline fallback to the old snapshot. Accepted: the owner's plan retires every
  pre-model shortcut on these terms.
- **Follow-up after the owner's hand check (2026-11-10).** On a provider with no tool protocol
  (`nativeTools=false`) the first build answered "a full Mail search wasn't readable": the model
  could not call `search_mail` and the prefetch held only the 12 newest headers. Four fixes:
  1. `AppleLiveDataContext.mailSearchIntent(for:)` reads a sender (after "from") or a term (from a
     look-up sentence, or after "about") and an optional day. `appleAppsContextBlock` runs that
     search before the model (`MailAutomation.mailboxSnapshot`, limit 15, off the main thread,
     only when Mail access is enabled) and injects `## Mail — search matches for "<term>"` with
     the headers fenced as untrusted, or a plain "no messages match" line. With no term, or an
     unreadable mailbox, the recent inbox is injected as before. In Mail's own chat the sentence
     need not contain the word "mail" (`scopeBundleId`).
  2. `MailAutomation.mailboxSnapshot(anyContains:)`: a bare `query` is matched against sender
     **or** subject (it was subject only, in `search_mail` and in `mail.search`). Result lines end
     with ` | Id: <n>` so `mail.read` can open a match; `parseSnapshot` ignores the suffix.
  3. `AppleLiveDataContext.mailSearchFilters`: the scoped route puts the user's whole sentence in
     the `query` input, which was searched for verbatim. A sentence is now read as one.
  4. `ChatRouteResolver.termsMatch` ignores glue words (now including "from"): "any mails from
     uel?" matched Mail's read-newest-message route on "from" alone.
  Tests: `MailSearchGroundingTests`.

---

## 4. Files to change

1. `Context-Dock/Search/DockCore+AIChat.swift` — delete the `if dockScope.scopedBundleId == "com.apple.mail", let intent = shouldExecuteMailMailboxSearch(…) { … }` block (2568–2578). Nothing else in the function changes.
2. `Context-Dock/Search/DockCore+MailFindActions.swift` — delete `shouldExecuteMailMailboxSearch(for:)` and its doc comment, and `mailSearchDisplayLabel(query:tokenKind:)`, whose only caller it was. Keep every other helper.
2a. `Context-Dock/Automation/CrossAppNLHandler.swift` and the cross-app branch of `handleL2Query` — §3.1a.
3. `Context-Dock/AI/MailboxSearchCommand.swift` — delete the file (Xcode uses file-system-synchronized groups; if the build reports a stale reference, remove it from `project.pbxproj`).
4. `Context-Dock/Search/DockShortcut.swift` — remove `case mailboxSearch` from the enum, `displayName` and `matchedRule`; reword the "Shortcut: Mailbox Search" example in comments.
5. `Context-Dock/AI/FrontmostAppTaskPlan.swift` — §3.1.
6. `Context-DockTests/DockShortcutTests.swift` — remove `mailboxSearchStep`.
7. `Context-DockTests/RoutingPhrasebookTests.swift` — remove `MailboxSearchCommandTests`; add the rows and suite in §5.
8. `docs/master/00-DOCK-PARITY-INVENTORY.md` (update row D12, add row D20; D19 is the last row today), `docs/master/00-NOW.md`, `MEMORY.md`.

---

## 5. Acceptance criteria and offline tests

All tests are pure and offline (no Mail, no provider, no network).

### 5.1 Phrasebook rows (`RoutingPhrasebookTests.phrasebook`, surface `.mailChat`, `found: [mail.search "Search Mail"]`)

Sentences 1, 2, 4, 5, 7, 10. Expected class for each: `.model` (verified: the unchanged
`asksOnly` is false for all six, and none equals the title "Search Mail").

### 5.2 `MailboxSearchShortcutRetirementTests`

1. `searchCommandsAreFreshLiveStateReads` — §3 item 4 for all 10 sentences.
2. `searchCommandsPlanAsDataLaneReads` — §3 item 5 for all 10 sentences.
3. `crossAppRoutingDoesNotClaimSearchCommands` — §3 item 2 for all 10 sentences; and `parse("search notes tax return")` is non-nil, is not a scoped search for `com.apple.mail`, and is one for `com.apple.Notes`.
4. `lookUpVerbsAreRecordReads` — `ScopedRecordRead.matches` is true for `look for emails from SBI` (Mail) and `look up notes about tax` (`com.apple.Notes`); false for `look for the sidebar` and `look for mail from SBI and reply to it` (Mail).
5. `mailboxSearchShortcutIsRetiredFromDockShortcut` — no `DockShortcut` raw value equals `mailboxSearch`.

### 5.3 Gates

1. `grep -rn "MailboxSearchCommand\|shouldExecuteMailMailboxSearch\|mailSearchDisplayLabel\|\.mailboxSearch\b" Context-Dock Context-DockTests` returns no match (`mailboxSearchPath` in `MailAutomation.swift` is a different symbol and stays).
2. `./scripts/check.sh --full` passes; the suites `RoutingPhrasebookTests`, `MailboxSearchShortcutRetirementTests`, `MailQuestionShortcutRetirementTests`, `DockShortcutTests` are confirmed by name in the result bundle.
3. No existing test changes its expectation except the removals in §4 items 6–7.

### 5.4 Owner hand check (live model; not automatable)

In the Mail App Pet, in both the bottom dock and the centred launcher:

1. Active chat (send "hi" first): `search mail from SBI`, `search for invoice`,
   `look for emails from SBI`.
2. Fresh chat, first sentence (§3.1a): `can you search mail from SBI?` is a question and goes to
   the model. A bare first sentence `search mail from SBI` may still be claimed by App Find
   (§1.3) — note what happens; it is the next PR, not a failure of this one.
3. Global Context: `search notes tax return` still offers the cross-app search of Notes.

Expect: a `mail.search` tool step, a written
answer listing matching messages, Mail not raised, no "Shortcut: Mailbox Search" line. The
"Search Mail for …" pill still works when clicked.

---

## 6. Failure modes

| Case | Behaviour |
|---|---|
| Mail access disabled in Settings (`mailMCPEnabled == false`) | `mail.search` returns its existing disabled error; the model reports it. Unchanged capability behaviour. |
| Mail not running / Automation permission denied | The reader's existing error is returned to the model, which reports it; the data lane never activates Mail. |
| No provider configured, offline, or provider error | The existing provider-failure message of the model path. No snapshot fallback (§3.2). |
| Turn cancelled or a new query typed mid-read | Existing `l2.currentTask` cancellation in `handleL2Query`; no new task or state is introduced. |
| App relaunch | Nothing persisted by the shortcut; no migration. `DockShortcut` raw values are not stored. |
| Mail content containing instructions | Fenced as untrusted by the existing readers; unchanged. |
| A sentence with a look-up verb in an app without a `ReadOnlyDataDomain` | `ScopedRecordRead.matches` is false, as before. |
