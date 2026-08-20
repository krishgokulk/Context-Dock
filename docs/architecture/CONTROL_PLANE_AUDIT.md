# DoraX control-plane audit

Read-only inventory of how an executable request travels from intent to receipt.
No code changed *by the audit*; steps 1 and 2 of §7 have since been applied and their
rows are marked **done** below. Produced as **Gate A** input: nothing about bounded loops, graph
orchestration, or scheduled autonomy should be built until this table has no blanks.

Method: traced `DoraXActionCandidate` → `GeneralAIActionExecutor` → verification →
receipt, plus the two other surfaces that execute (Context Dock Chat, provider tool
loop). Source of truth is the code, not this file — re-run the audit when routes change.

---

## 1. What already exists

More of the canonical model is real than the roadmap assumed. Recording it so the
consolidation extends these rather than inventing parallel abstractions.

| Concept | Type | File | State |
|---|---|---|---|
| Action candidate | `DoraXActionCandidate` | `AI/GeneralAIActionResolver.swift:22` | Complete. `Source` (10), `ExecutionRoute` (10), `Operation` (read/execute), risk, confidence, permission key, execution payload |
| Authority | `AppAccessPolicy` / `AppAccessLevel` | `AI/AppAccessLevel.swift` | Complete. Three levels (`awareness`/`menuOnly`/`adapter`), asked **per route**, not per app |
| Risk / approval | `AICapabilityRiskLevel` | `AI/AICapabilityRegistry.swift:5` | Complete. `low`/`medium`/`high`/`critical`. `.critical` is hard-denied at `AICapabilityRegistry.swift:677` **before** the approval check — deliberate, not a gap |
| Approval | `ApprovalCenter`, `ApprovalRisk` | `AI/ApprovalCenter.swift` | Complete. Already collapsed three earlier approval systems into one risk scale |
| Folder-scope guard | `CapabilityScopeGuard` | `AI/CapabilityScopeGuard.swift` | Complete. Runs before executor, over arguments as written, symlink-resolved |
| Durable task state | `TaskRunStore` | `AI/TaskRunStore.swift` | Real and on disk (`~/…/Context-Dock/task-runs/*.json`). Resumable, interrupts survive relaunch. **Scoped to provider tool loops only** — see §4 |
| Turn result | `GeneralChatWorkflowResult` | `AI/GeneralChatWorkflowResult.swift` | Surface-neutral by design. Carries `route`, `status`, `complexity`, `taskRunID`, `receipts`, `verification` |
| Capability output rows | `CapabilityResultTable` / `Row` | `AI/CapabilityResult.swift` | Complete. Structured rows alongside prose |

**Correction to the roadmap:** `TaskRunStore` and a typed `VerificationStatus` are *not*
missing. The problem is not absence — it is that each concept exists more than once.

---

## 2. Route inventory

`ExecutionRoute` cases and what each one actually guarantees.

| Route | Authority gate at `menuOnly` | Live pre-check | Verifier | Verification result |
|---|---|---|---|---|
| `appLaunch` | allowed at `awareness` | — | `NSRunningApplication` by bundle ID | **verified / unverified** |
| `verifiedMenu` | allowed | live menu read before click | `MenuOutcomeVerifier` window-list diff (350 ms settle) | **verified / unverified** |
| `keyboardShortcut` | allowed | live-verifies backing menu record first | same as `verifiedMenu` | **verified / unverified** |
| `axFallback` | **denied** | live menu verification required before click | none | `skipped` |
| `adapter` | **denied** | — | only via capability ID (§3) | `skipped` otherwise |
| `mcp` | **denied** | — | only via capability ID | `skipped` otherwise |
| `api` | **denied** | — | only via capability ID | `skipped` otherwise |
| `cli` | **denied** | — | `CommandOutcomeVerifier` (appearance, quit) + capability ID | **verified / contradicted**, else `notApplicable` |
| `shortcutRunner` | **denied** | — | none | `skipped` |
| `automation` | **denied** | — | none | `skipped` |

`GeneralAIActionExecutor.verify(_:)` no longer has a `default:`. Every route is named, and
the ones with no verifier say which they are and why — see §7 step 4.

---

## 3. Verification coverage by capability

Capability-ID read-backs in `GeneralAIActionExecutor.verifyCapability(id:inputValues:)`.
This is the one verifier both the candidate path and the agent tool loop share.

| Capability | Read-back | Notes |
|---|---|---|
| `reminders.create` | `AppleAppsAPI.getReminders(limit:30)` title match | verified / unverified |
| `reminders.delete` | absence from open reminders | shared with `.complete` |
| `reminders.complete` | absence from open reminders | absence is the confirmation either way |
| `calendar.create` | `getCalendarEvents(limit:30)` title match | refines success text with the date |
| `notes.create` | `searchNotes(query:)` | |
| `finder.newFolder` | `FileManager.fileExists(isDirectory:)` | |
| `finder.trash` | `FileManager.fileExists` — inverted | deletion gets the strictest handling |
| **everything else** | — | `.skipped` |

Verified: **7 capability IDs + 3 routes.** Every other write is executor-word only.

---

## 4. Duplicated concepts (the actual finding)

### 4a. Receipt — three types, one shape · **done**

All three wrap `AIProviderService.ExecutedCommand`. Fields are effectively identical.

| Type | File | Persisted |
|---|---|---|
| `TaskRunStore.Receipt` | `AI/TaskRunStore.swift:18` | yes (JSON, `+recordedAt`) |
| `GeneralChatWorkflowResult.Receipt` | `AI/GeneralChatWorkflowResult.swift:42` | no |
| `EvidenceReceipt` | **`Search/AIMessageViews.swift:538`** | no |

`GeneralChatWorkflowResult.Receipt` and `EvidenceReceipt` were field-for-field the same
struct. One lived in the AI layer, one in a **view file** — receipt shape was defined by a
presentation type.

**Resolved.** `DoraXActionReceipt` owns it. `TaskRunStore.Receipt` is a typealias,
`EvidenceReceipt` is gone, and the field names follow the persisted form so runs already on
disk decode unchanged. `id` sits outside `CodingKeys` because older files never wrote one.

### 4b. Verification — three vocabularies · **done for two of three**

| Type | Cases |
|---|---|
| `GeneralAIActionExecutor.VerificationOutcome` | `verified` / `unverified` / `skipped` |
| `GeneralChatWorkflowResult.Verification` | `verified` / `executorConfirmed` / `unavailable` / `failed` |
| Context Dock Chat | untyped `String?` state dump, always recorded `success: true` |

Mapping between the first two was lossy in both directions, and there was no
`contradicted` anywhere: "the verifier ran and proved the write did **not** land" was
expressed as `unverified` — the same value as "we did not check".

**Resolved for the executor and the turn record.** One `VerificationStatus`:
`verified` / `contradicted` / `unverified` / `notApplicable`, with `claimsSuccess` true for
exactly one of them. `VerificationOutcome` gained `.contradicted(evidence:)` and renamed
`.skipped` to `.notApplicable`, and the read-backs that are conclusive now say so —
`finder.trash` with the file still present, `finder.newFolder` with nothing there,
`reminders.delete`/`.complete` with the item still open, and `appLaunch` with the app not
running. The windowed reads (`reminders.create`, `calendar.create`, `notes.create`, the
menu window diff) stay `unverified`, which is what they honestly are.

**Still open:** Context Dock Chat, which has no typed verification at all — §5, step 3.

### 4c. Route — three enums on three different axes · **partly done**

| Type | Axis | Cases |
|---|---|---|
| `DoraXActionCandidate.ExecutionRoute` | execution mechanism | 10 |
| `GeneralChatWorkflowResult.Route` | turn classification | 12 (`conversation`, `liveState`, `memory`, `selection`, …) |
| `ChatRouteResolver.Kind` | Context Dock offer | 7 (`cli`, `adapterAction`, `menuCommand`, `mcpTool`, `skill`, `model`, …) |

These are not redundant — they answer different questions — but nothing declared the
mapping, so `adapterAction` → `.adapter` → `appAdapter` was re-derived per call site.

**Partly resolved.** `GeneralChatWorkflowResult` now carries both axes: `route` classifies
the turn, `executionRoute` names the mechanism, and `Route.classifying(_:)` declares the
relation in one place. This was forced by wiring — `Route` has no case for an app launch,
an API call, a Shortcut, a keyboard shortcut or an accessibility fallback, and folding them
into `appAdapter` would have discarded the distinction `AppAccessPolicy` is built on.
`ChatRouteResolver.Kind` is still unrelated to either.

---

## 5. Surface parity

Three things execute. They do not agree.

| | General AI (candidate path) | Agent tool loop (`run_capability`) | Context Dock Chat |
|---|---|---|---|
| Entry | `GeneralAIActionExecutor.execute` | `AgentToolRegistry.swift:1480` → same executor | `AppScopedChatService.execute` → `ChatRouteResolver.run` |
| `AppAccessPolicy` | yes | yes (`:1290`, `:1346`, `:1470`) | **yes** (step 3) |
| Shared verifier | `GeneralAIActionExecutor.verify` | same | `MenuOutcomeVerifier` for menu routes; `notApplicable` elsewhere |
| Verification method | typed read-back | typed read-back | typed for menus; state block demoted to context |
| `TaskRunStore` tracking | via provider service | via provider service | **no** |
| Receipt type | `DoraXActionReceipt` | same | same |

The agent tool loop was already unified with General AI — the executor comment at
`GeneralAIActionExecutor.swift:200` records that `verifyCapability` was split out
precisely because "two execution paths, one of them verified, is the same shape of bug as
two send paths with one of them wired."

**That same bug is still present between General AI and Context Dock Chat.**

Context Dock Chat's post-action check re-reads the app's context and hands the prose to
the model. It never returns pass/fail; it records `success: true` unconditionally. It is
a **state dump**, not a gate. Nothing downstream can distinguish "the menu command landed"
from "we looked at the app afterwards."

This is a scope-preserving fix, not a merge: the two surfaces keep different context
rules and different capability catalogues. Only authority, verification and receipt
semantics are shared.

---

## 6. Gate A status

> No loop / graph work until every important capability has: owner, authority
> classification, canonical executor, verification state.

| Requirement | Status |
|---|---|
| Owner (capability ID + source) | **met** — `DoraXActionCandidate` carries both |
| Authority classification | **met** — all three surfaces ask `AppAccessPolicy` |
| Canonical executor | **met for two of three surfaces** — Context Dock Chat runs `ChatRouteResolver` |
| Verification state | **met as far as it can be** — one vocabulary, every surface typed, every route named; 5 routes have no read-back and say so |

**Gate A has one row left.** Context Dock Chat still runs `ChatRouteResolver` rather than
the shared executor, which is also what blocks `verifyCapability` there (§7 step 3) and what
keeps `TaskRunStore` off that path (§5).

---

## 7. Narrowest change that opens Gate A

Ordered. Each is independently shippable. None touches UI, the resolver, the capability
registry, Global Context, or the typing path.

1. ~~**Collapse the receipt.**~~ **Done** — `DoraXActionReceipt`, no migration.

2. ~~**One verification vocabulary.**~~ **Done** — `VerificationStatus`, with
   `contradicted` separated from `unverified` at the four read-backs that are conclusive.

3. ~~**Route Context Dock Chat through the shared gate.**~~ **Done** — `AppAccessPolicy`
   runs before `ChatRouteResolver.run` (CLI routes exempt: a `cli://` bundle id names a
   tool, not an app), menu routes verify through `MenuOutcomeVerifier`, and the state block
   is demoted from verification to context. `verifyCapability` was *not* usable here:
   `ChatRoute` carries an adapter action id, a menu path or an MCP tool name, never a
   capability id with inputs. Closing that needs the shared executor, not a shared verifier.

4. ~~**Extend verification to the six `skipped` routes.**~~ **Done.** `cli` now reads back
   through `CommandOutcomeVerifier`, which existed and was wired into the agent tool loop
   only — so the same command verified in one surface and not the other. Its verdict is
   typed rather than spelled: callers decided pass or fail by matching the prefix
   "NOT applied", which every reader had to parse and any rewording would break.

   The rest are named instead of falling through a `default:`, each with the reason it has
   no read-back. `adapter` and `api` reach that line only when the capability-id verifiers
   found nothing. `mcp` returns what a server chose to return, and there is no second call
   meaning "did that land". `shortcutRunner` hands off to Shortcuts, which reports its own
   success and nothing about the world afterwards. `automation` composes in another app —
   the window it opens is the outcome, and the user is looking at it. `axFallback` is
   reached only after a live menu verification has already passed.

Only after 1–4: `DoraXTaskContract`, TaskRunStore beyond the provider loop, bounded
loops, graphs, scheduled autonomy.

---

## 8. Explicitly out of scope

Confirmed by this audit and unchanged:

- **No central database.** Calendar, Reminders, Notes, GitHub, Mail, Finder and the
  browser remain their own systems of record. DoraX stores references, receipts and
  approved durable knowledge — never mirrored copies.
- Global Context stays cache-first. No control-plane work on the typing path.
- No live AX menu scan during search. The resolver reads cached/registry metadata only.
- No LangGraph / CrewAI / graph framework.
- No new floating surface.
- Product layers stay separate. §5 unifies *semantics*, not surfaces.

---

## 9. Deferred — General AI routing bugs found alongside this work

Not control-plane defects; recorded here so they are not lost. Reproduced 2026-08-19 in
dock General Chat with ChatGPT selected.

### 9a. A keyword-shaped query never reaches its Global Command · **fixed**

`"trash bin"` answered conversationally. Two enabled runnable commands match it —
built-in **Empty Trash** and a user-added one — and neither ran.

Two matchers read the same command list at different thresholds:

| | Gate | `"trash bin"` |
|---|---|---|
| `GlobalCommandCapabilities.hasSemanticMatch` | keyword score ≥ 4, no verb needed | **matches** |
| `GlobalCommandCapabilities.explicitRunMatch` | verb prefix (`run `/`execute `/`open `/`start `/`launch `) **and** the literal command name in the query | no match |

`AIRequestClassifier` uses the first and classifies the turn `.scopedTask` under a comment
saying such phrases "must enter discovery instead of falling through to provider chat".
The dock's only deterministic execution path uses the second, so it falls through anyway.
`explicitRunMatch` also ignores keywords entirely: `"run trash"` fails because the command
is named *Empty Trash*.

**Deeper cause, found while fixing.** `GeneralAIActionResolver` had no reference to
`GlobalCommandCapabilities` or `SystemCommandsRegistry` anywhere — the deterministic route
finder knew adapters, cached menus, Shortcuts, CLI and MCP, and nothing about the user's own
installed commands. `explicitRunMatch` was a bolt-on that existed because of that blindness.
`resolve()` bailed at its first guard (`verbShaped || nounShapedTarget != nil`) before any
lookup ran.

**Fixed.** The bail now consults the user's commands before returning `.none`, and offers
them as candidates rather than running one — a phrase with no verb proves what the user
meant, not that they want it carried out, and a tie between a built-in and a user command
should not be settled alphabetically on a list containing Empty Trash. Picking one still
passes the approval card, since script commands are classified high risk. Read-shaped
phrasing is excluded outright, because the keyword scorer strips "what" before scoring and
so cannot tell `"what's in my trash bin"` from `"trash bin"` on its own.

### 9b. An invented tool envelope is printed at the user · **fixed**

The model replied `{"trash_bin_action":{"action":"empty"}}` and that string became the
answer. `GeneralChatCapabilityHub` already documents this failure for the form
`{"globalcmd.empty-trash":{}}`, and its safety net keys on
`CapabilityRegistry.shared.capability(id:) != nil` — so it catches invented envelopes whose
key is a real capability id. `trash_bin_action` is not one, so nothing handled it.

A parsed JSON object that resolves to no capability should never be shown as prose.

**Fixed in the one place that was wrong.** The last line of defence already existed —
`AIMessageViews.presentable()` replaces protocol-only content on every assistant bubble —
and it did not fire because `ChatAnswerSanitizer.isProtocolOnly` returned false.
Its structural test accepted a `*_call` suffix or a dotted capability id, and
`trash_bin_action` is neither.

A third test now catches it: one top-level key, an object underneath it, and a word in the
key that describes *doing* something rather than *being* something. `{"server":{"port":…}}`
remains an answer; `{"trash_bin_action":{…}}` does not. Keys are split on case boundaries as
well as separators, because models write both `run_tool` and `runTool` — a gap the tests
caught, not the review.

### 9c. A create request answered by a read · **fixed**

`create a reminder "to call sujith" today at 5pm` → **"You have no open reminders."**
A write intent selected a reader. `reminders.create` exists and is one of the seven
capabilities with a real read-back verifier (§3), so this is route selection, not coverage.

**Cause.** `readOnlyDataDomain` classified it `.reminders`: `"today"` is on its read-signal
list and `"reminder"` maps to the domain. Nothing asked whether the sentence also commands.
The read router runs deliberately *before* executable routing — its comment says "so
personal-data reads don't get misclassified as actions" — so a reminders **write** was
answered by a reminders **read** before the resolver ever saw it.

**Fixed** with the vocabulary fix 2 introduced rather than a third list, which is the §9a
mistake in different words. `GeneralAIActionResolver.requestsChange` is now the one test for
"this sentence asks for a change", used by both the tool-loop write guard and this router.
Matched as whole words: a contains-check on `save` reads `"show me my saved notes"` as an
instruction.

The classifier moved to `ReadOnlyDataRouter` to be testable at all. It had been a method on
`LauncherView` — a view with four hundred `@State` properties — so the one decision that
routes a request between "read this" and "do this" could not be exercised without standing
up the surface, and the only thing that could catch it deciding wrong was a person typing
the sentence. Verified by removing the guard: two of the new tests fail without it.

### 9d. Dead field

`AIIntentResolution.requiredCapabilityKinds` is written at six sites and read at none.
System commands are additionally tagged `.appData` — a read kind for something that
executes — which is inert only because nothing consumes the field.

### 9e. The approval card printed the model's sentence as its own · **fixed**

Asked `what's in my trash bin`, the model called the Empty Trash capability with the
explanation *"List the contents of the trash bin."* The card rendered:

> **Empty Trash — Empty the Trash** · High
> *List the contents of the trash bin.*

Two lines, two authors, one voice. `ApprovalRequest.purpose` was documented as "why it
wants to, **in the requester's words**" and on every AI path the requester is the model, so
model-authored text sat where a description belongs — inside the last gate before a
destructive action. Approving it emptied the trash.

**Fixed.** `purpose` split into `subtitle` (facts DoraX knows) and `requesterClaim` (the
requester's words, always introduced and quoted). A capability card's factual block now
leads with the capability id, because a title does not always identify the action: a Global
Command's title is whatever the user named it, so one called "List Trash Contents" wrapping
an empty-trash script would read as harmless in every other line of the card.

**Also fixed.** Nothing stopped a `.high` write being *chosen* to answer a read-shaped
question. The `looksReadOnly` guard added for §9a covered the resolver only; the agent tool
loop calls `run_capability` directly and checked authority and risk, never intent.
`AgentToolContext` now carries `userRequest`, and a write is refused when
`GeneralAIActionResolver.asksOnly` holds — stricter than `looksReadOnly`, because a mutating
verb anywhere in the sentence disqualifies it. "show me my reminders then delete the
completed ones" is read-shaped and plainly also an instruction; refusing there would be the
guard misreading the user rather than protecting them.

### 9f. Global Extensions are invisible to the AI

Global **Commands** reach the AI: `GlobalCommandCapabilities.register` publishes every
enabled, runnable one as a `globalcmd.<slug>` capability, so the model can call them through
`run_capability`, `explicitRunMatch` catches an explicit "run <name>", and since §9a the
resolver offers keyword matches. Commands the user writes themselves are included — nothing
distinguishes them from built-ins.

Global **Extensions** — the panel kind, both the built-ins (Process Monitor, Top Memory,
Listening Ports, Scratch Notes) and anything created through *Add Extension* — are not
exposed at all. `UserGlobalExtensionStore` has zero references anywhere under
`Context-Dock/AI/`. An extension owns a rows script and a row-action script, which is a
shape the capability model has no equivalent for: it lists, then acts on a chosen row.

Two exclusions from commands are deliberate: `provider:notepad` and `provider:windows`
carry placeholder scripts with nothing to run.

### 9g. A verified write reported as a failure · **fixed**

`create a reminder "call sujith" today at 5 pm` created the reminder. EventKit confirmed it
and the receipt read *I've added reminder "call sujith"* — the §3 read-back doing exactly its
job. The model then verified for itself, chose
`verify_outcome(file_contains, ~/Library/Reminders/Reminders)`, was told the text was not
there, and answered: *"The reminder was not successfully created."*

Two failures met.

**The model had no reason to stop.** `run_capability`'s `.verified` branch returned the
refined message and nothing more. The *menu* path already appends "This is the result — do
not look for further evidence", under a comment recording this precise failure: told only
that a click was sent, a model went looking for its own evidence, checked a guessed path,
and announced the app was not installed while its About window stood open. The lesson was
learned on one path and never applied to the other.

**The check it chose could not be performed, and said it failed.**
`~/Library/Reminders/Reminders` is a directory holding a SQLite store.
`String(contentsOfFile:)` returns nil, so `passed` was false and the observation read "does
not contain the expected text" — the same collapse as `contradicted` vs `unverified` in §4b,
one level down inside the tool. `file_contains` and `file_equals` now report a missing path,
a directory and unreadable bytes as checks that prove nothing.

### 9h. An input key nobody declared, dropped in silence · **fixed**

`remind me to call sujith at 5pm today` created a reminder with **no due date**. The
approval card showed the arguments plainly — `date: 2026-08-20T17:00:00+01:00` — and
`reminders.create` declares `dueDate`. The undeclared key was dropped, the reminder was
created undated, and every check afterwards then told the truth about a different thing:

| Check | Said | Was right about |
|---|---|---|
| `verifyCapability` read-back | verified | it exists, matched by title |
| `reminders.today` | none due today | it has no due date |
| the model | "was not successfully added" | nothing |

Required fields were validated; misspelled optional ones simply vanished. `run_capability`
now refuses a call naming inputs the capability does not have, lists the names it does take,
and says nothing ran — a refusal that does not name the right field only buys another guess,
and the guess is what produced the undated reminder.

Scoped to the model's path deliberately. Internal Swift callers are typed; the model is the
one inventing key names.

### 9i. The model treats its own guess as verification

Two behaviours, one cause: `verify_outcome` is a tool the model may point anywhere, and it
reads the result as authority.

It **narrates** the plumbing — an answer ended *"The outcome verification is successful."*,
which is the model reading its own tool output back to the user as prose. Same family as
§9b: protocol reaching the user, in English rather than JSON.

It **overrides** a real read-back. §9g put "This is the result — do not look for further
evidence" on the verified branch, and in the run after that the model still called
`verify_outcome` on a guessed path. The instruction is requested, not enforced. What stopped
the wrong answer was §9g's second half — an unreadable path now reports that it proves
nothing — not the instruction.

Worth considering: refusing `verify_outcome` outright for the rest of a turn once a typed
read-back has already verified the write. There is nothing left for it to establish.

### 9j. The Brain stores assistant output as the user's notes

`show me my saved notes` returned, among five:

> 3. *"I can't see or access your current Safari page — I only work with your notes here,
>    not the web or other apps."*

Plus two `(empty)` entries. That is a refusal DoraX produced, filed as something the user
wrote, and it will be retrieved later as if they had. Two of the memory files on disk are
the same shape: `5a9cb05b-i-can-t-see-or-access-your-current-safari-page-i.md`,
`7beb04af-i-cannot-undo-actions-or-run-commands-i-can-help.md`.

Belongs to the memory work landed in `09aad81` / `68ff290`, not the control plane. Recorded
because a memory layer that saves the assistant's apologies compounds them.

### 9k. Permissions reports Not Authorized for access that works

Settings → Permissions shows Reminders, Photos, Contacts and Automation as **Not
Authorized**, and Request Access produces no system prompt. Meanwhile `reminders.create`
writes through EventKit and `AppleAppsAPI.getReminders` reads back successfully in the same
session — so something is authorised that the screen says is not.

Eliminated with evidence: missing `NS…FullAccessUsageDescription` (both ship, from
`INFOPLIST_KEY_*` build settings), sandbox entitlements (`addressbook`, `calendars`,
`photos-library` all present; the app is not sandboxed), TCC signature mismatch across the
three installed copies (all signed by the same Apple Development certificate), and wrong API
for macOS 14+ (`requestFullAccessToReminders()` is correct).

The button read "Request Access", so `canPrompt` was true and the status was
`notDetermined` — the request is made and macOS stays silent. Remaining suspect is the
concurrency guard in `SystemDataSearchManager.requestRemindersPermission`: if
`isRequestingRemindersPermission` is ever left set, later calls spin and return false
without reaching EventKit. Instrumented either side of the call; the log will show a
`reminders request begin` with no matching `end`.

---

## 10. What is left

Ordered. Each line says what it costs and what it unblocks.

### 10a. The shared executor's approval contract · **fixed**

`GeneralAIActionExecutor` assumes its caller already asked the user. Four places say so:

```
:137  approved: true
:412  approved: true
:426  action.requiresApproval = false   // "General Chat already showed its own approval"
:745  approved: true
```

That is true of General AI, which raises its own route-specific card before calling. It is
not a property of the executor, it is a property of one caller — and nothing in the
signature says so. Any second surface routed into it inherits "already approved" for free.

It was worse than the comment suggested. The gate itself — check the standing grant, raise
the card, honour a cancel — was **copy-pasted into four callers**, all of them in
`LauncherView+GeneralAIActions.swift` (`:616`, `:785`, `:1061`, and a read-only variant at
`:1649`). The executor had no gate at all. And `GeneralAIActionApprovalCard()` is rendered
at exactly one place, `LauncherView+AIChat.swift:1811`, inside the `aiMode` block — so a
caller on any other surface would not merely skip the gate, it would have nowhere to draw
the card even if it tried.

**Fixed.** `execute(_:approval:)` now takes an `ExecutionApproval` with **no default**:

```swift
enum ExecutionApproval {
    case granted(GrantSource)   // .approvalCard | .userPickedButton | .accessPolicy
    case ask                    // executor raises the card itself and waits
}
```

- The gate moved into `execute`. `.ask` checks the standing grant, raises the card, and
  returns `.cancelled(routeLabel:)` on a refusal.
- `GeneralAIActionResult.wasCancelled` separates "the user declined" from "the route ran
  and failed". Showing one as the other reads as DoraX breaking when it obeyed.
- `AIAuditHistory` now records *which* yes each execution ran on
  (`[approved via approval card]`), so a caller claiming an approval it never collected is
  visible after the fact instead of indistinguishable from one that did.
- `GeneralAIActionExecutor.requiresPrompt(_:permissionKey:)` is pure and static, so the
  gate is testable without a window — `ExecutionApprovalTests`, 9 tests, mutation-checked
  (deleting the standing-grant branch fails 2 of them).
- All six call sites now state their source: `.userPickedButton` for a picked route,
  `.approvalCard` where the caller genuinely raises one, `.accessPolicy` for the agent's
  menu tool (gated by `AppAccessPolicy`, not re-asked per click), and `.ask` from
  `runCompoundStep`, which has no progress strip to sequence around a prompt.

`.ask` is exercised in production by that last one, so 10b is not the first user of an
untested path. The two General AI sites that keep their own card keep it deliberately:
they sequence `actionProgress` and `loadingStatus` around the prompt, and a single
`execute` call cannot change the status line while the card is up.

### 10b. Context Dock Chat through the shared executor — Gate A's last row

Blocks three recorded items at once: §5 (one executor), §7 step 3 (`verifyCapability`
unusable there because `ChatRoute` carries an action id or menu path, never a capability id
with inputs), and §5 again (`TaskRunStore` never reaches that path).

The conversion itself is mechanical — every `ChatRoute.Kind` maps onto an `ExecutionRoute`
and a payload:

| Kind | Route | Payload |
|---|---|---|
| `.cli` | `.cli` | `inputValues["command"]` |
| `.adapterAction` | `.adapter` | `adapterActionID` + `bundleID` |
| `.menuCommand` | `.verifiedMenu` | `menuPath` split on `\u{1}` |
| `.mcpTool` | `.mcp` | `inputValues["mcpServer"]`, `["mcpTool"]` |

What is not mechanical, and would each be a regression if missed:

1. **Approval.** Handled by 10a, but not automatically: `execute(_:approval:)` has no
   default, so the Context Dock call has to state a source. `.ask` is the right answer for
   a surface with no card of its own — and it obliges Context Dock's chat view to render
   `GeneralAIActionApprovalCard()`, which today only `LauncherView+AIChat.swift:1811` does,
   inside the `aiMode` block. Without that one line the request sits for 60 seconds and
   comes back cancelled.
2. **The CLI terminal branch.** `ChatRouteResolver.run` diverts commands that need a TTY into
   the thread's own terminal. The shared executor has no such branch, and running one
   through `terminal.runCommand` is the bug already recorded there: a working
   terminal-browser became a two-and-a-half minute timeout.
3. **Adapter query context.** `ChatRouteResolver` passes the user's `query` into
   `AppAdapterManager.execute`; the shared executor passes the candidate's title.

### 10c. Route vocabularies — §4c

`ChatRouteResolver.Kind` is still unrelated to `ExecutionRoute` and
`GeneralChatWorkflowResult.Route`. 10b introduces the mapping for the first two; the third
stays a separate axis by design.

### 10d. Open bugs, in the order they cost a user something

- **9k** — Permissions reports Not Authorized for access that works. Instrumented; waiting on
  one click to read `reminders request begin` / `end` from the log.
- **9i** — the model narrates `verify_outcome` and still runs it after a typed read-back has
  verified. Consider refusing it for the rest of a turn once a write is verified.
- **9j** — the Brain files assistant output as the user's notes. Belongs to the memory work.
- **9f** — Global Extensions invisible to the AI. A feature: the capability model has no
  shape for "list rows, then act on a chosen row".
- **9d** — `requiredCapabilityKinds` written at six sites, read at none. Inert; delete it.

### Not doing

Bounded loops, graph orchestration, scheduled autonomy, multi-agent. Gate A first, and with
10a done Gate A is 10b alone.

