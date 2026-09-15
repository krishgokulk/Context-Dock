# Corner Premium UX — Plan

> Execution plan. Steps use `- [ ]` so progress is legible. Nothing here is done yet.

**Goal:** The corner surfaces — App Chat, General Chat, Clipboard — read as one premium
product: quiet at rest, honest while working, and never a reason to stop what you were doing.

**Spec:** this file. **Prior art:** `2026-08-31-corner-dual-chat.md` (Tasks 1–5 landed),
`41ed4e5`, `4e887c7`.

---

## What is actually wrong today, verified

Four findings, each read from the code rather than inferred from the screenshots.

1. **The corner drives the dock.** `handleAppChatPromptSubmission`
   (`LauncherView+ContextLifecycle.swift:2045`) posts `.activateContextDock`, waits 120 ms, then
   calls `handleL2QuerySkippingMenuRouter`. So every question asked in the corner **opens the
   Context Dock window over the app you were working in**. It is not a rendering difference —
   the corner owns no pipeline, and the dock is where the turn runs.
2. **Finder parity is partial for the same reason.** `retargetCornerAppChat` sets
   `l2.chatDraftAppName/BundleId` and calls `syncL2DockSession`, but Finder's behaviour in the
   dock (folder-aware session key, selection context, the Finder contextual action set) hangs
   off dock state the corner only partly populates.
3. **The spinner is literal.** `AppChatPromptPill.swift:346` renders a bare
   `ProgressView` while the last message is the user's. The dock renders
   `LiveAgentProgressView(steps:)` (`LauncherView+AIChat.swift:1530`) over the same data. The
   reasoning exists; the corner just does not draw it.
4. **Clipboard has no search and no multi-select.** `ClipboardPanelModel.sources` is
   `[All] + per-app choices` and `visibleEntries` filters on `bundleID` alone
   (`ClipboardPanelWindow.swift:291,307`). There is no query field and no selection set.

**Already correct, do not "fix":** live menu search is already skipped on this path —
`handleL2QuerySkippingMenuRouter` is the menu-router-free entry point.

---

## Design language (applies to every task below)

One system, so the surfaces stop looking like three products.

- **Spacing:** 4-point scale — 6 / 10 / 14 / 20. Card inset 14. No other numbers.
- **Type:** 15 semibold titles, 13 medium rows, 12.5 body, 11 secondary. Nothing above 15 in
  the corner: the window's 22 is what made the start screen read as a shrunken window.
- **Radius:** 22 card, 10 row, capsule for chips. Never a rounded rect inside a rounded rect
  at the same radius — that reads as a rendering bug.
- **Elevation:** one shadow, on the card only. Inner elements are separated by tint and rule,
  never by a second shadow.
- **Motion:** one spring, `response 0.34 / damping 0.86`, for size. Opacity 0.12–0.18 ease.
  Never two animations on one container — that pairing is what made the resize stutter.
- **Chrome once:** any fact stated in the header is not repeated in the composer.

---

### Task 1: Run corner turns without opening the dock

The largest item, and the one everything else rests on. Until this lands, the corner cannot be
"smooth and undisturbing" — it opens a window over the user's work on every question.

**Files:** `Search/LauncherView+ContextLifecycle.swift:2045-2065`, new
`AI/AppChatTurnRunner.swift`, `Search/LauncherState.swift`, test
`Context-DockTests/AppChatTurnRunnerTests.swift`

- [ ] **Step 1** Write a failing test: a corner submission produces messages on
      `AppChatConversation.shared` without posting `.activateContextDock`.
- [ ] **Step 2** Extract the L2 turn from `LauncherView` into `AppChatTurnRunner`, taking the
      scope (app name, bundle id, folder key for Finder) and writing to `AppChatConversation`.
      The dock keeps calling it, so there is still one pipeline and one writer.
- [ ] **Step 3** Point `handleAppChatPromptSubmission` at the runner and delete the
      `.activateContextDock` post and the 120 ms delay.
- [ ] **Step 4** Verify by hand: ask from the corner while Finder is frontmost; the dock must
      not appear and Finder must not lose focus.

**Risk:** the turn currently reads `@State` on `LauncherView`. Anything it needs must move to
`AppChatConversation` or be passed in. Expect this task alone to be a session.

---

### Task 2: Finder parity, proven by a test rather than by eye

**Files:** `AI/AppChatTurnRunner.swift`, `Search/LauncherView+FinderSemantic.swift` (read only),
test `Context-DockTests/CornerFinderParityTests.swift`

- [ ] **Step 1** Write a test asserting the corner and the dock build the **same** scope key and
      the same context payload for Finder with a folder open.
- [ ] **Step 2** Feed the Finder folder key and current selection into the runner's scope.
- [ ] **Step 3** Verify by hand against a folder with a selection, and against Finder with none.

---

### Task 3: Show the reasoning, not a spinner

**Files:** `UI/AppChatPromptPill.swift:329-350`, `UI/LiveAgentProgressView.swift`, test
`Context-DockTests/AppChatPromptTests.swift`

- [ ] **Step 1** Replace the bare `ProgressView` with `LiveAgentProgressView(steps:)` over
      `model.liveSteps`, matching the dock.
- [ ] **Step 2** Empty-steps case: one line naming the stage ("Reading Finder…"), never a bare
      spinner — a spinner is the app declining to say what it is doing.
- [ ] **Step 3** Collapse to `N steps` on completion (already built for the dock; reuse it).
- [ ] **Step 4** Test: answering with steps renders them; answering without steps renders the
      stage line; neither renders a spinner alone.

---

### Task 4: App Chat chrome matches General

General already reads correctly: identity at top, provider at bottom, expand and pin in the
header. App Chat should be the same shape so switching modes changes the scope, not the layout.

**Files:** `UI/AppChatPromptPill.swift`, test `Context-DockTests/AppChatPromptTests.swift`

- [ ] **Step 1** Header, shown once a conversation exists: app icon + app name, then expand,
      pin, and clear-chat (trash).
- [ ] **Step 2** Move the provider chip to the composer row, matching General's bottom bar.
- [ ] **Step 3** Remove from the composer whatever the header now states.
- [ ] **Step 4** Test: header present only with a transcript; each control appears exactly once
      across header and composer.

---

### Task 5 (revised): Give the corner clipboard the dock's powers back

The corner panel is a reduced viewer of a scope that already does all of this. The dock's
`LauncherView+ClipboardScope.swift` is 2429 lines to the panel's 876, and the difference is
capability, not styling:

| Capability | Dock scope | Corner panel |
|---|---|---|
| Multi-select, ordered | `orderedSelectedClipboardEntries:515` | absent |
| Paste into the frontmost app | `pasteClipboardEntriesToFrontmost:601`, `postPasteShortcut:628` | single-entry `paste():138` |
| Drag a clip out as a real file | `clipboardDragProvider:645`, `temporaryClipboardDragFile:673` | absent |
| Drop files in | `handleClipboardIconDrop:702`, `revealClipboardDropTarget:688` | absent |
| Ask AI about the selection | `submitClipboardScopeAIQuery:561`, `clipboardContextText:543` | absent |
| Search | `clipboardSearchResults:898` | absent |

So the work is **extraction, not invention** — and the same rule the chat surfaces follow
applies: one implementation, two presentations. Reimplementing any of this in the panel is how
the two drift.

**Files:** new `Services/ClipboardScopeService.swift`, `Search/LauncherView+ClipboardScope.swift`,
`Search/ClipboardPanelWindow.swift`, tests `Context-DockTests/ClipboardScopeServiceTests.swift`

- [ ] **Step 1** Write failing tests against the service for the parts that are pure: ordered
      selection, the pasteboard payload for a mixed selection, and the AI context text.
- [ ] **Step 2** Move selection, pasteboard writing, drag providers, drop handling and the AI
      context builder out of `LauncherView+ClipboardScope` into `ClipboardScopeService`. The dock
      keeps working by calling it — verify the dock scope by hand before touching the panel.
- [ ] **Step 3** Point the corner panel at the service: multi-select, paste-to-frontmost,
      drag out, drop in, ask-AI.
- [ ] **Step 4** Verify both surfaces by hand. The dock scope must behave exactly as before —
      this task can regress a working surface, which is its main risk.

---

### Task 6 (revised): Drag and drop worth the rest of the UI

Behaviour, not decoration. Each item is a thing the surface currently cannot do.

- [ ] **Step 1 — Selection.** Click selects, ⌘-click adds, ⇧-click extends, Escape clears,
      ⌘A selects the filtered set. Selection survives changing the source chip.
- [ ] **Step 2 — Drag out.** Dragging any selected row drags the whole selection. Images and
      files go as real file promises so a Finder drop writes actual files; text goes as text.
- [ ] **Step 3 — Drag image.** A stack of the first three thumbnails with a count badge, not
      the row screenshot macOS gives by default.
- [ ] **Step 4 — Drop in.** The whole card is a drop target while a drag is in flight: it lifts
      slightly, shows an accent rule, and names what will happen ("Add 3 images"). Dropping
      ingests them as clips. No drop target is drawn when nothing is being dragged.
- [ ] **Step 5 — Reorder is not a thing.** Clipboard history is chronological; dropping a clip
      onto the list must not imply it can be rearranged.
- [ ] **Step 6 — Verify by hand.** Synthetic drags cannot prove any of this; see the
      `synthetic-drags-do-not-start-real-drag-sessions` memory. Tests cover the providers and
      the payloads; the gesture itself is the user's to confirm.

---

### Task 5b: Clipboard search, before the "All" chip

Search covers clip text, and the text inside documents the clip points at.

**Files:** `Search/ClipboardPanelWindow.swift:291-330,716-830`, `Services/` (indexing), test
`Context-DockTests/ClipboardSearchTests.swift`

- [ ] **Step 1** Test `ClipboardPanelModel.visibleEntries` for query + source together: a query
      narrows within the selected app, and clearing it restores the list.
- [ ] **Step 2** Add `query` to the model; filter on clip text case- and diacritic-insensitively.
- [ ] **Step 3** Search icon leading the filter row; clicking it opens the field in place, the
      chips sliding right. Escape clears, then closes.
- [ ] **Step 4** Document contents: index text from file clips lazily, on first search, cached by
      URL and modification date. Never on ingest — that would make copying a file cost a read.
- [ ] **Step 5** Test: a clip whose text does not match but whose file contents do is found.

**Open question for the user:** how deep should document search go — plain text and PDF only, or
Office formats too? Start with text and PDF.

---

### Task 7: Apply the design language

- [ ] **Step 1** Sweep the three corner surfaces onto the spacing, type, radius and motion scales
      above. No behaviour changes in this task.
- [ ] **Step 2** Full suite, `graphify update .`, then hand back for a look.

---

## Order and why

Tasks 1, 3, 4 first: Task 1 is what makes the corner usable at all — until a corner question
stops opening the dock over the user's work, nothing else about it can feel finished — and 3 and
4 are small and visible beside it. Then 5 / 6 / 5b, the clipboard set, which touch nothing the
chat surfaces use. Task 2 needs Task 1. Task 7 last, so the polish lands on a layout that has
stopped moving.

**The one that can break something that works:** Task 5. Extracting the dock scope's guts into a
service puts a working 2429-line surface at risk to give the corner the same powers. Verify the
dock by hand after the extraction and before the panel is touched.
