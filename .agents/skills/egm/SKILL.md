---
name: egm
description: >-
  Elephant-Goldfish Model (EGM) for Specification-Driven Development (SDD).
  Separates deep-context design (The Elephant) from zero-context critique
  (The Goldfish) to expose unstated assumptions, close logic gaps, and prevent
  implementation drift.
  Trigger: "egm", "elephant goldfish", "spec review", "zero-context review",
  "/egm-draft", "/egm-review", "/egm-drift".
---

# Elephant-Goldfish Model (EGM)

Adapted from [google/elephant-goldfish-model](https://github.com/google/elephant-goldfish-model).

> *"Design with an Elephant, Review with a Goldfish."*

## The Problem EGM Solves

When an AI coding agent writes a specification or code and then evaluates its own output within
the same chat context, it suffers from **context pollution**:
- It reads its own unstated intentions into ambiguous prose.
- It skips verifying edge cases because "it already knows what it meant."
- It misses architectural boundary violations because the conversation history provides artificial
  justification.

**The Solution:** Context segregation. The design is authored by a context-heavy agent (The Elephant),
but critiqued by an isolated, fresh agent with **zero conversational memory** (The Goldfish).

---

## The Core Roles

| Role | Entity | Context Scope | Responsibility |
|---|---|---|---|
| **The Elephant** | Main Session / Planner | Deep (chat history, blueprints, backlog, broad repo knowledge) | Brainstorms, explores alternatives, handles user dialogue, drafts specifications in `docs/superpowers/specs/` or `docs/designs/`. |
| **The Goldfish** | Subagent (`goldfish-reviewer`) | Zero (only the written spec file / diff + explicit cited files) | Rigorous critic. Assumes nothing. "If it's not written, it does not exist." Hunts unstated assumptions, missing failure modes, and layer violations. |
| **The Human Arbiter** | Owner | Global | Reviews trade-offs, resolves disagreements between Elephant and Goldfish, signs off on the specification before any code is written. |
| **The Builder** | Session / Worktree | Narrow (assigned issue + approved spec) | Implements the change in an isolated worktree (`.claude/worktrees/<issue>`). |
| **Drift Goldfish** | Subagent (`reviewer` / `goldfish-reviewer`) | Zero (diff + approved spec + `AGENTS.md`) | Verifies that the implementation does not drift from the approved spec or violate repository rules. |

---

## The EGM Workflow

```
   1. Brainstorm & Draft (Elephant)
      ├── Holds deep context, user requirements, blueprint
      └── Produces Markdown spec (docs/superpowers/specs/YYYY-MM-DD-*.md)
            │
            ▼
   2. Zero-Context Spec Review (Goldfish) ◄────────┐
      ├── Spawns clean subagent (no chat history)  │ (Review Loop)
      ├── Audits assumptions, gaps, failure modes  │
      └── Elephant updates spec to fix findings ───┘
            │
            ▼
   3. Human Sign-Off (Owner)
      ├── Reviews trade-offs
      └── Explicitly marks spec as APPROVED
            │
            ▼
   4. Implementation (Builder)
      ├── Isolated worktree (.claude/worktrees/<issue>)
      └── Implements strictly to approved spec
            │
            ▼
   5. Zero-Context Drift & Code Audit (Goldfish)
      ├── Diff audited against approved spec
      └── Verifies zero unapproved drift & AGENTS.md rules
```

---

## Specification Requirements (The Elephant's Deliverable)

Every specification authored under EGM must contain:
1. **Context & Goals:** Problem statement and explicit non-goals.
2. **Architectural Lane & Layer Alignment:** How the change respects the DoraX layer rule (Data lane vs UI lane; no copy of engine code; Corner parity).
3. **Data Model & Invariants:** Exact state representation, persistence, thread safety, and lifecycle.
4. **Failure Modes & Error Handling:** Explicit handling for app relaunch, network loss, stale caches, cancelled tasks, corrupted records.
5. **Acceptance Criteria & Offline Tests:** Machine-verifiable assertions that prove completion without requiring live external state.

---

## Spawning the Goldfish Reviewer

### Context Isolation Rule
**CRITICAL:** When dispatching to the Goldfish, **never** summarize what was discussed in chat.
Pass **only**:
1. The path to the specification file (or PR diff).
2. The paths of explicitly cited existing code files.
3. The standard review checklist below.

### Standard Review Checklist for the Goldfish
1. **Unstated Assumptions:** What dependencies, system states, or preconditions are taken for granted without being written down?
2. **Failure Modes & Edge Cases:** What happens on app quit, task cancellation, nil inputs, concurrent mutations, or missing files?
3. **Ambiguity:** Are requirements concrete and testable, or do they use hand-waving terms like "handle appropriately" or "efficiently"?
4. **Repository Rules (`AGENTS.md`):** Does the design violate product layer boundaries, duplicate engine logic, or break Corner/Dock parity?
5. **Drift (PR diff review only):** Does the code implement behavior not requested in the spec, or fail to implement something required?

### Output Contract
The Goldfish must output findings in strict, machine-parseable format:
```
path:line: severity (BLOCKER|WARN|NIT): problem. fix.
```
- **BLOCKER:** Must be resolved before spec approval or PR merge.
- **WARN:** Potential risk or unhandled edge case that requires explicit sign-off.
- **NIT:** Minor clarity or documentation improvement.

If zero blockers or warnings remain:
```
VERDICT: APPROVED (zero blocking gaps)
```

---

## Tool-Specific Execution

### In Claude Code
- **Spec Review:** Run the `goldfish-reviewer` subagent:
  ```
  Spawn goldfish-reviewer to review docs/superpowers/specs/2026-11-08-feature.md against AGENTS.md.
  ```
- **PR Diff Review:** Run `reviewer` or `goldfish-reviewer`:
  ```
  Spawn reviewer to review git diff against the approved spec and AGENTS.md.
  ```

### In Antigravity
- Use `invoke_subagent` with `Role: "Goldfish Spec Reviewer"` and `Model: "pro"` or `"inherit"`:
  ```json
  {
    "TypeName": "research",
    "Role": "Goldfish Spec Reviewer",
    "Prompt": "You are a zero-context Goldfish Reviewer (EGM). Read ONLY docs/superpowers/specs/XYZ.md and AGENTS.md. Audit for unstated assumptions, missing error handling, and architectural boundary violations. Output findings as: path:line: severity: problem. fix."
  }
  ```
- After receiving findings, the main session (The Elephant) updates the specification document and repeats until `VERDICT: APPROVED`.
