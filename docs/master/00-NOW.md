# 00 — Now: the work order and the owner's decisions

> **Why this file exists:** long chat sessions get compacted and forget. Anything decided or
> queued in a chat is written here the same day, so no session — cloud, Mac, Remote Control, the
> 11:00 daily brief — depends on remembering a conversation.
> **Rules:** one task is *In progress* at a time (finish it before the next — `AGENTS.md`).
> When a task merges, move it to *Done* with its PR number and promote the next one. Decisions are
> append-only: never edit an old one, add a new dated line that replaces it.
> GitHub Issues (milestone `1.0`) remain the long backlog; this file is the next few steps.

## In progress

Coordinator: cloud planner (`/planner`), branch `claude/jev-popularity-comparison-t530yd` — since 2026-09-30. The Mac Desktop session is the **builder** (`/loop /builder`); it takes GitHub issues labeled `ready`, oldest first, and never edits this file.

Owner rules (2026-09-30): one task at a time; merge only on the owner's words "merge <n>"; **no `ship it` while the Hand-check queue has entries.**

**#147 Drop Shelf icon** (`ready`), then **#165 E1b** (`ready`, owner said "E1b yes" 2026-10-04), then **#151 E3**. Hand-check pause limit is 1 required check (#168).

## Next, in order (GitHub issues)

Owner order (2026-10-01): security first, then the AI engine plan, with the two owner bugs after E1.
The planner labels the next issue `ready` when the one before it is in review.

0. **App agent plan (owner 2026-10-06, "confirm plan")** — `docs/master/00-APP-AGENT-PLUGIN-PLAN.md`, in this order: **#195 P1** Mail shortcut exact-command · **#196 P2** menus out of the prompt · **#197 P3** two lanes · then #180, #185 · **#198 P4** · **#199 P5** · **#200–#203 P6–P9** plugin manager · **#208 P13** dictionary rung (after P6) · **#204 P10** retire shortcuts (E12) · #205 P11 / #206 P12 after E19a.
1. ~~#146~~ (#163) · ~~#150 E2~~ (#170) — merged 2026-10-02
2. **#147** Drop Shelf becomes an icon at the end of the dock, in every app (UI)
3. **#165 E1b** outbound-gate gaps: Mail/Messages/Notes untrusted, shell allow-list, exact typed URL (owner 2026-10-04: all three, option a)
4. **#151 E3** Prompt order · **#152 E5a → #153 E5b** On-device (E5 needs the owner's escalation answer first)
5. **#154 E6a → #155 E6b → #156 E7a · #157 E7b**
6. **#158 E8a → #159 E8b → #160 E8c** (#160 `needs-owner`: which model grades the replays)
7. **#134 Settings-card follow-ups** (`needs-owner`)

Labs, after 1.0 (no issues yet): E9–E16 from the engine plan, plus the blueprint's "Later" items — undo log and dry-run preview for writes, latency targets (first token under ~1 s), a per-turn "what left the Mac" view, a model-upgrade gate (rerun E8 before any new default model), proactive suggestions with an interruption budget (now E18 watch mode, rules in the engine plan §5).
Study copy (diagrams, reasoning, interview notes; not the source of truth for tasks): the owner's DoraX Master Blueprint and its pages — [AI turn](https://claude.ai/artifact/4jFrmW4XwXuetpV7sp5YLD), [target architecture](https://claude.ai/artifact/CDYUTY2zVpMTQDcSbyCQzT), [harness and graph](https://claude.ai/artifact/NX49kAEX2FskD9XWM57MmS), [agent blueprint](https://claude.ai/artifact/T7U6PWYuhZvbgCCdLc56sf).

Also open: cloud sessions must never merge their own PR (#114 merged before review).

## Hand-check queue

- (none waiting; #175's injection test passed with #187 on 2026-10-06)

Checked and passed: #118, #119, #121, #123, #125, #127, #137, #141 (2026-09-29/30); #148, #163, #164, #170, #174 (2026-10-04); #187 (#184, incl. #175's injection test) (2026-10-06).
A failed check becomes a `Fix:` issue at the top of the queue and its sentence goes into the matching test (routing: `RoutingPhrasebookTests`).

## Done

| Date | Task | PR |
|---|---|---|
| 2026-10-10 | UI/UX: "/" jumps to any app's scope from Global or a Context Dock (owner's Corner lane) | #222 |
| 2026-10-10 | UI/UX: Finder from Global is Finder's own Context Dock, with an Ask AI row (owner's Corner lane) | #221 |
| 2026-10-09 | Corner UI/UX: one field — apps are steps inside Global; ⌘ and swipes walk them (owner's Corner lane) | #220 |
| 2026-10-09 | Corner UI/UX: layout previews show the desktop's windows; the app card opens in the sheet's right half (owner's Corner lane) | #219 |
| 2026-10-08 | UI round 2: list duplicates, Dock ← chip, command arrows, Context Dock pill, drag to dock (owner's Corner lane) | #218 |
| 2026-10-08 | Corner: resting on the apps folds into the dock; one ← back chip for every scope (owner's Corner lane) | #217 |
| 2026-10-08 | Corner: Terminal freeze and keys; droplet split; app step-in rests as its own Context Dock (owner's Corner lane) | #216 |
| 2026-10-07 | Corner: running app icons manage windows; pinned extensions in the apps piece; compact app card (owner's Corner lane) | #215 |
| 2026-10-06 | E1c: Claude Code CLI loses WebFetch/WebSearch/Bash in private-data chats; `dorax_read_url` / `dorax_run_command` and on-device tools go through the outbound gate; owner hand-tested ("184 passed") | #187 |
| 2026-10-05 | Mail chat reads the message body (selected, open or latest; Mail closed or open), fenced and capped; never routes Mail to Messages; owner hand-tested. Gate test moved to #184 | #183 |
| 2026-10-04 | Mail chat: choices only for matching routes; a turn that ran a step shows no pick card (Corner, Dock, chat window); owner hand-tested ("quit mail") | #181 |
| 2026-10-04 | E1b gate: Mail/Messages/Notes reads count as untrusted, shell allow-list, only the exact typed URL is trusted, every tool name classified; text-recovered sends go through the gate (injection hand check owed) | #175 |
| 2026-10-04 | Drop Shelf is an icon at the end of the dock in every app, Dock and Corner; the floating card is gone; owner hand-tested | #174 |
| 2026-10-02 | Flaky turn-log and Shortcuts temp-file tests fixed (hand check optional) | #171 |
| 2026-10-02 | E2 Recorder: one trace per turn in the turn log; owner hand-tested | #170 |
| 2026-10-02 | Builder pauses after one required hand check; `hand-check-optional` label; "merge N without hand check" | #168 |
| 2026-10-02 | Finder chat carries out a resolved call or says why not; owner hand-tested | #163 |
| 2026-10-01 | E1 outbound gate: private + untrusted turns ask before sending out (owner hand-tested; gaps in #165) | #164 |
| 2026-10-01 | A read-back that disagrees with the request fails the step | #142 |
| 2026-10-01 | Clipboard notice no longer blocks the frontmost app | #144 |
| 2026-10-01 | Chat transcript rewrite loop no longer pins the main thread; app quits during a turn; owner hand-tested | #148 |
| 2026-09-30 | Skill audit of 16a–18: 4 P1 fixed (approval queue instead of a dropped request, cancellable file search, `nonisolated ShortcutsService`, per-file VoiceOver labels on file cards); 15 P2 listed in the PR; owner hand-tested | #141 |
| 2026-09-30 | Result cards skip `~/Library` / system paths from step output (iCloud Drive and paths the answer names are kept) | #138 |
| 2026-09-30 | Flaky `AXMenuReaderScriptedFallbackTests` fixed: each reader posts as itself, each test listens to its own (5×2241 green) | #136 |
| 2026-09-30 | Old Shortcuts route retired: only `run_shortcut` (16d) runs a shortcut; owner hand-tested | #137 |
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
| 2026-09-29 | File search with Spotlight off: `find_files` agent tool (Spotlight, then a bounded scan of Desktop, Documents, Downloads, iCloud Drive), Finder pack and `dorax_find_files` MCP tool; owner hand-tested (task 18) | #123 |
| 2026-09-29 | Output files: `write_output_file` writes .md/.txt/.csv/.docx into `~/Documents/DoraX Outputs/` (never overwrites, confined to that folder, approval sheet, refused when unattended) and shows a card; `dorax_write_output_file` on the MCP server; owner hand-tested (task 16c) | #125 |
| 2026-09-29 | Shortcuts connector: `list_shortcuts` and `run_shortcut` (exact/case-insensitive name from the list, High-risk approval sheet, 60 s timeout, output cap, refused when unattended) and MCP twins; "shortcut" is a noun, not the Shortcuts app; owner hand-tested (task 16d) | #127 |
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
| 2026-09-30 | Planner (cloud) and builder (Mac Desktop) roles; GitHub issue labels are the queue; hand-check queue emptied — all merged work through #137 checked by the owner. |
| 2026-10-01 | AI engine plan accepted: `docs/master/00-AI-ENGINE-PLAN.md` (#161). E1–E8c are 1.0; E9–E16 are Labs. |
| 2026-10-01 | Security first: E1 (#149) runs next, then #146, E2, #147. #134 stays needs-owner. #44 closed (fixed in f2d3d5f). |
| 2026-10-01 | On-device fixes (E5a, E5b) are 1.0: on-device chat ships today and loses its history. |
| 2026-10-01 | The engine plan file defines tasks; this file sets the order. The owner's Master Blueprint pages are the study copy, not a second plan. |
| 2026-10-04 | E1b yes (#165): Mail/Messages/Notes reads count as untrusted; shell commands use an allow-list; only the exact typed URL is trusted. Runs after #147, before E3. |
| 2026-10-05 | Merges (A): only the cloud planner merges, on the owner's words "merge <n>" in the planner chat. The Mac builder never merges, even after a passed hand check. |
| 2026-10-05 | Owner "yes": the owner's "N passed" (hand check) is also permission to merge that PR once CI is green; docs-only PRs (no hand check) the planner merges itself once CI is green. |
| 2026-10-06 | Adopted the app agent + plugin manager plan: two lanes (data never takes the window; UI lane's last rung is Computer Use), menus out of the default prompt, plugin manager fronting existing registries, CLI learner, curated catalog, solved-task library. P1–P12 = #195–#206; P1–P3 go before #180/#185 (`00-APP-AGENT-PLUGIN-PLAN.md`). |

## Open decisions (owner)

- E5: in on-device-only mode, may DoraX *offer* a cloud model when a task is too big, or never mention it? Needed before #152.
- What ⌥⌥ opens once the Dock retires (A1 end state). Until then: ⌥⌥ Dock, ⌘⌘ Corner (2026-09-25).
- D9 Notifications, D11 Quick Note editor, D12 Mail in the Corner: move, or drop from v1?
