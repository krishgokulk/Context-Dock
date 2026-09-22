# 03 — App-Scoped Chat (Context Dock Chat Mode)

> **Status: DRAFT / under review.** Not merged into `docs/architecture/` yet.
> Tags: `[code]` verified in source · `[owner]` owner's stated knowledge · `[?]` needs confirmation.
>
> **Names for the same thing:** "frontmost app chat", "Context Dock Chat Mode",
> "app-scoped chat", the `.app(bundleId)` scope. This doc uses **App-Scoped Chat**.
> The non-chat **Context Dock command layer** (menus/actions sheet) is a *different* surface,
> documented later as `02-CONTEXT-DOCK.md` (still pending).

---

## 1. Goal — what App-Scoped Chat is *for*

**Talk to the app in front of you, and have it actually do the thing — through whatever
route that app exposes — with proof it happened, and one tap to link anything missing.**

This is the app's most defensible surface. Neither Siri nor Raycast does this: Siri can't
bring your own model or drive an arbitrary app's menus; Raycast can't run an agent loop over
an app's own actions + MCP + Shortcuts + CLI with outcome verification. The code already
reaches for this goal explicitly — see the tool-choice order (§5) and the "unlinked is not
impossible" rule (§5). `[code — ScopedAppPromptBuilder.swift]`

Sub-goals the code already encodes:
- **Per-app capability.** The chat knows what *this* app can do and prefers the app's own
  routes over generic shell.
- **Honest reach.** When nothing is linked, it proposes an approvable read-only command
  rather than saying "I can't."
- **Proof, not claims.** It verifies that a claimed action actually ran and actually changed
  something (§10).

---

## 2. What the user sees / does

- Opens a chat **scoped to one app** (the frontmost app, or a pinned/handed-off app scope).
- Asks in plain language ("add this to my notes", "minimize", "what changed in this file").
- The chat answers **or acts** — running the app's own action, its menu command, an MCP
  read, a Shortcut, or (last resort) a CLI/shell command behind an approval sheet.
- The same conversation is visible in the dock sheet and the full chat window — two views,
  one thread. `[code — docs/architecture/CHAT_SCOPES.md]`

---

## 3. Scope & storage model

`[code — CHAT_SCOPES.md, GeneralChatSessionStore, AppPanelChatStore]`

- **A conversation belongs to a scope, not a surface.** `scope = .app(bundleId)` here.
- **One store per scope:** `AppPanelChatStore`, file key `dock_app_<bundleId>`. A CLI scope
  (`.cli(command)`) uses `dock_app_cli://<command>`.
- **Shared, not copied:** the dock sheet and the chat-window row read the *same* file, so the
  window is a second view, never a drifting copy.
- `GeneralChatSessionStore` is the index/router: scope → store, sidebar list, and per-thread
  extra apps for combined chats.

---

## 4. Grounding — what the model is told about the app

Built by **`ScopedAppPromptBuilder.appIdentityBlock(...)`** — one builder, called identically
by every surface. `[code]` It assembles, per app:

| Grounding piece | Source | Purpose |
|---|---|---|
| Scope identity | scope | "this chat is about \<app\>" |
| **Adapter actions** | `AppAdapterManager.adapters[bundleId].actions` | the app's saved, runnable actions |
| **Verified menu commands** | `AppMenuCapabilityCache` (leaf items + shortcuts) | drive the app's real menu bar |
| **Linked MCP servers** | `MCPServerManager.servers(forBundleId:)` | read the app's data |
| **API connections** | (configured) | mention-only — NOT callable from chat |
| **macOS Shortcuts** | linked shortcuts | run a Shortcut |
| **Skills** | `SkillStore.skills(for:)` (enabled) | app-specific instructions injected |
| **CLI tools** | linked packages (trust-gated) | fallback route |
| Live window facts | `liveWindowFacts(bundleID:)` via AX | current window title/doc |
| Browser facts | `browserPageFacts` / `browserHistoryFacts` | page text/tabs/history for browsers |
| Menu evidence | `menuSnapshotEvidence` / `observedMenuFacts` | what the menu bar actually showed |
| Date/time | `dateTimeBlock()` | "today" resolves |
| Selection | `selectionBlock(_:)` | selected files/images in context |
| Untrusted-content rule | `UntrustedContent.rule` | prompt-injection guard on page/file text |

**Provisional CLI links are dropped unless the question names them** — a guess about which
CLI an app maps to is not a permission. `[code — promptRelevantCLIPackages]`

---

## 5. Tool-choice order (the decision policy)

Injected verbatim into the system prompt. `[code — ScopedAppPromptBuilder.swift]`

> **exact saved adapter action → verified live app menu → MCP/API for app data → Shortcut →
> linked CLI fallback → answer from live context.** Terminal/CLI is last resort; never
> generate shell/AppleScript for something the app's linked tools or live menu already do.

And the honesty rule that stops false dead-ends:

> **"Unlinked is not impossible."** When no linked route fits and a *read-only* command could
> answer the question, name the exact command and propose it — it goes to the approval sheet
> before running. Never end with "I can't" while an approvable read-only command exists.
> `[code]`

---

## 6. Per-app access model (authority) — safety

`[code — AppAccessLevel.swift]` Authority is **per route, not per app**, with three levels:

| Level | Meaning | What's allowed |
|---|---|---|
| `awareness (0)` | app exists, maybe running | know it, start it — nothing more |
| `menuOnly (1)` | cached menu bar, or a per-chat grant | public menu commands, **only after live verification** |
| `adapter (2)` | user added an App Adapter | readers, actions, MCP, CLI, skills, app data |

A per-chat "Enable \<app\> for this chat" grant is real authority (the user was asked in
words and said yes) and is honored consistently by both the resolver and discovery.

---

## 7. The tool loop ("loops")

`[code — AIProviderService.sendWithTools, AgentToolRegistry, TaskRunStore, Providers/*ToolProviderAdapter]`

```
prepareTurnBudget(query, provider, allowedToolNames, refusesChanges)
   │
   ▼
send → model emits tool_call → reserveToolCall(name)   ← per-turn tool budget
   │                              │ (budget reached → refuse this call, tell model)
   ▼                              ▼
execute route (adapter/menu/MCP/Shortcut/CLI)  → guarded executor
   │                              │ cached success? → resume from durable receipt
   ▼
feed result back → repeat up to maxIterations → final answer
```

- **Per-turn tool budget** (`TaskRunStore.reserveToolCall`) caps how many tools one turn may
  spend, trimmed to what the turn is about.
- **Durable receipts + resume** (`TaskRunStore.track` / `resolve`): a re-asked task reuses a
  cached successful command instead of re-running it.
- **Same loop for every provider** — OpenAI, Anthropic, Gemini, Ollama, OpenAI-compatible,
  Kimi, bridges. On-device (Apple) runs its own `OnDeviceToolSession` variant. `claudeCode`
  CLI answers with **no** DoraX tools by design (it acts through its own agent).

---

## 8. Per-app tools / "plugins" (what a route actually is)

`[code]` The named tools the model can call in an app scope:

| Tool | Does | Backed by |
|---|---|---|
| `run_adapter_action` | run a saved app action by id | App Adapters |
| `run_menu_command` | fire an app menu item by full path | AX menu cache |
| `run_mcp_tool` | read app data via a linked MCP server | MCPServerManager |
| `terminal_call` (typed JSON) | run a CLI command (fallback) | TerminalPackageManager + approval |
| macOS Shortcuts | run a linked Shortcut | Shortcuts |
| Skills | inject app-specific instructions | SkillStore |
| API connections | **mention-only**, not callable | (config) |

"Per-app plugins" in owner's words = **App Adapters + their linked MCP/Shortcuts/CLI/skills**.
The catalog shown in Settings and consumed by chat is the *same* registry
(`AppAdapterCapabilityCatalog` / `CapabilityRegistry`). `[code]`

---

## 9. "Graph engineering" — the honest state

**There is no per-app knowledge graph or reasoning graph in App-Scoped Chat.** `[code]`

What exists instead:
- **A capability *index*** (`CapabilityIndex` / `CapabilityRegistry`): "one index over
  everything DoraX can do, and one ranking for a given sentence." Matching is **token overlap**
  between the sentence and a capability's id/title/fields, plus hand-written **verb synonyms**
  (`append → add put save write…`). Below a score threshold, the honest answer is "nothing
  named." This is a **flat ranked lookup, not a graph.**
- The only graphs in the project are the **conversation `KnowledgeGraphView`** (a
  visualization of which apps/tools a thread touched — viz, not reasoning) and **graphify**
  (a graph of the *codebase*, developer-tool only, not shipped).

If graph-based capability reasoning is a goal, it is **net-new work**, not polish. `[gap]`

---

## 10. Verification & evaluation — the honest state

**Runtime verification is real and good. Offline evaluation does not exist.** `[code]`

Runtime guards:
- **`AgentAnswerVerifier`** — catches an answer claiming work that never ran (checks which
  tools actually executed this turn against `AIAuditHistory`).
- **`CommandOutcomeVerifier`** — reads back whether a command *actually changed* anything
  (exit-zero ≠ worked).
- **`FreshResultEvaluator`** — evaluates result freshness/relevance.

Missing:
- **No eval/benchmark suite** for answer quality, route-selection accuracy, or regressions.
  Nothing measures "did the chat pick the right route / give the right answer" across a fixed
  test set. `[gap]`
- The offline test suite (`Context-DockTests/`) covers some tool-less paths but not
  end-to-end route quality. `[gap]`

---

## 11. Safety

`[code]`

- **One approval inbox** — `ApprovalCenter` unifies shell, capability, general-action and
  adapter-action approvals into one surface, identical on every window. A different window is
  never a reason to lower a gate. `[code — CHAT_SCOPES.md, ApprovalCenter.swift]`
- **Authority envelope** — `refusesChanges` (read-only turns) and `allowedToolNames` (a
  restricted tool set) set once per turn via `prepareTurnBudget`; a promise in a prompt is
  not a boundary, so these are enforced in code.
- **Per-route access levels** (§6) — knowing a menu command exists is not permission to read
  the app's documents.
- **Untrusted-content rule** — page text, file contents and other external data are wrapped
  with `UntrustedContent.rule` so injected instructions in that content are treated as data.
- **Destructive menu commands** (Close/Quit/Delete) pop the app's *own* confirmation.

---

## 12. Providers

Same loop, many models. `[code]` API providers (OpenAI/Anthropic/Gemini/Ollama/compatible/
Kimi/bridges) run `sendWithTools`; on-device Apple runs `OnDeviceToolSession`; `claudeCode`
CLI answers tool-less. Anthropic requests use `AnthropicPromptCache` (prefix-caches tools +
system across the loop's 2–16 calls). Token cost is recorded in `AITokenLedger`.

---

## 13. Engineering map (files)

| Concern | File |
|---|---|
| Scoped-chat orchestration | `AI/AppScopedChatService.swift` |
| Per-app grounding / tool-choice order | `AI/ScopedAppPromptBuilder.swift` |
| Capability index & ranking | `AI/CapabilityIndex.swift`, `AI/AppAdapterCapabilityCatalog.swift` |
| Access levels / authority | `AI/AppAccessLevel.swift` |
| Tool loop, budget, receipts | `AI/AIProviderService.swift`, `AI/AgentToolRegistry.swift`, `AI/TaskRunStore.swift`, `AI/Providers/*ToolProviderAdapter.swift` |
| On-device tool session | `Services/OnDeviceToolBridge.swift` |
| Verification | `AI/AgentAnswerVerifier.swift`, `AI/CommandOutcomeVerifier.swift`, `AI/FreshResultEvaluator.swift` |
| Approval / safety | `AI/ApprovalCenter.swift` |
| Storage / scope routing | `AI/GeneralChatSessionStore.swift`, `AppPanelChatStore` |
| Adapters / MCP / skills registries | `AppAdapterManager`, `MCPServerManager`, `SkillStore` |

---

## 14. Known gaps / open questions (to resolve with owner)

1. **No capability graph.** Route selection is flat token-overlap ranking, not graph
   reasoning. Decide: is graph reasoning a real goal, or is a better ranker enough? `[gap]`
2. **No evaluation suite.** Route-selection and answer quality are unmeasured — you cannot
   tell if a change made the chat smarter or dumber. This is the highest-leverage missing
   piece for "make it stronger, intelligent later." `[gap]`
3. **API connections are mention-only** — configured but not callable from chat. Intended, or
   an unfinished feature? `[?]`
4. **Verb-synonym list is hand-written** (`append → add put…`). It fails for words nobody
   hard-coded — the exact "user speaks English, not API" case the code comments admit. `[gap]`
5. **No per-app success metric** — no measure of "did the chat do what the user meant on the
   first try, per app." `[gap]`
6. **Menu-only route depends on cache freshness** — a stale menu cache can offer a command
   that no longer exists; live verification mitigates but timing is `[?]`.
7. **Combined chats** (two+ apps in one thread) — route arbitration across apps is documented
   at a high level; per-app authority interaction in a combined chat needs its own review.
   `[?]`

---

*End of draft. Redline directly; merges into `docs/architecture/` only after owner
confirmation.*
