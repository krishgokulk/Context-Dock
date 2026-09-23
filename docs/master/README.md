# DoraX Master Documentation (work in progress)

**Status: DRAFT / under review. Not authoritative yet.**

This folder is a from-scratch, surface-by-surface documentation pass of the whole app,
built with the owner to (a) write down what each surface actually is, (b) find missing
work and features, and (c) converge on the app's single goal.

It is **separate on purpose**. `docs/architecture/` holds the current architecture-truth
files. Nothing here overrides those. Once a surface doc here is confirmed by the owner, its
content is merged into the relevant `docs/architecture/` file and the master doc becomes the
top-level index.

## Method

- One surface per document, numbered in reading order.
- Each doc has two depths: **what the user sees** and **how it works in code** (files, data
  structures, execution, caches).
- Every claim is tagged: `[code]` verified in source · `[owner]` owner's stated knowledge ·
  `[?]` needs confirmation.
- Each doc ends with **Known gaps / open questions** — the point of the exercise.

## Planned surfaces (order may change)

1. Global Context — universal search & launch ✅ draft
2. Context Dock — frontmost-app command layer
3. App-Scoped Chat (Context Dock Chat Mode) — includes "running app chat"
4. General AI Chat (AI Assistant Mode)
5. Selection Shortcut Sheet — selection & clipboard scope
6. Media Dock
7. Extensions (L1 / L2 / L3) & the global extension system
8. The AI engine — providers, tool loop, verification, approval, token ledger
9. Knowledge graph / Second Brain
10. Cross-cutting: evaluation, safety, performance, security

## Master index

- [`01-GLOBAL-CONTEXT.md`](01-GLOBAL-CONTEXT.md) ✅ draft — universal search & launch
- [`02-CONTEXT-DOCK.md`](02-CONTEXT-DOCK.md) ✅ draft — frontmost-app command layer
- [`03-APP-SCOPED-CHAT.md`](03-APP-SCOPED-CHAT.md) ✅ draft — frontmost-app / Context Dock Chat Mode
  - [`diagrams/03-app-scoped-chat-flow.md`](diagrams/03-app-scoped-chat-flow.md) — flow diagram
- [`04-GENERAL-AI-CHAT.md`](04-GENERAL-AI-CHAT.md) ✅ draft — AI Assistant Mode (`.general` scope)
- [`05-SELECTION-AND-CLIPBOARD.md`](05-SELECTION-AND-CLIPBOARD.md) ✅ draft — Selection Shortcut Sheet + clipboard
- [`06-MEDIA-DOCK.md`](06-MEDIA-DOCK.md) ✅ draft — media state & controls
- [`07-EXTENSIONS.md`](07-EXTENSIONS.md) ✅ draft — L1/L2/L3 + global extension system
- [`08-AI-ENGINE.md`](08-AI-ENGINE.md) ✅ draft — shared engine: providers, loops, tools, verify, safety, cost
- [`09-SECOND-BRAIN-AND-DASHBOARD.md`](09-SECOND-BRAIN-AND-DASHBOARD.md) ✅ draft — memory layer + dashboard/graph
- [`10-CROSS-CUTTING.md`](10-CROSS-CUTTING.md) ✅ draft — evaluation · safety · performance · security

**All 10 surface/cross-cutting drafts complete.** Next: confirm & merge into
`docs/architecture/`, then build the evaluation harness (see `10` §5.1).
