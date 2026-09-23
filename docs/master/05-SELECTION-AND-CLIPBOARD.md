# 05 — Selection Shortcut Sheet + Clipboard scope

> **Status: DRAFT / under review — written against current code (audit-clean).** Not merged yet.
> Tags: `[code]` verified in source · `[owner]` owner's stated knowledge · `[?]` needs confirmation.

Two related corner surfaces: the **Selection Shortcut Sheet** (act on what's selected) and the
**Clipboard** ambient pill (act on what you copied). Both are corner cards, siblings of the
dock and chat — not the launcher.

---

## A. Selection Shortcut Sheet

### A1. One job
**A selection-aware action engine.** `[code — SELECTION_SHORTCUT_SHEET.md]` On **long-press
Command**, show actions for the current selection and run the chosen one. Explicitly *not*
Global Context — it must not become app/file search or general chat.

### A2. Inputs `[code]`
Selected text · selected file/folder · selected image · selected URL · browser URL/title ·
clipboard text/file/URL · frontmost app · current window title.

### A3. Action sources `[code]`
Built-in selection extensions · user-created extensions · frontmost app menu actions · app
adapters · macOS Shortcuts · AI actions.

### A4. How it works
`SelectionScopeModel` renders the selection **as a card in the corner** — a sibling of the
clipboard, drop-shelf and chat surfaces (not the old "launcher drawn as a pill"). `[code —
UI/SelectionScopeModel.swift]`

**Critical timing:** the selection is read **once, when the hotkey fires and the source app is
still frontmost**. Reading later would capture whatever is selected in Context Dock's own
window — which is nothing. `[code]` This is a real correctness constraint worth preserving.

Related UI: `SelectionScopeCard`, `AppChatSelectionScope`, `DropShelfWindow` (drag targets),
`CornerDockStrip` / `CornerDockWindow` (the corner surface family).

---

## B. Clipboard scope

### B1. One job
An **ambient clipboard surface**: a pill that slides into the bottom-right corner on every
copy and grows, under the pointer, into a card of recent clips. `[code — ClipboardPanelWindow.swift]`

### B2. Key design facts `[code]`
- **Independent of the dock's state** — it deliberately does *not* touch LauncherView's
  `activeSmartQueryKey` or dock-layer state, so Context Dock can be opened and used while the
  clipboard pill is on screen. (This independence is why the layer rule holds here.)
- **Fixed-size transparent panel** — the pill→card morph is a pure SwiftUI frame animation
  inside a fixed window, never an `NSWindow` resize (resizing a window frame stutters; the
  whole point is a smooth morph).
- History rendering (`LauncherView+ClipboardScope.swift`) caches thumbnails and app icons;
  clips can be text/file/URL/image. `ClipboardPreviewScratchFile` backs previews.

### B3. Relationship to selection
Clipboard content is *also* an input to the Selection Shortcut Sheet (A2) — the two share the
idea of "act on this content", but the clipboard pill is ambient (fires on copy) while the
selection sheet is invoked (long-press ⌘).

---

## C. Boundaries

- Selection/clipboard are **not** the launcher, **not** app search, **not** general chat.
- They feed content *into* actions and (optionally) into a chat scope, but they own the
  "act on this selection/clip" job only.

---

## D. Engineering map

| Concern | File |
|---|---|
| Selection card model | `UI/SelectionScopeModel.swift`, `UI/SelectionScopeCard.swift` |
| Selection → chat scope | `UI/AppChatSelectionScope.swift` |
| Clipboard ambient window | `Search/ClipboardPanelWindow.swift` |
| Clipboard history/render | `Search/LauncherView+ClipboardScope.swift` |
| Clipboard preview | `UI/ClipboardPreviewCard.swift`, `Search/ClipboardPreviewScratchFile.swift` |
| Corner surface family | `UI/CornerDockStrip.swift`, `UI/CornerDockWindow.swift`, `UI/DropShelfWindow.swift` |

---

## E. Known gaps / open questions

1. **Selection read-timing** is a single point of failure — if the hotkey path changes, the
   "read while source app frontmost" invariant must be preserved. Document as a guarded
   invariant. `[code]`
2. **Clipboard history retention/privacy** — how long clips are kept, whether sensitive clips
   (passwords) are excluded, and where the scratch files live, is `[?]` and a privacy-review
   item.
3. **No tests** on selection capture or clipboard morph state. `[gap]`
4. Overlap between selection actions and Context Dock actions (both surface app menu actions +
   adapters) — confirm the boundary is "selection-triggered" vs "app-triggered". `[owner]`

---

*End of draft. Redline directly; merges after owner confirmation.*
