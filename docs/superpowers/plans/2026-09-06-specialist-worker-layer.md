# Specialist workers: delegating a bounded problem to Claude Code or Codex

**Goal:** when DoraX has no route for a request it understands, it may offer to hand that
bounded problem to an installed coding agent — inside an authority envelope derived from the
scope it was asked in — instead of ending at "add a route in Settings".

**Status:** plan only. Nothing here is built.

**Origin:** a user analysis of why Claude Code and Codex "feel more powerful", checked against
the code. Its architecture was right and is followed here; two of its factual claims were not,
and are corrected below.

---

## What is true today

Verified, not assumed:

- **Claude Code and Codex are app-linked CLIs.** `AdapterIntegrationSeeder.swift:106-121` seeds
  `claude` to the Claude adapter and `codex` to the Codex adapter. They are reachable in those
  app scopes and invisible from every other, so a VS Code chat cannot see them.
- **No worker concept exists.** Nothing in `AI/` models an external agent runtime.
- **The verification vocabulary already exists.** `AIVerificationStatus` in
  `AIOrchestrationModels.swift:51` — `verified`, `executorConfirmed`, `unverified`,
  `notAvailable`. A worker's result maps onto this rather than inventing a parallel one.
- **Approval already has surfaces.** `ApprovalSurface` covers `.dock`, `.chatWindow`,
  `.preview`, `.corner`, so a delegation raised in the corner can be answered there.
- **The approval-gated command rung now exists** (`fix(agent): unlinked is not impossible`).
  This matters for ordering: most "DoraX can't" cases are one approved read-only command, not
  a worker.

### Where the origin analysis was wrong

1. **It skipped the command rung.** Its ladder went *deterministic route → no route →
   specialist worker*. `ArgvCommandGate` already sends an unrecognised executable to the
   approval path, so "propose a command the user approves" sits between those. A `curl` that
   answers in 200ms must not be answered by spawning an agent for minutes.
2. **It treated the seeded "add a route in Settings" ending as the intended fallback.** It was
   an instruction, and it has since been replaced. A worker layer is not needed to fix that
   case, and building one to fix it would have been building the wrong thing.

---

## The ladder

```
request
  → direct capability
  → deterministic discovery (menu, CLI, MCP, API, Shortcut)
  → propose an approvable read-only command          ← exists today
  → offer a specialist worker, bounded and approved  ← this plan
  → say what capability is missing
```

A worker is never reached because a capability is merely absent; it is reached when the request
is *work* — investigate, search, edit, build, test — and the rungs above cannot carry it.

## Authority is the whole design

Context Dock Chat is scoped to the frontmost app. A worker delegated from it must not become a
system-wide agent, or the scope architecture is decoration. Every delegation carries an
envelope derived from the scope that asked:

```
scope: VS Code
allowed:    current workspace/repository, VS Code installation metadata,
            linked VS Code capabilities, read-only package-manager queries
forbidden:  unrelated apps, unrelated paths, sudo, installs, deletions,
            settings changes
budget:     timeout, attempt limit, token/tool budget
result:     structured, and independently verified before it is believed
```

When the request genuinely needs more than the envelope allows, the answer is an escalation
offer — "this needs system-level execution, continue in General AI?" — never a silent widening.
That is the never-merge-layers rule applied to delegation.

## Tasks

### Task 1 — Worker model and registry (no execution)

`AI/Workers/`: `AIWorker`, `AIWorkerKind`, `AIWorkerCapability`, `AIWorkerRegistry`.
Typed domains (`coding`, `repository`, `build`, `test`, `systemInspection`) so a worker is a
specialist, not a hammer. Pure, tested: given installed workers and a request, which are
eligible and in what order.

### Task 2 — Discovery, cached, off the typing path

Resolve `claude` and `codex` once in the background using existing binary discovery; cache
availability. Never scan or spawn while the user types, while Context Dock rebuilds rows, or on
the hotkey path — during a request this is a cached lookup only.

### Task 3 — The bounded task contract

`AIWorkerTask`: goal, scope, workspace, context summary, allowed and forbidden operations,
risk, timeout, attempt budget, expected output, verification requirement. Construction is pure
and tested — an envelope wider than its scope is a test failure, not a code review note.

### Task 4 — The offer, and approval

When the ladder reaches this rung, the answer carries a delegation proposal, rendered with the
`ActionChoice` mechanism that already exists: *"No verified update route is linked. Codex and
Claude Code can inspect this read-only. Use one?"* — Use Codex / Use Claude Code / Cancel.
Nothing runs before approval. Reuse the corner and window surfaces; no new window, no new mode.

### Task 5 — Execution and progress

Run the worker as a process with the envelope applied. Report through the existing step rows —
`● Codex inspecting installation…` — never as hidden reasoning, only factual stages and tool
receipts.

### Task 6 — Verification

A worker's text is not proof. Map its result onto `AIVerificationStatus` and, where possible,
verify independently: app version, filesystem state, git state, package-manager state. A write
the worker recommends needs its own second approval; delegation approval is not execution
approval.

### Task 7 — Regression and performance proof

Typing latency unchanged; Context Dock live context unchanged; simple VS Code actions still use
`code`/menu directly; a worker never runs before approval; a Context Dock delegation receives
only that app's envelope; broader requests offer General AI escalation instead. Debug and
Release build; full suite.

## What this plan will not do

- Attach Claude Code or Codex to every app adapter. They are not app capabilities.
- Route workers through `AIProviderRouter`. A provider is a model; a worker is a harness.
- Launch a worker automatically because a capability is missing.
- Let a worker grant itself permission, or let "the worker said success" mean verified.
