# Corner Selection panel: one panel that does everything the Dock's Selection does

> **Status: PLAN, awaiting owner approval (2026-09-25).** Written so work can resume exactly here
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

## Open questions for the owner (answer before A starts)

- **Q1.** Follow-ups: once an answer is in the card, the card is a small chat about the
  selection. OK that it stays a Selection card (not App Chat) until closed?
- **Q2.** "Quick notes and knowledge graph": do you mean (a) Selection rows that **save** the
  selection to a Quick Note / the knowledge graph, or (b) testing ⌃S **inside** those apps?
- **Q3.** Share from the card: the standard macOS share picker (recommended, native, works from
  any window), or the Dock's own share destinations list drawn inside the card?
