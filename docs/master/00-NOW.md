# 00 — Now: the work order and the owner's decisions

> **Why this file exists:** long chat sessions get compacted and forget. Anything decided or
> queued in a chat is written here the same day, so no session — cloud, Mac, Remote Control, the
> 11:00 daily brief — depends on remembering a conversation.
> **Rules:** one task is *In progress* at a time (finish it before the next — `AGENTS.md`).
> When a task merges, move it to *Done* with its PR number and promote the next one. Decisions are
> append-only: never edit an old one, add a new dated line that replaces it.
> GitHub Issues (milestone `1.0`) remain the long backlog; this file is the next few steps.

## In progress

**1. Selection in the Corner** (inventory D10, `00-DOCK-AND-CORNER.md` §4a) — Mac session.
Approach B with conditions (see decisions 2026-09-25). Also removes the `#if DEBUG` "Temporary
trace" in `CornerChatPresentation.showFrontmostApp` that writes to `/tmp/dorax-trace.log`.

## Next, in order

**2. AGENTS.md: Dock/Corner rule** — docs only, after 1 merges.

```
Small docs-only PR to general-chat-agent. In AGENTS.md, under "DoraX architecture rule", add:

Before touching any Dock (LauncherView*) or Corner (AppChat*, Corner*, SelectionScope*) code, read docs/master/00-DOCK-AND-CORNER.md and docs/master/00-DOCK-PARITY-INVENTORY.md.
- The Dock is the reference behaviour; the Corner must match it. Reuse Dock code; never write a second copy.
- A bug fixed in one shell: check the other shell for the same bug in the same PR, and update the matching inventory row.

Also add docs/master/00-NOW.md to "Start here". Keep AGENTS.md under 150 lines. Stage only AGENTS.md, one MEMORY.md line, open the PR. Move this task to Done in 00-NOW.md.
```

**3. ⌥⌥ opens Dock / Corner setting** (inventory A1).
Today ⌥⌥ → `toggleLauncher()` (Dock, centre); ⌘⌘ → `activateGlobalContextScope()` (Corner). The
Corner's frontmost-app mode is `activateAppChatPrompt()`, reachable only by the App Chat hotkey
(unset by default) — so no gesture opens the Corner in Context Dock mode.

```
Task: ⌥⌥ target setting (inventory A1). Own worktree from origin/general-chat-agent.
- Setting "⌥⌥ opens: Dock / Corner" on the Hotkeys page (default Dock).
- Corner: ⌥⌥ → activateAppChatPrompt() (frontmost-app mode); ⌥⌥ again puts it away; ⌘⌘ while it's up switches to Global Context and ⌥⌥ switches back — same as the Dock.
- Tests: each setting routes ⌥⌥ to the right shell; ⌥⌥ toggles; ⌘⌘ ↔ ⌥⌥ switch modes in the Corner.
- Update inventory A1 and 00-DOCK-AND-CORNER.md §5 ("interim: user-selectable, default Dock").
check.sh green, one PR, one MEMORY.md line, move this task to Done in 00-NOW.md.
```

**4. Safari tabs in the Corner** (inventory D13).
The Corner shows the shared hint "tabs, page cmds, menu cmds" (`UI/AppChatListCard.swift:184` via
`Search/AppScopeHint.swift`) but loads no tabs; only the Dock does (`LauncherView.swift:3627`
`loadSafariTabs()`, drawn at `LauncherView+LivePanel.swift:1392`).

```
Task: Safari tabs in the Corner (inventory D13). Own worktree from origin/general-chat-agent.
- Reuse the Dock's tab loading: move it out of LauncherView into a shared type both shells call. No second copy.
- Corner Safari scope lists the tabs like the Dock; ↩ switches to the tab; typing filters them.
- Until tabs show, the Corner hint must not say "tabs".
- Also check Chrome/Arc if the Dock handles them.
- Tests: the Corner Safari scope lists tabs from the shared loader; filtering; the hint matches what is shown.
- Inventory D13 → ✅ with the test names. check.sh green, one PR, one MEMORY.md line, move this task to Done in 00-NOW.md.
```

**5. Then** the inventory's own order: keyboard rules (B/C/E4) into a shared tested type →
remaining scopes → owner decisions D9 / D11 / D12.

## Done

| Date | Task | PR |
|---|---|---|
| 2026-09-24 | Plans, blueprint, harness, check.sh | #76 |
| 2026-09-24 | Corner fixes (restore, folder preview, pins, Dock navigation) | #79 |
| 2026-09-25 | One-shell dock; → never runs a system command (D4); ↑ reaches Global (F2) | #80, #81 |
| 2026-09-25 | First letter typed from the resting strip no longer lost (B5) | #82 |

## Owner decisions (append-only)

| Date | Decision |
|---|---|
| 2026-09-24 | Name: **General Chat** everywhere, never "AI Assistant". |
| 2026-09-24 | Priority: move the ⌥⌥ Dock into the Corner with exactly the same behaviour, functions and navigation. |
| 2026-09-24 | Swipes in the Corner: exactly the Dock's, horizontal and vertical, over the input only (`00-DOCK-AND-CORNER.md` §4b). |
| 2026-09-24 | Selection actions + swipes are one task (`corner-parity`). |
| 2026-09-24 | Global Context lives on the ⌘⌘ row; no separate hotkey row. |
| 2026-09-25 | Selection in the Corner: **B** — reuse the Dock's rows through a bridge now, extract later. Conditions: (1) behind a `SelectionActionProviding` protocol, the Corner never names LauncherView; (2) works cold, before ⌥⌥ was ever opened (verified: LauncherView is built at launch); (3) Corner-side tests for rows, order, close button, Esc; (4) GitHub issue "Extract SelectionActionSource out of LauncherView", must land before the Dock retires. |
| 2026-09-25 | Selection AI rows (Ask AI, presets) run through the Corner's own ask path; the prompt lives only in `DockPill.selectionAIPrompt`, which the Dock also reads. |
| 2026-09-25 | Selection Share rows left out of the Corner for now; D10 stays 🟡 ("Share missing") until they return. |
| 2026-09-25 | The Corner captures the selection when it builds its list and runs every row on that copy, never on the live Dock payload. |
| 2026-09-25 | New bug-fix sessions wait until the Selection PR merges. |
| 2026-09-25 | Chat Window hotkey stays **⌃C** (advised ⌃⌥C). Known cost: a global hotkey takes the key from every app, so ⌃C no longer interrupts a running command in Terminal (or reaches any other app) while DoraX runs. Revisit if that bites. |

## Open decisions (owner)

- What ⌥⌥ opens once the Dock retires (A1 end state; task 3 is the interim).
- D9 Notifications, D11 Quick Note editor, D12 Mail in the Corner: move, or drop from v1?
