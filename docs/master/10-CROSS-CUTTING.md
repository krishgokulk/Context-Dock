# 10 — Cross-cutting: Evaluation · Safety · Performance · Security

> **Status: DRAFT / under review — synthesised from all surface docs + code.** Not merged yet.
> Tags: `[code]` verified in source · `[owner]` owner's stated knowledge · `[?]` needs confirmation.
>
> The concerns that cut across every surface. This is the doc to read to answer "is it fast,
> accurate, safe, secure?" honestly.

---

## 1. Evaluation & accuracy

### What exists (runtime verification) `[code]`
- `AgentAnswerVerifier` — rejects an answer claiming work no tool did.
- `CommandOutcomeVerifier` / `MenuOutcomeVerifier` — read back whether a command/menu action
  actually changed anything.
- `verify_outcome` — a model-callable verification tool.
- Typed `VerificationStatus` incl. **`contradicted`** — a read-back can *disprove* a claim.
  `[code — CONTROL_PLANE_AUDIT.md]`
- `FreshResultEvaluator` — result freshness/relevance.

### What exists (offline eval suite) — CORRECTION `[code]`
**An earlier draft of these docs claimed "no offline evaluation harness exists." That was
wrong.** The suite is large and eval-driven: **~135 `@Test`s in `*Eval*` files** (and **1,167
tests across 148 files** total), covering the deterministic layers this project cares about:
- Capability ranking — `CapabilityIndexTests` (15), `CapabilityMatchEvalTests`,
  `CapabilityRankedAppMatchTests`, `ContactSearchRankingTests`.
- Chat-turn routing/scoping — `AgentRoutingEvalTests` (38), `RoutePreferenceEvalTests`,
  `GeneralChatScopeFlowEvalTests`, `GlobalCommandRoutingTests`.
- Per-adapter behavior — Finder/Mail/Notes/Reminders/Safari/Messages `*AdapterEvalTests`.
- Prompt assembly, reading tools, app-reference discovery — `PromptAssemblyEvalTests`,
  `ReadingToolEvalTests`, `AppReferenceDiscoveryEvalTests`.

Most read "this was a real bug; here is the assertion that locks the fix" — eval-driven
development in practice. `[code]`

### What is thinner (the honest, smaller gap) `[gap]`
The existing tests are **per-case regression assertions** ("does this specific sentence route
right?"). What is not evident is a **dataset-driven aggregate metric** — a labeled corpus of N
route/scope cases run as a set to produce a **pass-rate you track release-over-release**, so a
change that fixes 3 cases and breaks 5 is visible as a *number*, not just red/green per case.
Also genuinely absent: **memory-retrieval eval** (author's own note, `09` §7 #5) and any
answer-quality/perf metric that needs a live model or Mac.

**Accuracy verdict:** honest *within a turn* (strong verifiers) AND well-covered *per-case
offline* (large eval suite). The refinement worth considering is an *aggregate scored corpus*,
not a foundation that's missing.

---

## 2. Safety

The control plane is genuinely well-built. `[code — CONTROL_PLANE_AUDIT.md, ApprovalCenter.swift]`

- **Risk levels** (`AICapabilityRiskLevel`: low/medium/high/critical). `.critical` is
  **hard-denied before the approval check** — deliberate, not a gap.
- **One approval inbox** (`ApprovalCenter`) — collapsed three earlier approval systems into one
  risk scale; identical on every surface. Approval is a **value** (`ExecutionApproval`), not an
  assumption — an executor with no stated approval raises the card itself.
- **Per-route authority** (`AppAccessLevel`: awareness/menuOnly/adapter) — asked per route, not
  per app. Installed ≠ permitted.
- **Folder-scope guard** (`CapabilityScopeGuard`) — runs before the executor, over arguments as
  written, **symlink-resolved** (so a path can't escape its scope via a symlink).
- **Untrusted-content rule** — external page/file text is wrapped so injected instructions are
  data, not commands.
- **Keys, not prompts** — scope is enforced in code (consent stores, bearer token on the MCP
  server, a vault path the writer can't escape), never asked for in a system prompt.

### Elevated-risk surfaces (the real review targets) `[owner — review]`
- `run_command` (shell), `send_keys` (keystroke injection), `spawn_worker` (delegation).
- **L2 custom extensions run arbitrary user scripts** (`bash`/`python`) as first-class AI tools
  (`07` §7 #1).
- These are gated by approval — approval is the *only* thing between the model and the machine
  for them, so the approval UX and the `critical` hard-deny list are the crown jewels.

---

## 3. Performance

Goal: **Raycast/Spotlight-level typing feel.** `[code — PERFORMANCE_RULES.md]`

- **Typing path:** input updates synchronously; heavy work runs after debounce; rebuilds are
  cancellable; a new query cancels stale work; **no AX refresh and no menu scan while typing**;
  no full pill rebuild per keypress.
- **Global Context is cache-first** — search indexed data while typing; live-verify only before
  execution; noisy global menu items excluded (Services, Writing Tools, AutoFill, Dictation,
  Emoji, Apple-menu noise).
- **Context Dock is live-first but UI-stable** — the result sheet stays mounted; queries filter
  existing rows; backspace must not collapse a valid sheet.
- **Unified Dock Surface** — mode changes swap content inside one shell; never recreate the
  floating window.
- **AI cost/latency:** `AnthropicPromptCache` (prefix cache across the 2–16-call loop),
  `AIContextBudget` (relevance-ranked context, not blind truncation).

**Performance verdict:** the *rules* are right and documented. Whether the app *hits*
Raycast-feel is a stopwatch question on a real Mac — **unmeasured here** (no perf test). `[?]`

---

## 4. Security

- **Sandbox / entitlements** — macOS app sandbox; codesigned. Distribution is an **unsigned
  beta DMG** (first launch needs right-click → Open) — not notarized. `[code — CLAUDE.md]`
- **Private frameworks** — `MediaRemote` is loaded via `dlopen`, never linked (`06`). Symbols
  can break per macOS release, and App Store distribution disallows private frameworks —
  confirm beta/direct-only. `[risk]`
- **Local data / privacy** — the memory vault is plain markdown the user owns and can relocate;
  scope enforced by a path the writer can't escape (`09`). Open privacy items: clipboard
  history retention + sensitive-clip exclusion (`05` E2), and private Safari data (history/
  bookmarks) which is gated to **local providers only** (`shouldIncludePrivateSafariData`). `[code]`
- **Network** — provider API keys per provider; a direct `URLSession` that bypasses system PAC
  to avoid proxy failures. `[code — AIProviderService.swift]`
- **Secrets** — API keys and tokens in settings/credential store; never in commits, prompts, or
  code (also a repo rule). `[code]`

---

## 5. The app-wide "what's missing" list (for the roadmap)

Ranked by leverage:

1. **Aggregate eval metric** — a large per-case eval suite already exists (~135 eval tests).
   What's thin is a *dataset-driven pass-rate* tracked over releases + memory-retrieval eval.
   This is a **refinement**, not a missing foundation. (Earlier drafts wrongly called eval
   absent — corrected.) `[gap, smaller than first stated]`
2. **Capability graph** — routing/planning is flat index + ranking; graph reasoning is net-new
   (`08` §14 #2). `[gap]`
3. **Two intent brains** — `GeneralAIActionResolver` vs `L2UnifiedAssistant`; resolve which is
   authoritative, delete the other (`04` §10 #1). `[?]`
4. **Test coverage** — most surfaces have no automated tests (ranking, pill assembly, selection
   capture, extension loading). `[gap]`
5. **Memory hygiene** — no decay/dedupe/correction yet (deferred deliberately, `09` §7 #1). `[code]`
6. **Worker-layer contract** — `spawn_worker` exists; its authority envelope is unfinished
   (`08` §11). `[?]`
7. **Distribution hardening** — notarization/signing if this ever leaves beta (`06`, §4). `[risk]`

---

## 6. Honest one-line verdicts (for the goal conversation)

- **Fast?** Rules say yes; unmeasured. `[?]`
- **Accurate within a turn?** Yes — strong verifiers. `[code]`
- **Accurate across turns?** Well-covered per-case by a large offline eval suite (~135 eval
  tests); no *aggregate* pass-rate metric yet. `[code]/[gap]`
- **Safe?** The control plane is a real strength; the risk lives in the elevated tools behind
  approval. `[code]`
- **Secure?** Reasonable for a beta; private-framework use and clipboard/Safari privacy are the
  items to review before any wider release. `[risk]`
- **Does it save tokens?** Mechanisms exist (prompt cache, context budget, ledger); real
  savings unmeasured. `[code]/[?]`

---

*End of draft. This is the capstone; once the surface docs are confirmed, merge the gap lists
here into a single roadmap. Then build the evaluation harness.*
