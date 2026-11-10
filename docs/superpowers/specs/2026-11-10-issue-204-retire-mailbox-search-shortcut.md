# Specification: Issue #204 (P10 / E12) — Retire the Mailbox Search Pre-Model Shortcut (`DockShortcut.mailboxSearch`)

- **Issue:** [#204](https://github.com/krishgokulk/Context-Dock/issues/204)
- **Status:** Draft — awaiting Goldfish review and owner sign-off
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
- `executeMailMailboxSearch(intent:userMessage:)` (`DockCore+MailFindActions.swift:530–573`) calls
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
  untouched; it already ran before Mailbox Search, so what it claims does not change.
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
2. **Cross-app parser does not claim it.** `CrossAppNLHandler.shared.parse(sentence.lowercased())`
   is `nil` (it is the next branch in `handleL2Query`).
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

### 3.2 What the user sees (accepted changes)

- The answer is written by the model from `mail.search` results instead of the raw snapshot text,
  and the trace shows the tool step instead of "Shortcut: Mailbox Search".
- The turn now costs one model round trip; with no provider configured, or offline, the turn
  fails the way every other Mail sentence already does (the existing provider error message).
  There is no offline fallback to the old snapshot. Accepted: the owner's plan retires every
  pre-model shortcut on these terms.
- Tool-less providers get inbox headers pre-fetched only when
  `AppleLiveDataContext.wantsMailContext(query)` is true. Sentences 2 and 9 contain none of its
  words; a tool-less provider answers them from the source-authority rule alone and may say it
  cannot search. Accepted and listed as a hand-check item; not widened here.
- `mail.search` matches `query` against sender **or** subject, which fixes the subject-only defect.

---

## 4. Files to change

1. `Context-Dock/Search/DockCore+AIChat.swift` — delete the `if dockScope.scopedBundleId == "com.apple.mail", let intent = shouldExecuteMailMailboxSearch(…) { … }` block (2568–2578). Nothing else in the function changes.
2. `Context-Dock/Search/DockCore+MailFindActions.swift` — delete `shouldExecuteMailMailboxSearch(for:)` and its doc comment. Keep every other helper; `mailSearchDisplayLabel` is deleted only if the build shows it has no remaining caller.
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

Sentences 1, 2, 4, 5, 7, 10. Expected class: `.model`. If the unchanged `asksOnly` classifies a
row as read-only, that row's expected class is `.none` and the spec is updated to say which; a
row may never be `.exactCommand`.

### 5.2 `MailboxSearchShortcutRetirementTests`

1. `searchCommandsAreFreshLiveStateReads` — §3 item 4 for all 10 sentences.
2. `searchCommandsPlanAsDataLaneReads` — §3 item 5 for all 10 sentences.
3. `crossAppRoutingDoesNotClaimSearchCommands` — §3 item 2 for all 10 sentences.
4. `lookUpVerbsAreRecordReads` — `ScopedRecordRead.matches` is true for `look for emails from SBI` (Mail) and `look up notes about tax` (`com.apple.Notes`); false for `look for the sidebar` and `look for mail from SBI and reply to it` (Mail).
5. `mailboxSearchShortcutIsRetiredFromDockShortcut` — no `DockShortcut` raw value equals `mailboxSearch`.

### 5.3 Gates

1. `grep -rn "MailboxSearchCommand\|shouldExecuteMailMailboxSearch\|\.mailboxSearch\b" Context-Dock Context-DockTests` returns no match (`mailboxSearchPath` in `MailAutomation.swift` is a different symbol and stays).
2. `./scripts/check.sh --full` passes; the suites `RoutingPhrasebookTests`, `MailboxSearchShortcutRetirementTests`, `MailQuestionShortcutRetirementTests`, `DockShortcutTests` are confirmed by name in the result bundle.
3. No existing test changes its expectation except the removals in §4 items 6–7.

### 5.4 Owner hand check (live model; not automatable)

In the Mail App Pet, in both the bottom dock and the centred launcher: `search mail from SBI`,
`search for invoice`, `look for emails from SBI`. Expect: a `mail.search` tool step, a written
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
