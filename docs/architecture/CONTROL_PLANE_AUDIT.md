# DoraX control-plane audit

Read-only inventory of how an executable request travels from intent to receipt today.
No code changed. Produced as **Gate A** input: nothing about bounded loops, graph
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
| `cli` | **denied** | — | only via capability ID | `skipped` otherwise |
| `shortcutRunner` | **denied** | — | none | `skipped` |
| `automation` | **denied** | — | none | `skipped` |

`GeneralAIActionExecutor.verify(_:)` `default:` → `.skipped` for the bottom six rows.

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

### 4a. Receipt — three types, one shape

All three wrap `AIProviderService.ExecutedCommand`. Fields are effectively identical.

| Type | File | Persisted |
|---|---|---|
| `TaskRunStore.Receipt` | `AI/TaskRunStore.swift:18` | yes (JSON, `+recordedAt`) |
| `GeneralChatWorkflowResult.Receipt` | `AI/GeneralChatWorkflowResult.swift:42` | no |
| `EvidenceReceipt` | **`Search/AIMessageViews.swift:538`** | no |

`GeneralChatWorkflowResult.Receipt` and `EvidenceReceipt` are field-for-field the same
struct. One lives in the AI layer, one in a **view file**. Receipt shape is currently
defined by a presentation type.

### 4b. Verification — three vocabularies

| Type | Cases |
|---|---|
| `GeneralAIActionExecutor.VerificationOutcome` | `verified` / `unverified` / `skipped` |
| `GeneralChatWorkflowResult.Verification` | `verified` / `executorConfirmed` / `unavailable` / `failed` |
| Context Dock Chat | untyped `String?` state dump, always recorded `success: true` |

Mapping between the first two is lossy in both directions. `skipped` (no verifier exists)
and `unverified` (verifier ran, could not confirm) both have to land somewhere in the
four-case enum, and neither `unavailable` nor `failed` is an obvious home. There is no
`contradicted` case anywhere: "the verifier ran and proved the write did **not** land" is
currently expressed as `unverified` — the same value as "we did not check."

### 4c. Route — three enums on three different axes

| Type | Axis | Cases |
|---|---|---|
| `DoraXActionCandidate.ExecutionRoute` | execution mechanism | 10 |
| `GeneralChatWorkflowResult.Route` | turn classification | 12 (`conversation`, `liveState`, `memory`, `selection`, …) |
| `ChatRouteResolver.Kind` | Context Dock offer | 7 (`cli`, `adapterAction`, `menuCommand`, `mcpTool`, `skill`, `model`, …) |

These are not redundant — they answer different questions — but nothing declares the
mapping, so `adapterAction` → `.adapter` → `appAdapter` is re-derived per call site.

---

## 5. Surface parity

Three things execute. They do not agree.

| | General AI (candidate path) | Agent tool loop (`run_capability`) | Context Dock Chat |
|---|---|---|---|
| Entry | `GeneralAIActionExecutor.execute` | `AgentToolRegistry.swift:1480` → same executor | `AppScopedChatService.execute` → `ChatRouteResolver.run` |
| `AppAccessPolicy` | yes | yes (`:1290`, `:1346`, `:1470`) | **no** |
| `GeneralAIActionExecutor.verify` | yes | yes (`:1491`, `:1624`) | **no** |
| Verification method | typed read-back | typed read-back | re-resolve `ContextResolver…promptBlock()` → prose |
| `TaskRunStore` tracking | via provider service | via provider service | **no** |
| Receipt type | `GeneralChatWorkflowResult.Receipt` | same | `EvidenceReceipt` |

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
| Authority classification | **met for two of three surfaces** — Context Dock Chat bypasses `AppAccessPolicy` |
| Canonical executor | **met for two of three surfaces** — Context Dock Chat runs `ChatRouteResolver` |
| Verification state | **not met** — 6 of 10 routes `skipped`; 3 incompatible vocabularies; no `contradicted` |

**Gate A is not open.**

---

## 7. Narrowest change that opens Gate A

Ordered. Each is independently shippable. None touches UI, the resolver, the capability
registry, Global Context, or the typing path.

1. **Collapse the receipt.** One `DoraXActionReceipt` in the AI layer. Delete
   `EvidenceReceipt` from `AIMessageViews.swift`; make `GeneralChatWorkflowResult` and
   `TaskRunStore` use the shared type. Mechanical — the three shapes already match.

2. **One verification vocabulary.** Single `VerificationStatus`:
   `verified` / `contradicted` / `unverified` / `notApplicable`.
   - `contradicted` is new and load-bearing: the verifier ran and disproved the write.
   - `unverified` = verifier ran, inconclusive.
   - `notApplicable` = no verifier exists for this route (today's `skipped`).
   Never let an executor success promote itself past `notApplicable`.

3. **Route Context Dock Chat through the shared gate.** Add `AppAccessPolicy` before
   `ChatRouteResolver.run`, and call `GeneralAIActionExecutor.verifyCapability` for
   non-read-only routes instead of the prose state dump. Keep the state dump as
   *additional* evidence; it stops being the verification.

4. **Extend verification to the six `skipped` routes** where a cheap read-back exists.
   `shortcutRunner` and `automation` likely stay `notApplicable` — say so explicitly
   rather than by falling through a `default:`.

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
