# Corner Selection panel: one panel that does everything the Dock's Selection does

> **Status: BUILDING (2026-09-25). Part A in progress.** Written so work can resume exactly here
> after any interruption. Spec: `docs/master/00-DOCK-AND-CORNER.md` §4a. Branch:
> `claude/corner-parity`, PR #84 (open, all work so far committed and pushed).

## Where we are (read this first when coming back)

The owner's order (the remote-control brief, 2026-09-24), with state:

| # | Step | State |
|---|---|---|
| 1 | PR into general-chat-agent | ✅ #76 merged |
| 2 | Verify the parity inventory on the app | ✅ partial: 12 rows checked (#81); 8 ❓ need a selection / live model |
| — | Owner's four Corner fixes | ✅ #79, #80 merged |
| — | → never runs a row (D4), ↑ reaches Global (F2) | ✅ #81 merged |
| — | First typed letter lost | ✅ #82 merged |
| 3 | **Corner Selection (§4a) + swipes (§4b)** | 🔨 **in progress**: swipes ✅ #79; Selection rows via bridge ✅ in #84; open-speed / idle / hotkey fixes ✅ in #84; **this plan is the rest of step 3** |
| 4 | Keyboard rules as one shared tested type (inventory B, C, E4) | next after step 3 |
| 5 | Remaining scopes D4–D7, D13–D14 (ask about D9, D11, D12) | after 4 |

Parked, with owner answers still owed: hotkeys register 3.75 s after launch (follow-up?);
#77 test-host main-thread stalls; #83 extract `SelectionActionSource` (before the Dock retires).

## What the owner asked (2026-09-25, with screenshot)

The answer to a Selection AI row appears in a **second card** (App Chat, Finder) under the
Selection card. Instead:

1. **Answers in the same panel.** The Selection card becomes the result sheet: rows, then the
   answer (the same step list and answer view App Chat draws), follow-ups in its own field.
   One panel, never a second card stacked on it.
2. **Everything the Dock's Selection does, inside that panel:** Share (supersedes the earlier
   "Share left out" — #83 to be updated), a **preview of selected files**, all extensions
   including the **four default ones** (Save Selection to Downloads, Search on YouTube, Search
   Web, Copy as Plain Text) and user-added ones.
3. **Modern, clear, working.** Every function tested by the agent; the owner is asked for a
   hand check only where the agent cannot test.
4. **Test on several apps, deepest in Safari.** Also Quick Notes and the knowledge graph (see
   open question Q2).

## Plan (one PR, #84, one commit per part)

A. **Answer inside the card.** The card gets a second state, *answering*: header and the
   selection stay; the rows give way to the transcript (reuse the App Chat transcript and
   step-list views — no second copy); the field becomes the follow-up field. The turn still
   runs on the one pipeline (`appChatPromptSubmitted` → `ScopedTurnRunner`). The App Chat card
   is not raised for a Selection question (`presentAnswer(forSelectionIn:)` stops being used).
   Esc: answer → rows → close. Tests: asking keeps one card; follow-up goes to the same turn;
   Esc steps back.
B. **Share in the card.** Share rows come back into the Corner list. Running one opens the
   standard macOS share picker anchored to the card (not the Dock's inline mode, which is
   invisible from the Corner). Tests: Share rows present in Dock order; running one asks the
   picker with the captured items.
C. **File preview in the card.** For a file selection the preview area shows the file (the
   thumbnail the pin card already uses; a folder uses `PreviewFolderBrowser`), Space opens
   Quick Look. Tests: preview kind per selection kind.
D. **Look.** Same row style as the App Chat list, section headings (AI · Actions · Extensions ·
   Share · Finder), card height stays a pure function of state.
E. **Test matrix, on the app by the agent** (System Events + screen capture; memory
   `driving-dorax-on-the-mac`):

   | App | Selection | Check |
   |---|---|---|
   | Safari (deep) | text on a page; a link; page with no selection | every row runs; AI answer in the card; Share picker; Search Web / YouTube open; Copy as Plain Text |
   | TextEdit | text | Rewrite / Summarize answers in the card; Copy Text; Save Selection to Downloads writes a file |
   | Finder | one file; several files; a folder | preview; Compress / Open / Reveal; Share; AI "Explain this file" |
   | Notes | text | rows present; AI answer |
   | Quick Notes / knowledge graph | see Q2 | |

   Rows that run commands with side effects (Share sending, Services that write) are checked up
   to the confirmation step only, never sent. Hand checks asked only for what cannot be driven.
F. Docs: §4a, inventory D10 (→ ✅ when Share and answers are in), `corner-shell.md`, #83 note.

## Owner rules (2026-09-25, second message) — these govern every part

1. **Follow `docs/superpowers/specs/2026-09-23-surface-cost-and-computer-use.md`.** Every row
   has a surface — `headless` < `opensApp` < `takesScreen`. **AX-driven work (clicking a
   menu, Writing Tools, setting text in another app) is `takesScreen`: it runs only when
   Computer Use is enabled for that app** (`ComputerUseConsentStore.effectiveMode(for:)`).
   Otherwise the cheapest able path runs — a headless route, or **the AI provider the user
   selected** (e.g. Rewrite / Proofread through the provider, not Writing Tools via AX). Where
   the UI is the only way, the row says so and offers the consent (spec §3 Step 4: Allow once ·
   Allow always), never a silent failure.
2. **The result sheet is the answer surface and must be complete**: markdown, **tables**,
   **links**, files / documents / **images** rendered in the card (the shared
   `AIChatMessageView`, the one renderer the Dock and App Chat use), and **actions at the end of
   a result**: Replace selection (only with Computer Use for the source app — otherwise Copy,
   with the reason shown), Copy, Save to Quick Note, Share.

## Build order (revised)

- **A — Answer in the card** + result actions (rule 2). Card state *answering*: transcript from
  `AppChatConversation.shared` via `AIChatMessageView` and `LiveAgentProgressView`; follow-ups in
  the card's field; Esc answer → rows → close; the App Chat card is not raised.
- **A2 — Surfaces and consent on rows** (rule 1): Finder-menu, app Share-menu and Writing Tools
  rows are `takesScreen`; with Computer Use off they show the consent offer instead of running.
- **B — Share** (routes 1–3 above, route 2 only with Computer Use).
- **C — File preview**, **D — look**, **E — test matrix**, **F — docs**, as above.

## Owner answers (2026-09-25)

- **Q1 — yes.** An answer keeps the card a Selection card (a small chat about the selection)
  until it is closed; it never turns into App Chat.
- **Q2 — use what exists, skip what does not.** Quick Note: a **Save to Quick Note** Selection
  row (text → new note via `QuickNotesStore.add`; files → `attachFiles`), added to the Dock's
  Selection builders so both shells get it; and **Save answer to Quick Note** on an answer in
  the card. Notes mirror into memory (`QuickNoteMemoryMirror`), so they become findable.
  Knowledge graph: no action — it is a view of past conversations; card answers appear in it
  on their own.
- **Q3 — reuse the app's share routes, confirmed from code before starting:**
  1. *Native inline destinations* — `ShareActionCoordinator.shareDestinations(items:)`: every
     NSSharingService incl. installed share extensions, real icons, frecency-ranked; run with
     `performDirectShare` (gives extensions a host window); payload resolved at tap
     (`liveShareItems`, e.g. the live Safari URL). The Dock deliberately does *not* bounce to
     NSSharingServicePicker.
  2. *App Share menu via AX* — apps whose File ▸ Share children AX captures (e.g. DuckDuckGo)
     share through those menu items so the app supplies the page; the native list does not
     duplicate them (`frontmostAppHasShareMenu`).
  3. *Direct routes* — `ShareIntentRouter`: "send to <person> via Messages/Mail" with contact
     lookup, falling back to the native service.
  Part B therefore = a Share row that opens route 1 **inside the card**, route 2 where the app
  has it, route 3 for typed "send to …"; built from `ShareActionCoordinator` with the captured
  selection. NSSharingServicePicker is not used. **Awaiting the owner's go for this before B.**
