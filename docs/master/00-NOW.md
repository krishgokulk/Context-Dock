# 00 — Now: the work order and the owner's decisions

> **Why this file exists:** long chat sessions get compacted and forget. Anything decided or
> queued in a chat is written here the same day, so no session — cloud, Mac, Remote Control, the
> 11:00 daily brief — depends on remembering a conversation.
> **Rules:** one task is *In progress* at a time (finish it before the next — `AGENTS.md`).
> When a task merges, move it to *Done* with its PR number and promote the next one. Decisions are
> append-only: never edit an old one, add a new dated line that replaces it.
> GitHub Issues (milestone `1.0`) remain the long backlog; this file is the next few steps.

## In progress

**4. Safari tabs in the Corner** (inventory D13) — PR #89, **reworked 2026-09-25**: the first build
put the tabs in the result *list*; the owner wants them as **pills in the Corner's strip, next to the
input field**, the way the Dock shows open tabs. The shared `BrowserTabList` loader in #89 stays.

```
Rework PR #89 (Safari tabs, D13). Keep BrowserTabList / the shared loader. Change where tabs show:
- The owner's spec: open Safari tabs appear as pills in the Corner's strip NEXT TO THE INPUT FIELD (the space
  where the pinned app icons sit today), the way the Dock UI shows open tabs. Look at how the Dock draws its tab
  strip (LauncherView+LivePanel.swift safariTabListView) and match it; reuse, no second copy.
- The strip sizes itself to what it shows (auto width, overflow → "+N" like running apps), never clipped.
- Click / ↩ on a tab pill switches to that tab. Typing still filters.
- Fix the CI race first: a late refresh must never overwrite a newer result (refresh generation), tests use only
  the injected source; check whether it explains the first switch that did nothing on the app.
- Tests: tabs render as strip pills from the shared loader; overflow; switch; stale refresh dropped.
End with the AGENTS.md hand-off.
```

## Next, in order

**4a. Menu safety list blocks harmless commands** (bug, owner 2026-09-25) — can run in a second
session alongside 4: different files. `AppMenuConsentStore.isDestructive` matches "close" as a
*substring*, so **History ▸ Reopen Last Closed Window** and **Recently Closed** count as destructive
and App Chat refuses them. "forward" as an outbound word also catches **History ▸ Forward** (navigation,
not Mail's Forward). Separately, `AppMenuCapabilityCache` treats History / Recently Closed as a
volatile branch, so "Recently Closed" never shows in menu results.

```
Task 4a: menu safety list false positives. Own worktree from origin/general-chat-agent.
Files: Services/AppMenuConsentStore.swift (destructiveNeedles / outboundNeedles / isDestructive),
Services/AppMenuCapabilityCache.swift (isVolatileMenuPath, privateDynamicBranches).
- Match destructive words as whole words on the item title, not substrings of the whole path: "Close Tab",
  "Close Window", "Clear History…" stay gated; "Reopen Last Closed Window", "Recently Closed" are not.
- "Forward"/"Back" under a browser's History menu are navigation, not outbound. Mail/Messages ▸ Forward stays gated.
- Stable browser commands (Reopen Last Closed Window, Reopen All Windows from Last Session, Recently Closed
  submenu) appear in menu search results in both shells; the per-URL rows keep their current handling.
- Tests, one per case above, both directions (still gated / now allowed). Safety first: when unsure, stay gated.
End with the AGENTS.md hand-off.
```

**4b. Pins in the Corner strip** (owner 2026-09-25, after 4 merges). The Corner's context dock uses
the strip beside the input for things the user pins, per app: tabs, menu commands, app actions
(Safari: Add to Bookmarks, Export as PDF, Save as Markdown, Ask AI), and the user's own actions.

```
Task 4b: pins in the Corner strip. Own worktree from origin/general-chat-agent, after #89 merges.
- Any row in the Corner's app list (menu command, app action, extension, the user's own action) and any tab can be
  pinned for that app; pins show in the strip beside the input, before live tabs, and run with one click / ↩.
- Reuse the Dock's pin store (DockPinStore, inventory F4) — per-app pins, same storage; no second store.
- Safari actions: first check which of Add to Bookmarks / Export as PDF / Save as Markdown / Ask AI already exist
  as actions in the Dock; reuse those; list any that don't exist in the PR and ask before building them.
- Strip auto-sizes; unpin from the pill's context menu; order is the user's (drag) or pin order.
- Actions that are destructive/outbound keep their consent step even when pinned.
- Tests: pin/unpin per app, strip order, a pinned destructive action still asks, overflow.
End with the AGENTS.md hand-off.
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
| 2026-09-25 | Selection in the Corner (D10 ✅): the Dock's rows on the captured selection, answers in the card, Share, "send to …" with confirmation, Quick Note, file preview, Computer Use rule | #84 |
| 2026-09-25 | AGENTS.md: Dock/Corner rule, 00-NOW.md in "Start here" | #88 |

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
| 2026-09-25 | Replaces "Share left out": the Selection card does everything the Dock's Selection does **inside one panel** — answers (never a second card), Share (the app's own share routes: native destinations, typed "send to …"), file preview, all extensions. D10 → ✅ when these ship. |
| 2026-09-25 | AX-driven work (menus, Writing Tools, writing into another app) runs only with Computer Use on for that app; otherwise the user's AI provider does it (surface-cost spec). |
| 2026-09-25 | Quick Note: a Save-to-Quick-Note action on answers; the knowledge graph gets no action. |
| 2026-09-25 | Test sends go only to the owner (Gokula Kannan J). |
| 2026-09-25 | Selection test matrix: Safari is checked like the other apps, not in depth. |
| 2026-09-25 | ⌥⌥ opens the **Dock**, ⌘⌘ opens the **Corner** — fixed, no setting. Task 3 ("⌥⌥ opens Dock / Corner" setting) is dropped. |
| 2026-09-25 | Chat Window hotkey stays **⌃C** (advised ⌃⌥C). Known cost: a global hotkey takes the key from every app, so ⌃C no longer interrupts a running command in Terminal (or reaches any other app) while DoraX runs. Revisit if that bites. |
| 2026-09-25 | Safari tabs show as **pills in the Corner's strip next to the input**, like the Dock's tab strip — not as rows in the result list. The strip auto-sizes. |
| 2026-09-25 | The Corner's strip holds the user's **pins per app**: tabs, menu commands, app actions (e.g. Safari: Add to Bookmarks, Export as PDF, Save as Markdown, Ask AI) and the user's own actions. |

## Open decisions (owner)

- What ⌥⌥ opens once the Dock retires (A1 end state). Until then: ⌥⌥ Dock, ⌘⌘ Corner (2026-09-25).
- D9 Notifications, D11 Quick Note editor, D12 Mail in the Corner: move, or drop from v1?
