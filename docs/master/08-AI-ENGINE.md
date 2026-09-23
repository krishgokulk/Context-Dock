# 08 — The AI Engine

> **Status: DRAFT / under review — written against current code (audit-clean).** Not merged yet.
> Tags: `[code]` verified in source · `[owner]` owner's stated knowledge · `[?]` needs confirmation.
>
> This is the shared machinery **every** chat surface calls (`03` app-scoped, `04` general,
> and the result-sheet paths). Documented once here; the surface docs reference it.

---

## 1. The engine in one pass

```
request (surface + scope + provider + attachments)
  → AIProviderRouter            mode: answer | plan | execute | explainResult
  → grounding                   ScopedAppPromptBuilder / General front-end (03,04)
  → classify                    AIRequestClassifier.requiresPlanning?
  → ONE of three execution paths:
        A. reactive tool loop   (native-tool providers)      sendWithTools
        B. plan-and-execute DAG (multi-step)                 ChatPlanRunner
        C. tool-less prose loop (Apple Intelligence, Claude Code)  runToolLessScopedTurn
  → tools                       AgentToolRegistry (run_capability, run_menu_command, …)
        under: tool budget + durable receipts (TaskRunStore)
        under: authority envelope (allowedToolNames, refusesChanges) + access levels
        under: approval (ApprovalCenter)
  → verification                AgentAnswerVerifier + CommandOutcomeVerifier + verify_outcome tool
  → answer + receipts           → cost recorded (AITokenLedger, AnthropicPromptCache)
```

Everything below expands one box. `[code]`

---

## 2. Providers (11) and the native-tools split

`[code — AppSettings.swift:699–760]` `AIProvider`:

| Provider | Reached via | Native tools? |
|---|---|---|
| `onDevice` (Apple Intelligence) | `FoundationModels` / `OnDeviceToolSession` | **No** → path C |
| `anthropic` (Claude) | HTTP + `AnthropicToolProviderAdapter` | Yes |
| `openAI` (ChatGPT) | HTTP + `OpenAIToolProviderAdapter` | Yes |
| `googleGemini` | HTTP + `GeminiToolProviderAdapter` | Yes |
| `ollama` | local HTTP (OpenAI-compatible) | Yes |
| `openAICompatible` | HTTP | Yes |
| `kimi` | HTTP (OpenAI-compatible) | Yes |
| `claudeBridge` / `chatGPTBridge` | local bridge endpoint | Yes |
| `claudeCode` (CLI) | `ClaudeCodeCLIService` | **No** → path C (agent with its own tools) |
| `shortcuts` | macOS Shortcuts | **No** → path C |

**The split matters:** `supportsNativeTools` decides whether a request takes the tool loop
(A/B) or the tool-less prose loop (C). Apple Intelligence and Claude Code get **none** of
DoraX's tools by design — "they answer; the app acts." `[code]`

---

## 3. The router

`AIProviderRouter` `[code — AIProviderRouter.swift]`
- **Modes:** `answer`, `plan`, `execute`, `explainResult`.
- **Sources:** `globalContext`, `contextDock`, `mediaDock`, `aiChat`, `extensionSystem`,
  `workflow` — so the engine knows which surface asked.
- `sendPrepared(...)` dispatches a prepared request to the chosen provider's adapter.
  On-device and `claudeCode` take their own paths (no HTTP endpoint to point at).

---

## 4. The three execution paths (detail lives in `03`)

- **A — reactive tool loop** (`AIProviderService.sendWithTools`): send → model emits a
  tool_call → execute → feed result back → repeat up to `maxIterations`. Per-provider
  transport adapters normalize each API's tool-call format.
- **B — plan-and-execute DAG** (`ChatPlanRunner`): for multi-step requests, the model orders
  **pre-resolved route ids** into a DAG; a hallucinated step is a rejected id. Runs with
  per-step authorization. A completed plan is saveable as a `WorkflowRecipe`.
- **C — tool-less prose loop** (`runToolLessScopedTurn`): a "ask → run → re-ask" loop over the
  capability catalogue for providers with no function-calling API.

See [`03-APP-SCOPED-CHAT.md`](03-APP-SCOPED-CHAT.md) §7/§7b/§7c.

---

## 5. The global tool registry

`AgentToolRegistry` — "registered, executable, and impossible for a model to call unless
listed." `[code — AgentToolRegistry.swift]` Registered tools include:

| Tool | Purpose |
|---|---|
| `run_capability` | run any registered capability by id (unknown id → treated as a change → app-action fallthrough) |
| `find_capability` | search the capability index for a matching route |
| `run_adapter_action` | run a saved App Adapter action |
| `run_menu_command` | fire an app menu item by full path |
| `run_mcp_tool` | call a linked MCP server tool (read app data) |
| `run_command` | run a shell command (approval-gated) |
| `verify_outcome` | **model-callable verification** — read back whether an action worked |
| `read_tool_result` | re-read a previous tool's output |
| `read_attachment` | read an attached file |
| `window_control` | window management |
| `send_keys` | inject keystrokes into the frontmost app |
| `spawn_worker` | hand a sub-task to a worker (see §11) |
| `get_messages_conversations` / `search_messages` / `compose_message` | Messages |
| read tools (`registerReadingTools`) | fetch/read a page or file mid-turn |
| route tools (`registerRouteTools`) | route-execution helpers |

Tools are built in via `registerBuiltInsIfNeeded()`; MCP/adapter tools are added dynamically
per enabled app. `run_capability` is the catch-all that reaches every registered capability.

---

## 6. Budget, receipts, resume

`[code — TaskRunStore.swift, AgentToolRegistry.swift]`
- **Per-turn tool budget** — `prepareTurnBudget(query, provider, allowedToolNames,
  refusesChanges)` once per turn; `reserveToolCall(name)` refuses a call over budget and tells
  the model (rather than silently stopping).
- **Durable receipts** — `TaskRunStore.track/resolve`; a re-asked task reuses a cached
  successful command instead of re-running side effects.
- **`AIToolBudget`** — the budget model the registry trims to what the turn is about.

---

## 7. Authority envelope + access levels (safety, part 1)

`[code — AppAccessLevel.swift, AgentToolRegistry.swift]`
- **`allowedToolNames: Set<String>?`** — a restricted tool set for a turn; nil = unscoped.
- **`refusesChanges: Bool`** — read-only turns; enforced in code, because "a promise in a
  prompt is not a boundary."
- **Per-route access levels** — `awareness (0)` / `menuOnly (1)` / `adapter (2)`; authority is
  asked per route, not per app.

---

## 8. Verification & evaluation (the honest state)

**Runtime verification is real and layered; offline evaluation does not exist.** `[code]`

Runtime (all in the loop):
- **`AgentAnswerVerifier`** — rejects an answer claiming work no tool actually did (checks
  `AIAuditHistory`).
- **`CommandOutcomeVerifier`** — reads back whether a command *changed* anything (exit-zero ≠
  worked).
- **`verify_outcome` tool** — the model itself can verify an action mid-turn.
- **`FreshResultEvaluator`** — result freshness/relevance.

Offline eval (CORRECTION — an earlier draft wrongly said this was absent):
- **A large offline eval suite exists** — ~135 eval `@Test`s (of 1,167 total across 148 files):
  `AgentRoutingEvalTests` (38), `CapabilityIndexTests` (15), `RoutePreferenceEvalTests`,
  `CapabilityMatchEvalTests`, per-adapter `*AdapterEvalTests`, `PromptAssemblyEvalTests`,
  `ReadingToolEvalTests`. Route/scope/ranking are measured **per case**, offline. `[code]`
- **Thinner:** no **dataset-driven aggregate pass-rate** tracked release-over-release, and no
  memory-retrieval eval (`09` §7 #5). That aggregate metric is the real (smaller) gap. `[gap]`

---

## 9. Approval & untrusted content (safety, part 2)

`[code — ApprovalCenter.swift]`
- **One approval inbox** — `ApprovalCenter` unifies shell, capability, general-action and
  adapter-action approvals; identical on every surface. `GeneralAIActionExecutor.execute` takes
  a mandatory `ExecutionApproval` (no default) — a surface can't forget the gate.
- **Untrusted-content rule** — page text, file contents, and other external data are wrapped
  so injected instructions are treated as data, not commands.
- **Elevated-risk tools** — `send_keys` (keystroke injection) and `run_command` (shell) are the
  sharpest tools; they run behind approval. `spawn_worker` delegates to a worker (§11). These
  are the surfaces a security review should focus on. `[owner — review target]`

---

## 10. Cost, tokens, caching

`[code]`
- **`AITokenLedger`** — records every response's token counts (the numbers DoraX used to throw
  away), so a turn's real cost is visible.
- **`AIModelRateCard`** — prices are **entered by the user**, never baked in; a model with no
  rate shows tokens and no money rather than a made-up cost.
- **`AnthropicPromptCache`** — prefix-caches `tools → system → messages`; a breakpoint on the
  last system block caches tools+prompt together. Reads bill ~0.1× input; the 2–16-call tool
  loop shares one prefix, so it comes out ahead.
- **`AIContextBudget`** — relevance-ranked context fitting (semantic chunks scored against the
  query) instead of a blind `prefix(N)` cut, and it marks what was dropped.

---

## 11. Worker layer (`spawn_worker`)

`[code — tool registered; owner plan]` `spawn_worker` hands a sub-task to a worker (Claude
Code / Codex as specialist workers). The **broader "worker layer with an authority envelope"**
is the last item on the owner's `corner-general-chat-parity` sequence and is **in progress**,
not finished — so treat the tool as present but the surrounding contract as maturing. `[?]`

---

## 12. On-device specifics

`[code — OnDeviceToolBridge.swift, AIProviderService.swift]`
- `OnDeviceToolSession` runs `Tool`-conforming types against `FoundationModels`
  (`SystemLanguageModel` / `LanguageModelSession`), gated on macOS 26.
- Images are currently **OCR'd to text** before the model sees them; gen-3 native vision is
  the open adoption item (see `docs/reference/APPLE_FOUNDATION_MODELS_GEN3.md`).
- Availability must be checked at runtime; the OCR path is the correct degraded fallback.

---

## 13. Engineering map

| Concern | File(s) |
|---|---|
| Provider service + tool loop | `AI/AIProviderService.swift` |
| Provider routing | `AI/AIProviderRouter.swift` |
| Per-provider transports | `AI/Providers/*ToolProviderAdapter.swift` |
| Streaming | `AI/Providers/AIProviderStreaming.swift` |
| Planner | `AI/ChatPlan.swift`, `AI/WorkflowRecipe.swift` |
| Intent/plan classifier | `AI/AIRequestClassifier`, `AI/CapabilityFallbackClassifier.swift` |
| Global tool registry | `AI/AgentToolRegistry.swift`, `AI/ReadingTools.swift`, `AI/RouteTools.swift` |
| Budget / receipts | `AI/TaskRunStore.swift`, `AI/AIToolBudget.swift` |
| Verification | `AI/AgentAnswerVerifier.swift`, `AI/CommandOutcomeVerifier.swift`, `AI/FreshResultEvaluator.swift` |
| Approval / access | `AI/ApprovalCenter.swift`, `AI/AppAccessLevel.swift` |
| Cost / cache / context | `AI/AITokenLedger.swift`, `AI/AIModelRateCard.swift`, `AI/AnthropicPromptCache.swift`, `AI/AIContextBudget.swift` |
| On-device | `Services/OnDeviceToolBridge.swift` |
| Capability index | `AI/CapabilityIndex.swift` |

---

## 14. Known gaps / open questions (engine-wide)

1. **Eval: large per-case suite exists; no aggregate metric.** ~135 offline eval tests cover
   route/scope/ranking per case. Missing is a dataset-driven *pass-rate* tracked over releases
   (+ memory-retrieval eval). A refinement, not a missing foundation. (Earlier draft wrongly
   called eval absent — corrected.) `[gap]`
2. **No capability graph.** Routing is flat index + ranking; the planner orders a flat list.
   Graph reasoning is net-new work, not polish. `[gap]`
3. **Two intent brains** — `GeneralAIActionResolver` vs `L2UnifiedAssistant` (04 §10 #1). `[?]`
4. **Elevated-risk tools** (`send_keys`, `run_command`, `spawn_worker`) — the right target for
   a dedicated security review; approval is the only gate. `[owner]`
5. **OSLog is unreliable on the dev Mac** (per `CLAUDE.md`) — engine tracing leans on the app's
   own `turns.log`, not system logs. Worth knowing before debugging an engine turn. `[code]`
6. **Worker layer contract unfinished** (§11). `[?]`
7. **Verification coverage is per-effect** — `CommandOutcomeVerifier` only reads back effects it
   knows how to read; actions with no read-back are trusted. `[gap]`

---

*End of draft. Redline directly; merges into `docs/architecture/` only after owner
confirmation.*
