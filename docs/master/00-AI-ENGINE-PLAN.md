# 00 — AI Engine Plan: make the agent safe, measurable and cheaper before 1.0

> **Status: ACCEPTED by the owner 2026-10-01 (option A).** The engine half of the plan:
> how one AI turn is guarded, measured and improved. The product, code layout and workflow
> stay in [`DORAX-BLUEPRINT.md`](DORAX-BLUEPRINT.md); the order of work stays in
> [`00-NOW.md`](00-NOW.md). This file never sets the order — it defines the tasks.
> Checked against `general-chat-agent` @ `c8f3acd` (2026-10-01).
> Tags: `[code]` true in the repo today · `[judgment]` recommendation · `[guess]` to be measured.

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

## 3. Baseline — what the code does today

| Area | Today | Evidence |
|---|---|---|
| Untrusted content | Fenced in prompts; `read_url` and `read_file` run without approval, any URL, any path | `[code]` `AI/ReadingTools.swift:105`, `:151`; `AI/UntrustedContent.swift:45` |
| Approval levels | `.medium`, `.high`, `.critical` all require approval | `[code]` `AI/AICapabilityRegistry.swift:18` (fixed in f2d3d5f, #44 closed) |
| Question vs action | A question is answered, never offered as an action | `[code]` `AI/ScopedRoutePolicy.swift`, `Context-DockTests/QuestionNotAnOfferTests.swift` |
| Read-back | A read-back that disagrees fails the step | `[code]` #139 / PR #142 |
| Prompt order | Volatile sections (`resolvedContext`, `selection`) come before stable ones (`capabilities`, `reference`, `cli`); one cache mark on the whole system prompt | `[code]` `AI/ScopedPromptAssembler.swift:20`; `AI/AnthropicPromptCache.swift:27` |
| Tool loops | Three near-copies (OpenAI, Anthropic, Gemini); max_tokens 8,192 vs 16,000 | `[code]` `AI/Providers/AIProviderToolLoops.swift:103`, `:305`, `:516`; `:327` |
| Tool budget | On-device 8 tools, others 40; `find_capability` / `run_capability` always kept | `[code]` `AI/AIToolBudget.swift` |
| On-device chat | `sendToOnDevice` takes `history` and never uses it; errors are returned as answer text; no `exceededContextWindowSize` handling | `[code]` `AI/AIProviderService.swift:853`, `:872` |
| On-device tools | A new `LanguageModelSession` on every call | `[code]` `Services/OnDeviceToolBridge.swift:1209`, `:1264` |
| Observability | Opt-in `turns.log`; token ledger per provider per day | `[code]` `Services/DoraXTurnLog.swift`; `AI/AITokenLedger.swift` |
| Approvals | Held in memory (`@Published pending`); not restored after relaunch | `[code]` `AI/ApprovalCenter.swift:167` `[guess]` restart behaviour to confirm |
| Evals | 148+ offline test files; retrieval benchmark (hit@5, MRR); no replay of real turns | `[code]` `Context-DockTests/`, `AI/RetrievalEvaluation.swift` |

## 4. Tasks for 1.0

Sizes follow the issue rule: S ≤ ½ day, M ≤ 2 days, L is split.

| # | Task | Done when | Lane | Size | After |
|---|---|---|---|---|---|
| **E1** #149 | Security gate: once a turn holds private data and untrusted content, outbound tools ask first | An injected page asking `read_url` for `https://attacker/?d=…` raises an approval card; a URL the user typed in the thread still runs; offline tests cover both | `AI/ReadingTools`, `AI/UntrustedContent`, `AI/ApprovalCenter` | M | — |
| **E2** #150 | Recorder: per-turn trace in the turn log | One record per turn: tools sent vs called, rounds, tokens per round, cache-read tokens, characters per prompt section, verifier fires, latency; OpenTelemetry GenAI field names; still opt-in | `Services/DoraXTurnLog`, `AI/Providers` | M | — |
| **E3** #151 | Prompt order: stable first, a second cache mark, volatile last | E2 shows the cache-read ratio rising on multi-turn Anthropic threads; offline suite green | `AI/ScopedPromptAssembler`, `AI/AnthropicPromptCache` | S | E2 |
| E4 | ~~One "question or action?" gate~~ | **Done before this plan** — `ScopedRoutePolicy`, `QuestionNotAnOfferTests` | — | — | — |
| **E5a** #152 | On-device: keep history, survive overflow, typed errors | A 10-turn on-device chat uses a fact from turn 2; `exceededContextWindowSize` → condense the transcript, new session, retry once; failures are errors, never answer text | `AI/AIProviderService`, `Services/OnDeviceToolBridge` | M | — |
| **E5b** #153 | On-device: budget with `tokenCount` before sending | No overflow on the E5a test set | same | S | E5a |
| **E6a** #154 | Tool loop: no-progress stop + one max_tokens table | Two rounds with nothing new end the loop; per-provider limits in one table | `AI/Providers/AIProviderToolLoops` | S | E2 |
| **E6b** #155 | Tool loop: three loops become one | Adapters only translate request/response formats; offline suite green; no behaviour change in the E2 trace | same | M | E6a |
| **E7a** #156 | Focus: inspect / act / verify / answer each send their own tool set | Tools sent per round drop in the E2 trace; "answer" sends none | `AI/AgentToolRegistry`, `AI/AIToolBudget` | M | E6b |
| **E7b** #157 | Approvals survive quitting the app | A pending approval reappears after relaunch and the turn continues or is cleanly cancelled | `AI/ApprovalCenter` | M | — |
| **E8a** #158 | Replay cases: record query, context and tool outputs from real turns | 50 cases on disk, private data stripped | `Services/DoraXTurnLog`, tests | M | E2; test host #65, #75, #77 |
| **E8b** #159 | Replay runner: rule checks + retrieval metrics, offline | One command prints the pass rate before and after a change; includes 10 prompt-injection cases | `Context-DockTests/` | M | E8a |
| **E8c** #160 | Replay judge for answer quality | Judge scores agree with the owner's hand grades on 20 cases | tests | S | E8b |

Each task is one GitHub issue (#149–#160), created **without** the `ready` label. The builder only
takes `ready` issues, so nothing starts until the owner labels one.

## 5. Labs, after 1.0 (no issues yet)

| # | Task | Notes |
|---|---|---|
| E9 | Thread summary written on-device + `search_memory` tool | Old turns are summarized, not just dropped (`AI/ChatHistoryBudget.swift`) |
| E10 | Model policy per turn: privacy, availability, complexity; the user's setting is the ceiling | Folds in #70 (privacy routing settings) |
| E11 | Parallel read tools | Measured with E2 |
| E12 | Finish the capability index migration; retire old routers one at a time | `AI/CapabilityIndexShadow.swift`; #55, #57 |
| E13 | Hybrid retrieval: `NLEmbedding` + reciprocal rank fusion (k = 60) | Ships only if hit@5 and MRR improve on E8 cases |
| E14 | Graph gate: 30 real multi-hop questions from the turn log | No graph without them |
| E15 | Knowledge graph: typed edges from receipts in SQLite + `graph_neighbors` | Replaces the dashboard-only `KnowledgeGraph` |
| E16 | Nightly consolidation: dedupe facts, rebuild graph and embeddings | Extends `Services/BrainMaintenance.swift` |
| E17 | Import the `SKILL.md` of CLIs the user installed (CLI-Anything convention: JSON output, `--help`, skill file) into the capability index, so `find_capability` finds them | Never bundled or installed by DoraX; every command is a write that asks; only after E1b (#165) |
| E18 | Watch mode (= E19 layer 4): a scope notices things while you are away and leaves one suggestion. **Finder first**; Safari, then Mail/Calendar only after measured acceptance | Rules below. Needs E1b (#165), E7b (#157), E9 |
| E19 | **App Assistant**: each app scope becomes a personal assistant for that app — remembers you, learns your routines, briefs you when you arrive, says what changed after an update | Plan in §5b. Pilot Finder + Mail. After 1.0 |

### 5b. E19 App Assistant — the plan (owner confirmed 2026-10-04)

**Goal.** Every app scope (Finder, Mail, Safari, any app) acts like a personal assistant for that app: it knows how *you* use it, offers the next step before you ask, and tells you what changed — inside the scope's existing Context Dock chat, never a new surface. Inspired by OpenAI Dots, built the DoraX way: local, read-only when proactive, approval to act.

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
1. No new surface — the scope's Dock/Corner chat and strip only (Unified Dock Surface rule).
2. Proactive = read-only; any write waits for the owner through the same card and gate; an approved write runs once (E7b).
3. Interruption budget: at most one briefing per app switch, a few per day; off per app until switched on; an ignored suggestion type is learned and goes quiet.
4. Memory is visible and editable per app; nothing learned leaves the Mac.
5. Measured: every suggestion is traced (E2); an app whose suggestions are accepted less than an agreed share goes quiet; E8 replays guard quality.

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
builder (`/loop 20m /builder`, on the Mac) builds and tests it on its own branch from
`general-chat-agent` → engine planner reviews the PR against this file → owner hand-checks
and says "merge <n>" → this file's baseline (§3) is updated in the next docs PR.

Cloud sessions cannot build or test the app (Linux, no Xcode). Code is built only by the builder.

## 8. Study copy

The diagrams and reasoning behind this plan (the 17-step turn, memory tiers, loops) are in
the owner's "DoraX Master Blueprint" doc. This file is the source of truth for the tasks.
