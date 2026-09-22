# 04 — General AI Chat (AI Assistant Mode)

> **Status: DRAFT / under review — written against current code (audit-clean).** Not merged yet.
> Tags: `[code]` verified in source · `[owner]` owner's stated knowledge · `[?]` needs confirmation.
>
> **Names for the same thing:** "General AI Chat", "AI Assistant Mode", "DoraX Action Chat",
> the `.general` scope. This doc uses **General Chat**.

---

## 0. The one honest sentence

**General Chat is App-Scoped Chat (`03`) with `scope = .general` and a smarter front-end.**
`[code]` `GeneralChatWindowModel.send()` calls the *same* `AppScopedChatService.send(...)`
entry (`GeneralChatWindowModel.swift:923`) — so the tool loop, planner, tool-less engine,
verifiers, approval, and `ScopedTurnRunner` are **identical** to `03`. What is different is
everything that happens *before* the engine: General Chat has no app in front of it, so it
must **figure out which apps a request even touches**, resolve routes across all of them, and
gate access. That front-end is this doc.

---

## 1. Goal — what General Chat is *for*

From `PRODUCT_LAYERS.md`: **the system-wide AI workflow layer.** `[code]`
- System-wide questions, app discovery, cross-app workflows, and conversational fallback when
  no local capability is relevant.
- **Visible** attachments and context; user-controlled provider/profile.
- Rules: **not** a launcher, **not** the frontmost-app command sheet. Installed apps inform
  capability discovery but **do not silently grant access**. Execution requires a **typed
  route, appropriate approval, and an honest result**.

Plainly: *"Ask DoraX anything across your Mac; it works out which apps are involved, does the
cross-app workflow, and never pretends."*

---

## 2. What the user sees / does `[code — GeneralChatWindowModel.swift]`

- A chat with **no fixed app** (`activeScope = .general`).
- **Attachments** (`attachments: [URL]`) — visible files added to the question.
- **Attached apps** (`attachedAppNames`) — the user can scope a general thread to one or more
  apps (e.g. Reminders + Safari); 2+ becomes a **Combined chat**.
- **Per-message app memory** (`messageApps`) — the transcript keeps showing what each question
  was asked *about*, even after the scope changes ("today's scope on last week's question
  would be a lie").
- **Per-thread in-flight** (`sendTasks`, `sendingScopeKeys`) — one thread's send is never
  cancelled by switching threads.
- **Live progress** (`statusByScopeKey`, `progressByScopeKey`) — a running status checklist
  per scope while the turn works.

---

## 3. Scope & storage `[code — GeneralChatSessionStore.swift]`

- Scope: `.general` (also `.thread` for named threads). Storage key `general` →
  `GeneralAIChatConversationStore` (UserDefaults, `dorax.generalAI.session.general.v1`).
- `GeneralChatSessionStore` is the index/router (sidebar list, attached-apps per thread).
- The `.general` conversation is **shared with the result sheet** — same conversation, two
  views (`CHAT_SCOPES.md`).

---

## 4. The distinctive front-end (this is what makes General Chat *General*)

App-Scoped Chat knows its app. General Chat does not, so it adds these stages **before** the
shared engine runs. All `[code]`:

| Stage | File | What it does |
|---|---|---|
| **Scope resolution** | `GeneralChatScopeResolver.swift` | Infers *which apps* a request touches when it names none — "where are my invoices?" → Mail / Files / Notes — instead of making the user pick first. |
| **Cross-app clarifier** | `CrossAppGeneralChatClarifier.swift` | Stops an incomplete cross-app statement from being treated as a live lookup; asks the missing operation/app before reading either app. |
| **Action resolution** | `GeneralAIActionResolver.swift` | Decides if the query is an **executable** request and looks up real routes across *all* sources: registered capabilities, app adapters, warm menu cache, keyboard shortcuts, Shortcuts catalog, CLI manifests. |
| **Capability hub** | `GeneralChatCapabilityHub.swift` | Exposes **every enabled adapter's MCP tools + saved app-scoped histories** to the general tool loop, so the model picks the right app's tools itself. Cached 300 s, keyed by what the block was built *from* (so a Notes-only block isn't reused for a different app's question). |
| **Local evidence** | `GeneralChatLocalEvidence.swift` | Query-grounded retrieval of what is **actually on this Mac for this question** — the anti-hallucination ground truth, so app answers don't come from model training data (invented menus/files). |
| **Capability gap** | `CapabilityGap.swift` | Honest "the app is right and nothing it has can answer this" — e.g. a hand-made adapter has *actions* but no *reader*. Fills the silence the model would otherwise invent into. |
| **Action execution** | `GeneralAIActionExecutor.swift` | Executes a resolved `DoraXActionCandidate`; **approval is mandatory in the signature** (no default), validates before acting, and only reports success on a real executor success. |
| **The brain (legacy hub)** | `L2UnifiedAssistant.swift` | Older "connect Context/Terminal/AI/Files/Photos/Contacts/Calendar/Reminders" NL-workflow layer. `[?]` how much still lives on the hot path vs superseded by the resolver — flag for audit. |

---

## 5. Access gate — safety (no silent grants)

`[code — AppScopedChatService.appNeedingAccess, AppAccessPolicy, GeneralChatWindowModel.swift:450]`

- General Chat may **know** an app exists and name it, but touching its data/actions needs a
  grant. When a request needs an app that isn't enabled, `appNeedingAccess` raises a one-tap
  **"Enable \<app\> for this chat"**; enabling attaches the app and re-asks the question.
- That grant is real authority (`chatGranted`) and is honored consistently by both the route
  resolver and capability discovery — the same 3-level `AppAccessLevel` model as `03` §6.
- Installed ≠ permitted: discovery informs; it does not grant. `[code — PRODUCT_LAYERS.md]`

---

## 6. Shared execution engine (identical to `03`)

Once the front-end has a scope, routes, and grants, execution is **the same** as App-Scoped
Chat — see [`03-APP-SCOPED-CHAT.md`](03-APP-SCOPED-CHAT.md) §7 / §7b / §7c / §10 / §11:
- Reactive tool loop, plan-and-execute DAG planner, and tool-less prose loop.
- Per-turn tool budget, durable receipts (`TaskRunStore`).
- Verifiers (`AgentAnswerVerifier`, `CommandOutcomeVerifier`).
- One approval inbox (`ApprovalCenter`); `refusesChanges` / `allowedToolNames` authority
  envelope.
- Vision, streaming, `ScopedTurnRunner`.

**Not repeated here on purpose** — one engine, documented once.

---

## 7. Providers

Same multi-provider set as `03`, **user-controlled per profile** (General Chat is the surface
where the user most visibly chooses the model). `AITokenLedger` records cost;
`AnthropicPromptCache` caches the prefix. `[code]`

---

## 8. Engineering map (General-Chat-specific files)

| Concern | File |
|---|---|
| Window model / view state | `AI/GeneralChatWindowModel.swift` |
| Scope inference | `AI/GeneralChatScopeResolver.swift` |
| Cross-app clarify | `AI/CrossAppGeneralChatClarifier.swift` |
| Executable-route resolution | `AI/GeneralAIActionResolver.swift` |
| Route execution | `AI/GeneralAIActionExecutor.swift` |
| Cross-app capability exposure | `AI/GeneralChatCapabilityHub.swift` |
| Local ground-truth retrieval | `AI/GeneralChatLocalEvidence.swift` |
| Honest capability-gap replies | `AI/CapabilityGap.swift` |
| Legacy NL-workflow hub | `AI/L2UnifiedAssistant.swift` |
| Workflow result shaping | `AI/GeneralChatWorkflowResult.swift` |
| Index / storage routing | `AI/GeneralChatSessionStore.swift`, `GeneralAIChatConversationStore` |
| Shared engine | see `03` engineering map |

---

## 9. Boundaries

- **Not a launcher** (that's Global Context, `01`).
- **Not the frontmost-app command sheet** (Context Dock command layer, `02`).
- **Not App-Scoped Chat** — but shares its engine; the difference is scope + front-end.

---

## 10. Known gaps / open questions (to resolve with owner)

1. **Two resolvers of overlapping intent.** `GeneralAIActionResolver` (route lookup) and the
   older `L2UnifiedAssistant` ("the brain") both claim cross-source workflow routing. Which is
   authoritative on the hot path today? Dead code is a lie waiting to happen. `[?] [gap]`
2. **Scope inference is unmeasured.** `GeneralChatScopeResolver` guesses which apps a request
   touches — a wrong guess sends the whole turn at the wrong app. No eval covers this, and it
   is the single most General-Chat-specific failure mode. `[gap]`
3. **Same missing pieces as `03`:** no capability *graph* (flat route lookup) and no offline
   **eval** for route/scope/answer quality. General Chat's extra inference stages make the
   eval gap *worse*, not better. `[gap]`
4. **Capability-hub cache correctness.** 300 s TTL keyed by "what it was built from"; a stale
   or mis-keyed block can tell the model an app has no tools when it does. Correctness under
   fast app-enable/disable is `[?]`.
5. **Local-evidence coverage.** `GeneralChatLocalEvidence` is the anti-hallucination floor; how
   many app/data types it actually retrieves for (vs. falls back to "capability prompt only")
   is undocumented. `[?]`
6. **No success metric** — no measure of "did General Chat pick the right app(s) and do the
   right thing on the first try." `[gap]`

---

*End of draft. Redline directly; merges into `docs/architecture/` only after owner
confirmation.*
