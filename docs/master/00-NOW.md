# 00 — Now: the work order and the owner's decisions

> **Why this file exists:** long chat sessions get compacted and forget. Anything decided or
> queued in a chat is written here the same day, so no session — cloud, Mac, Remote Control, the
> 11:00 daily brief — depends on remembering a conversation.
> **Rules:** one task is *In progress* at a time (finish it before the next — `AGENTS.md`).
> When a task merges, move it to *Done* with its PR number and promote the next one. Decisions are
> append-only: never edit an old one, add a new dated line that replaces it.
> GitHub Issues (milestone `1.0`) remain the long backlog; this file is the next few steps.

## In progress

Owner rule (2026-09-29): strictly in order — finish 16 and 17, hand test, merge, then 18.

**18. File search with Spotlight off** — Spotlight first, then a bounded scan of Desktop,
Documents, Downloads, iCloud Drive; full paths out; in-app agent, Finder pack and DoraX MCP server.
Starting in a subagent worktree; draft PR to follow.

Coordinator (2026-09-29): this branch (`claude/jev-popularity-comparison-t530yd`) runs in a local
Mac session. It edits only `00-NOW.md` and `MEMORY.md`, runs each task in a subagent in its own
worktree, watches the PRs, and merges only when the owner says so.

## Next, in order


**16c. Output files** — the model writes a real file (.md/.csv/.docx) into a DoraX outputs folder,
shown as a card. **16d. Shortcuts connector** — list and run the user's Shortcuts with approval
(the supported route to Siri-style reach; macOS has no public API to call other apps' App Intents).
Both after 18 (they build on 16b's cards and 17's routing).

**15. Owner decisions** D9 / D11 / D12. Settings card follow-ups: ⚙ on the scope-from-Global chip;
keys inside the card.
Follow-ups: a read-back that disagrees after a System connector write reports success with the
mismatch in text — make it a failed step (#115); cloud sessions must never merge their own PR (#114
merged before review).

## Done

| Date | Task | PR |
|---|---|---|
| 2026-09-24 | Plans, blueprint, harness, check.sh | #76 |
| 2026-09-24 | Corner fixes (restore, folder preview, pins, Dock navigation) | #79 |
| 2026-09-25 | One-shell dock; → never runs a system command (D4); ↑ reaches Global (F2) | #80, #81 |
| 2026-09-25 | First letter typed from the resting strip no longer lost (B5) | #82 |
| 2026-09-25 | Selection in the Corner (D10 ✅): the Dock's rows on the captured selection, answers in the card, Share, "send to …" with confirmation, Quick Note, file preview, Computer Use rule | #84 |
| 2026-09-25 | AGENTS.md: Dock/Corner rule, 00-NOW.md in "Start here" | #88 |
| 2026-09-25 | Menu safety list (4a): whole words; History ▸ Forward is navigation; Reopen Last Closed Window / Recently Closed stay in results; page rows still open by URL; unsure stays gated | #91 |
| 2026-09-25 | Safari tabs in the Corner (D13): Context Dock folds into its tab bar | #89 |
| 2026-09-26 | Pins in the Corner strip (4b): per-app pins of menu commands, actions, extensions and tabs lead the app's bar; any app with pins gets the bar; pinned destructive commands still ask. Safari "Save as Markdown" / "Ask AI" actions not built (asked in PR) | #94 |
| 2026-09-26 | AppleScript runs on one serial queue (fixes the Safari tab-click crash) | #95 |
| 2026-09-26 | Keyboard rules (task 5) in the shared `DockKeyRules`: result focus, pill row, empty-field Backspace ladder, list arrows, Return, Space, Finder folders, ⌘R in the Corner; one key press, one handler; ←/→ walk the apps both ways | #96, #98 |
| 2026-09-27 | AppleScript re-entrancy crash: one recursive lock owned by a thread, not `DispatchQueue.sync`; also the Corner dock auto-hides and shows (setting) | #100 |
| 2026-09-27 | The Corner no longer pulls DoraX in front of the app you are using; no blink when the strip hands the keyboard back | #101 |
| 2026-09-28 | Safari actions (task 6): Ask AI about this page, Save as Markdown (Downloads, never overwrites, Reveal); sensitive pages refused | #102 |
| 2026-09-28 | Per-app settings card: pin beside +, ⚙ in the app chip opens Can do / Sees now / Allowed | #105 |
| 2026-09-28 | Remaining scopes (task 7): a Global Command's row steps in, never runs (D4, D5); attach Finder's front folder (D7); D14 marked; D6 left for the owner | #106 |
| 2026-09-28 | Plugins from search open in the Corner's board (D6); Finder in front lists its menus; the Dock's window layouts in the app field | #107, #108 |
| 2026-09-28 | Sensitive pages never reach the chat: the page reader keeps only the origin and the guard's reason; `read_page` returns the refusal; sensitive tabs listed by origin (task 9) | #111 |
| 2026-09-28 | The Dock's menu reader never runs System Events on the main thread; the walk runs off-main and fills in (task 10) | #110 |
| 2026-09-28 | ⌘R in the Dock re-reads the app's menus, one rule and one re-read shared with the Corner (task 11, C12) | #112 |
| 2026-09-28 | System connectors: Global Commands as chat tools — reads free, writes ask, same runner as the Global row (task 12a) | #113 |
| 2026-09-29 | App Packs page in Settings: one switch per pack, detail page with the card's sections, "Sends data out" (task 12b) | #114 |
| 2026-09-29 | Activity rows: one row per real step in General Chat, Dock and Corner; read-back results; picker risk Medium; status reads preferred (task 14) | #115 |
| 2026-09-29 | Result cards for every chat turn: paths in an answer or step output become Open / Reveal / Quick Look / drag cards in Dock, Corner and the Chat Window; owner hand-tested (task 16b). Follow-up: paths under `~/Library` from step output are noise | #118 |
| 2026-09-29 | "find my …" no longer routes to Find My: phrase-like app names need a real cue, discovery never launches an app, a generic Edit row is not an answer to a search; owner hand-tested (task 16e) | #119 |
| 2026-09-29 | Model-first routing: the keyword shortcut preempts the model only on an exact command; the model picks from the scoped app's commands; phrasebook tests of the owner's real sentences (task 17) | #121 |
| 2026-09-29 | Approval bridge: a CLI turn DoraX launched gets the normal approval sheet; unattended refusal is per-run (task 16a) | #117 |

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
| 2026-09-25 | The Context Dock (frontmost-app chat) folds its field away at rest into a bar of the app's own things — pinned actions, open tabs, pinned tabs — like Global Context's running apps; not Global's pins. Open tabs in #89; pins are task 5. |
| 2026-09-25 | ⌥⌥ opens the **Dock**, ⌘⌘ opens the **Corner** — fixed, no setting. Task 3 ("⌥⌥ opens Dock / Corner" setting) is dropped. |
| 2026-09-25 | Chat Window hotkey stays **⌃C** (advised ⌃⌥C). Known cost: a global hotkey takes the key from every app, so ⌃C no longer interrupts a running command in Terminal (or reaches any other app) while DoraX runs. Revisit if that bites. |
| 2026-09-25 | Safari tabs show as **pills in the Corner's strip next to the input**, like the Dock's tab strip — not as rows in the result list. The strip auto-sizes. |
| 2026-09-25 | The Corner's strip holds the user's **pins per app**: tabs, menu commands, app actions (e.g. Safari: Add to Bookmarks, Export as PDF, Save as Markdown, Ask AI) and the user's own actions. |
| 2026-09-25 | Every Corner scope (frontmost app / Context Dock, Safari, …) uses the **same shell size, field and strip style as Global Context** — one look, not a wider or smaller variant per scope. |
| 2026-09-25 | UI changes are checked by eye against a reference screenshot before a PR is called done (AGENTS.md); tests alone are not enough. |
| 2026-09-26 | Build Safari **"Ask AI about this page"** and **"Save as Markdown"** as app actions (task 6, after task 5). |
| 2026-09-26 | While typing, every Context Dock is compact: no tabs pill, no pinned pages, no extensions — just attach (+), send and pin; no expand. Replaces "Safari's tabs stay while a question is typed" (2026-09-25). An app's pins show in its bar and the field's pill at rest, ahead of the tabs. |
| 2026-09-26 | B2 (Backspace into inline text pills) is "—" in the Corner: its scope is one chip outside the text; leaving it is B3. (Accepted by merging #98, which asked for it.) |
| 2026-09-29 | Strict order: finish 16 (a, b, e) and 17, hand test, merge, then 18. 16c/16d move after 18. |
| 2026-09-28 | "App Pack" is the name for an app's bundle of actions, skills, menus and tools; System packs group Global Commands. No Discover/marketplace in 1.0. |

## Open decisions (owner)

- What ⌥⌥ opens once the Dock retires (A1 end state). Until then: ⌥⌥ Dock, ⌘⌘ Corner (2026-09-25).
- D9 Notifications, D11 Quick Note editor, D12 Mail in the Corner: move, or drop from v1?
