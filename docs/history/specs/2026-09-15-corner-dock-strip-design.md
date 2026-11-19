# Corner Global Context — the dock strip

**Date:** 2026-09-15 · **Branch:** `general-chat-agent` · **Brain issue:** #24
**As built (owner's review during Task 5, decision `8aa25547`):** dwell is **2 s**; the fold is
one morph — the field capsule becomes the strip capsule with the **magnifier as its first
item** (no separate circle, no two-stage split); hovering or clicking the magnifier, hovering
the field's small running-app pills, ← on an empty field, or any typed character moves between
the two; right-click on a strip icon is a **Dock-style card above the icon**; clipboard and
selection affordances join the strip as a **tools section** after the pins; the window row
takes the list's slot, centred over the field. Where the text below disagrees, this note wins.
**Surface:** the corner's **Global Context** pill only. Scoped app chat, General chat, CLI
scope and the `.chat` phase are untouched.

## Why

At rest the corner Global pill is a search field with four 22 pt running-app pills tucked into
its trailing edge. Nobody rests on a search field. The request is for the corner to rest as a
dock: the field folds away after a second of silence, the running apps stand at Dock size,
hovering one shows its windows, and the things reached for most — apps, global commands, files,
folders, CLI tools — can be pinned beside them. Typing brings the field back.

The reference for the fold is Apple's own Liquid Glass morph: separate glass shapes drift
together, blend, and settle as one capsule; the reverse buds a shape off again. SwiftUI on
macOS 26 does this natively with `GlassEffectContainer` + `glassEffectID`, so no custom shader
and no custom metaball drawing.

## Rules this design lives under

- **Unified Dock Surface** (CLAUDE.md): one shell, multiple modes. The dock strip is a *phase* of
  the existing corner Global pill, not a new floating container.
- **Sizes are pure functions of model state** (memory `corner-pill-size-must-be-pure`). The
  strip's size comes from `AppChatPromptMetrics`, never from a measured view.
- **One key monitor for every corner surface** (memory `corner-surfaces-share-one-key-monitor`).
  "Type to expand" is gated on the Global pill holding the keyboard.
- **Global Context is not Chat Mode.** The strip offers places to go; it does not answer.

## 1. State machine

`AppChatPromptPhase` gains `.dock`.

```
hidden ─summon─► prompt ──2 s idle, setting on, isGlobalScope──► dock
                        ──5 s idle, otherwise────────────────► mini ─8 s─► hidden   (today)
dock ──printable key / click field stub / re-summon──► prompt
dock ──Esc / click outside / Space switch───────────► hidden
```

- `.dock` is reachable only when `isGlobalScope` and `autoShrinkInputField` is on. Every other
  scope and phase keeps today's `idleDwell` (5 s) → `.mini` → dismiss path, unchanged.
- `.dock` has no dwell timer. `standDown()` from `.dock` is a no-op; `armForIdle()` is not
  called on entering it.
- Hover over the strip does **not** expand the field — it would fight the window row. Only
  typing, clicking the field stub, or re-summoning expands.
- A printable key while `.dock`: `set(.prompt)`, `query = <that character>`, focus the field.
  Handled in `CornerDockController`'s existing local key monitor, only when
  `chatPresentation` holds the keyboard and the Global pill is the visible surface.
- **Only printable characters expand.** Arrow keys, Tab, Return, Esc, Backspace and modifier
  chords keep the handlers the field has today, in every phase. In `.dock` with the field
  gone, → still runs `scopeIntoFirstRunningApp()` (steps into the first running app's scoped
  chat — which is a scope, so the pill leaves `.dock` for that scope's `.prompt`) and falls
  through to `chatPresentation.handleRightArrow`; ← still runs `handleLeftArrow`. Nothing the
  empty field did on an arrow key changes.
- `isPinned` (⌘P "keep open") and `isAnswering` block the shrink, as they block `.mini` today.
- Frontmost-app change while `.dock`: the strip updates in place; no phase change.
- `.suggesting` still idles back to `.prompt` first (today's rule), and `.prompt` then idles to
  `.dock` — so the list closes, then the field folds.
- `AppChatPromptModel.dockDwell: TimeInterval = 2`.

## 2. Shell, layout, morph

The Global pill body becomes one `GlassEffectContainer(spacing: 24)` holding two capsules, each
`.glassEffect(.regular, in: .capsule)` with a `glassEffectID` in one `@Namespace`:

```
prompt:  ┌ 🔍  Search apps, tools and me…  [🖥][💻][🧭][📷] ┐     (field capsule, as today)
dock:                     ┌ [🖥][💻][🧭][📷] │ [📁][⚡][📄] ┐   (strip capsule alone)
```

- **Field capsule** — `glassEffectID("field")`. On `.dock` it is removed from the container's
  hierarchy; SwiftUI morphs it into the strip capsule. The container's `spacing` lets the two
  blend as the field's width animates down. Reverse on expand. `withAnimation(.smooth(duration:
  0.45))`; `accessibilityReduceMotion` → `.opacity` crossfade, no morph.
- **Strip capsule** — `glassEffectID("dock")`. Icons **48 pt**, 8 pt gap, 10 pt capsule inset →
  strip height **68**. Left: running apps; 1 pt hairline divider; right: pins. Running dot
  under running icons, as today's 22 pt pills draw it.
- **Magnify** — hovered icon `scaleEffect(1.25)`, immediate neighbours `1.1`, spring
  `.snappy`. `.interactive()` on the strip's glass. Nothing beyond that; it is a strip, not a
  Dock clone.
- **In `.prompt`** the field row keeps today's 22 pt `ContextMatchDock` pills. The 48 pt strip
  exists only in `.dock`. (The two are the same data at two sizes; the morph carries the eye
  from one to the other.)
- **Metrics** — `AppChatPromptMetrics.size(for: .dock, running: n, pinned: p)`:
  `width = 20 + n·48 + max(0, n−1)·8 + (p > 0 ? 17 + p·48 + (p−1)·8 : 0)`, `height = 68`,
  width capped at `AppChatPromptMetrics.width × 1.6` (≈ 595). Past the cap the running section
  shows a `+N` pill through the existing `globalOverflowCount` path; pins are never overflowed
  (the user chose them). `CornerDockController.currentSlots()` reads this like every other
  phase.
- **Window row** — its own corner slot above the strip, like the clipboard preview: a glass
  card of thumbnails, one per on-screen window of the hovered app, max 6, each 160 × 100 with
  the window title beneath, anchored over the hovered icon and clamped to the screen. Appears
  250 ms after hover begins, hides 150 ms after the pointer has left both the icon and the row.
  Click a thumbnail → raise that window (AX `kAXRaiseAction` on the matching window element)
  and activate the app. Click the icon → activate the app (today's `openGlobalMatchIcon`).
  Its height is **not** part of the pill's metrics.

## 3. Data

### Pins — `Services/DockPinStore.swift` (new)

```swift
enum DockPinKind: Codable, Equatable {
    case app(bundleID: String)
    case globalCommand(id: String)      // GlobalSearchService system command / user global extension id
    case cliTool(name: String)
    case file(path: String)
    case folder(path: String)
}

struct DockPin: Codable, Identifiable, Equatable {
    let id: UUID
    let kind: DockPinKind
    var title: String
    var order: Int
}

@MainActor final class DockPinStore: ObservableObject {
    static let shared: DockPinStore
    @Published private(set) var pins: [DockPin]         // sorted by order
    func pin(_ kind: DockPinKind, title: String)         // no-op if that kind is already pinned
    func unpin(_ id: UUID)
    func move(from: Int, to: Int)
}
```

- Persisted as `dock-pins.json` under `~/Library/Application Support/Context-Dock/` through
  `ContextDockStore.write/read` (debounced, hash-deduped like everything else there).
- Icons are resolved at draw time — `NSWorkspace` for apps and files, the command's own icon
  for global commands, the CLI icon for tools — and never persisted.
- The legacy `PinnedApp` / `PinnedAppsRow` (launcher, `AppSettings.pinnedApps`) is left alone.
  It is a different surface with a different lifetime; folding the two is not this work.

### Running section

- Source: `model.globalMatchIcons` — untyped, that is already "every running app" in the
  dock's order, with `globalOverflowCount` for the rest.
- `AppChatPromptModel.hiddenRunningBundleIDs: Set<String>` — session-only, cleared on relaunch.
  "Remove from strip" adds to it; the app reappears next launch, like a Dock icon that was
  only dragged out while running.
- An app that is both running and pinned draws **once**, in the pinned section, with its
  running dot.

### Pin entry points

| Gesture | Where | Result |
|---|---|---|
| Right-click a Global result row → **Pin to dock** | `AppChatListCard` rows | `DockPinStore.pin(kind)` — rows that map to no `DockPinKind` (menu items, snapshots, extension panels) show no item |
| Drop onto the pinned section | strip | file URLs from `NSItemProvider` → `.file` / `.folder`; the corner's own row-drag payload → its kind |
| Right-click a running icon | strip | **Pin to dock** · **Remove from strip** · **Quit** |
| Right-click a pinned icon | strip | **Unpin** · **Show in Finder** (files/folders) |
| Drag a pinned icon out of the strip and release | strip | unpin |
| Drag within a section | strip | reorder (pins persist order; running order is the dock's, not draggable) |

Mapping `SearchResult` → `DockPinKind` is one pure function, `DockPinKind.init?(result:)`, so
the context menu and the drop handler agree.

### Window thumbnails — `AppWindowSnapshotService` (extend)

Today: one image per bundle ID (`snapshot(for:)`, `refresh(bundleID:)`) via `SCShareableContent`
+ `SCScreenshotManager`. Add:

```swift
struct WindowSnapshot: Identifiable { let id: CGWindowID; let title: String; let image: NSImage? }
func windowSnapshots(for bundleID: String) -> [WindowSnapshot]   // cached
func refreshWindows(bundleID: String)                             // on hover; 2 s cache
```

Windows filtered on bundle ID, on-screen, layer 0, non-zero size, then captured one by one.
Capture stays off the main actor as it does now.

## 4. Settings, failure, tests

**Setting.** `GeneralSettingsView` gains a row in its existing corner/behaviour section:
"Auto-shrink the search field" — `@AppStorage("autoShrinkInputField") var autoShrinkInputField
= true`. Help text: *After 2 seconds with nothing typed, the corner's search field folds into the
dock strip. Typing brings it back.* Off → behaviour identical to HEAD.

**Failure.**
- No Screen Recording permission: the window row shows the app icon and window titles (from
  AX) with no images. No permission prompt is raised from a hover; the existing snapshot path's
  prompt policy stands.
- Pinned file or folder no longer on disk: icon dims to 40 %, click reveals its parent in
  Finder, context menu offers Unpin. Pinned app not installed: same, click does nothing.
- Global command whose extension was removed (`appPanelToolRemoved` / global extension
  removal): pin dims; Unpin available. Not auto-removed — the user placed it.
- Zero running apps and zero pins (fresh machine, only Finder): the strip still draws Finder;
  it never draws empty.

**Tests** (`Context-DockTests/`, swift-testing, offline):
- `CornerDockPhaseTests` — `.dock` reachable only from `.prompt` when `isGlobalScope` and the
  setting is on; never from a scoped chat, General, CLI, `.chat`; `.dock` never times out;
  printable key → `.prompt` with the character seeded; → on `.dock` calls `scopeIntoFirstRunningApp()` exactly as on an empty `.prompt` field and ← calls `handleLeftArrow`, neither seeds a character; `isPinned`/`isAnswering` block it;
  setting off → the existing `.prompt → .mini → hidden` sequence, dwell values unchanged.
- `AppChatPromptMetricsDockTests` — widths for (n, p) ∈ {(1,0), (4,0), (4,3), (12,0), (12,5)},
  the cap, overflow count, and that pins are never overflowed.
- `DockPinStoreTests` — round-trip through `ContextDockStore`, dedupe on `kind`, `move`
  renumbers `order`, unpin of a missing id is a no-op.
- `DockPinKindMappingTests` — one `SearchResult` per kind maps; menu item / snapshot / panel
  rows map to `nil`.
- `WindowSnapshotFilterTests` — the window filter on a fixture list (bundle ID, on-screen,
  layer, size).

**Manual only** (record on #24 when checked): the morph itself, magnify, the window row's
timing, every drag gesture (memory `synthetic-drags-do-not-start-real-drag-sessions`), reduced
motion, light and dark.

## Out of scope

- Folding legacy `PinnedApp` into `DockPinStore`.
- A dock strip in scoped app chat or General chat.
- Folder pins that open as a grid/fan (macOS Dock stacks). A folder pin opens in Finder.
- Badging (unread counts) on running icons.
- The strip staying on screen when the corner is not summoned ("always on") — considered and
  declined: the corner never becomes a permanent fixture.

## Files

New: `Services/DockPinStore.swift`, `UI/CornerDockStrip.swift`, `UI/CornerWindowRow.swift`,
tests above.
Changed: `UI/AppChatPromptModel.swift` (phase, dwell, hidden set, key seed),
`UI/AppChatPromptPill.swift` (container, two capsules, metrics), `UI/CornerDockWindow.swift`
(key monitor gate, window-row slot), `UI/AppChatListCard.swift` (row context menu),
`Services/AppWindowSnapshotService.swift` (per-window), `UI/LegacySettingsContent.swift`
(General toggle), `App/AppSettings.swift` (`autoShrinkInputField`).
