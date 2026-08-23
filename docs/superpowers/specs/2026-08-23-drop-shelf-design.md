# Drop Shelf — design

Date: 2026-08-23
Status: approved, not yet implemented

## The problem

Moving a file between two apps on macOS means keeping both windows on screen at
once, or making a round trip through the Desktop. A shelf breaks the drag in
half: drop a thing somewhere it will wait, go find the destination, drag it out
again. The waiting place has to survive the apps that produced the item — it
outlives the Finder window, the download, and the restart.

Context Dock already watches what the user copies. It does not watch what the
user drags, and dragging is where the other half of the work happens.

## Goal

A shelf that accepts anything dragged onto it — files, text, URLs, images —
holds it until the user removes it, keeps it in a folder they could open in
Finder and understand without explanation, and hands it back out to any other
app by dragging.

## Non-goals

- No syncing, no sharing, no cloud.
- No editing of held items. The shelf stores; it does not transform.
- Not a file manager. Removing an item removes it from the shelf, nothing more.
- Not a clipboard. Copying does not put anything on the shelf, and dropping does
  not put anything on the clipboard.

## Surface

The Drop Shelf is its **own surface**, with its own window and its own store.
It is not part of the clipboard pill, and neither one reads the other's state.
Context Dock's rule is that surfaces keep one job each; a shelf that was
secretly the clipboard would break the guarantees of both — a copy would appear
to be a drop, and clearing one would clear the other.

What they share is the corner. Both live bottom-right, both use the same shell,
metrics, and morph behaviour, so the corner reads as one place with two things
in it rather than two competing widgets.

### Placement and coexistence

The shelf pill occupies the bottom-right corner, the same anchor as the
clipboard pill.

While a drag is in progress the clipboard pill **hides** and the shelf pill owns
the corner. A drag is not a copy, so nothing is lost by standing the clipboard
down for the duration, and it removes the only case where two pills would fight
for the same pixels and the same pointer. When the drag ends the clipboard pill
returns to its normal ambient behaviour.

When the shelf holds items and no drag is in progress, the shelf pill sits
directly above the clipboard pill in the same corner, bottom-anchored, with a
gap between them. Either can be hovered independently.

### States

```
hidden      shelf is empty and no drag is happening
inviting    a drag is over the drop area; the pill is visible and lit
holding     shelf has items; collapsed pill shows the count
expanded    pointer is on the pill; card of items, each removable and draggable
```

## Detecting a drag

macOS does not broadcast "a drag has started somewhere". There is no
notification, and polling cannot see it.

The shelf is therefore **its own drop target, always present and invisible**: a
transparent panel pinned across the bottom edge of the screen, registered for
dragged types. It paints nothing until `draggingEntered` fires, at which point
it reveals the pill in the corner.

The window must not interfere with anything else on screen. Its content view
overrides `hitTest` to return `nil`, so ordinary mouse events pass straight
through to whatever is underneath; drag events still route to a registered
dragging destination, which is a separate path from hit testing. The window is
`.nonactivatingPanel`, `.borderless`, floating, and joins all Spaces.

This is the single riskiest assumption in the design and is verified first —
see Verification.

## Storage

Root: `~/Library/Application Support/Context-Dock/Shelf/`

Every drop is **copied** into the shelf, which then owns its copy. The original
is never moved, never modified, and never depended on: an item survives the
original being renamed, moved, deleted, or the Downloads folder being emptied.

Layout is type first, date second:

```
Shelf/
  Images/
    2026-08-23/  IMG_4822.PNG
  Documents/
    2026-08-23/  report.pdf
  Text/
    2026-08-23/  note-0312.txt
  Links/
    2026-08-23/  figma-board.webloc
  Archives/
  Other/
  index.json
```

Type first because the question people actually ask is "where are the
screenshots I dropped", not "what did I drop on Tuesday".

### Kind classification

Kind comes from `UTType` conformance, never the filename extension. The checks
are **ordered and first match wins** — the broad types overlap the narrow ones,
so an unordered set of rules would file a PNG under Documents:

| Order | Kind | Rule |
|---|---|---|
| 1 | Text | dropped text with no file of its own |
| 2 | Links | dropped URL with no file of its own |
| 3 | Other | the URL is a directory |
| 4 | Images | conforms to `.image` |
| 5 | Archives | conforms to `.archive` |
| 6 | Documents | conforms to `.pdf`, `.text`, `.spreadsheet`, `.presentation`, or `.content` |
| 7 | Other | anything else, including a type that cannot be resolved |

A dropped folder is copied whole and filed under Other.

### Naming and collisions

The item keeps its original filename. If that name is taken in the destination
folder, a numeric suffix is appended (`report 2.pdf`), never an overwrite — two
dropped files with the same name are two different items and the shelf must not
silently destroy one.

### Text and URL drops

Dropped text and dropped URLs have no file of their own, so the shelf makes one:
text becomes a real `.txt`, a URL becomes a real `.webloc`. Without this they
could be shown but never dragged back out, which would make them second-class
items in the one operation the shelf exists for.

Text files are named from their first line, truncated, with a timestamp
fallback when the text has no usable first line.

### index.json

Beside the kind folders, recording per item: id, relative path, kind, original
filename, source application name and bundle id, and drop timestamp. It is the
display order and the metadata the folder structure cannot carry.

The files on disk are the truth. If `index.json` is lost or corrupt it is
rebuilt by walking the folders; items reappear with their metadata reduced to
what the filesystem knows.

## Item lifecycle

Items persist across restarts and stay until the user removes them. There is no
expiry and no cap — a shelf that quietly threw work away would be worse than no
shelf.

Removing an item deletes the shelf's copy and its index entry. The original the
user dropped is untouched, because the shelf only ever held a copy of it.

## Dragging out

Items are dragged out as file URLs. The shelf owns real files on disk, so this
needs no file-promise machinery — the provider hands over the URL and the
receiving app copies from it.

An item dragged out is **not** removed. Dragging out is a read.

## Components

| File | Responsibility |
|---|---|
| `Services/DropShelfStore.swift` | Owns the folder, ingest, classification, naming, index, removal. No UI. |
| `Services/DropShelfItem.swift` | The item model plus its Codable index representation. |
| `UI/DropShelfWindow.swift` | The invisible edge drop target and the corner pill window. |
| `UI/DropShelfPill.swift` | Collapsed pill and expanded card, mirroring the clipboard pill's shell and morph. |

`ClipboardPanelController` gains one thing only: a way to stand the clipboard
pill down while a drag is in flight, and bring it back afterwards. No shared
state beyond that.

## What is testable without UI

These are pure and get tests first, in this order:

1. Kind classification from `UTType`, including the folder case.
2. Destination path building: kind folder, date folder, and the collision
   suffix — including that the suffix never overwrites.
3. Text materialization: naming from first line, truncation, and the fallback
   when there is no usable first line.
4. URL materialization into `.webloc`.
5. Index add, remove, and reload, including that removal deletes the copy.
6. Index rebuild from a folder walk when `index.json` is missing or corrupt.
7. Store reload ordering (newest first).

The store takes its root directory by injection, exactly as
`ClipboardPanelModel` takes its `storeURL`, so every test runs against a
temporary directory and never the user's real shelf.

Drag plumbing and the morph are verified in the running app, the same way the
clipboard pill was.

## Verification

Before any UI work, prove the invisible edge window is harmless:

1. With the shelf window live, drag a file onto the Dock, onto a Finder window,
   and between two other apps. All must behave exactly as they did before.
2. Click through the bottom edge of the screen into whatever is underneath.
3. Confirm `draggingEntered` fires for a drag originating in another app.

If the edge window cannot be made harmless, the approach changes before
anything is built on top of it.

Then, in the running app: reveal on drag, drop of each kind, persistence across
a relaunch, drag back out into a third app, and removal.

## Risks

**The edge window swallows drags meant for other apps.** Verified first, above.
This is the assumption the whole design rests on.

**Large drops block the drop.** Copying a multi-gigabyte file cannot happen on
the main thread. Ingest is asynchronous; the item appears immediately in a
pending state and settles when the copy completes.

**A drop that fails halfway** leaves a partial file. Copies land at a temporary
name and are moved into place only when complete, so an interrupted copy leaves
nothing behind.

## Out of scope

Stacks or grouping of shelf items, tagging, search within the shelf, and any
automatic clean-up policy. All are reasonable later; none are needed for the
shelf to do its job.
