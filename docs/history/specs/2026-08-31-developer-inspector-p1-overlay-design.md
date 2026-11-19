# Developer Inspector P1 Overlay — Design

**Date:** 2026-08-31  
**Status:** approved in conversation, pending implementation plan  
**Parent design:** `docs/superpowers/specs/2026-08-26-developer-inspector-design.md`  
**Foundation:** `docs/superpowers/plans/2026-08-31-developer-inspector-p0.md`

## Goal

Turn the invisible P0 inspection registry into a DEBUG-only interactive developer tool. A
developer can toggle Inspect Mode, hover an instrumented DoraX region, lock it, and read its
stable identity and source metadata without changing product behaviour or capturing a bug
packet.

## P1 boundary

P1 includes:

- fixed DEBUG-only `⌥⌘I` activation;
- hover highlighting and an InspectID label;
- `⌥`-click selection locking;
- a non-activating detail panel;
- exact teardown of event monitors and overlay windows;
- automatic reconciliation with window and registry lifecycle;
- focused unit/AppKit tests and one manual General Chat proof.

P1 excludes screenshots, user notes, ViewModel-state serialization, source-candidate ranking,
bug packets, DiagnosticsPanel integration, IPC, scenarios, repair sessions, CLI handoff, and
automated rebuilds. `[Capture Bug]` is not shown until the packet workflow exists.

## Architecture

Use one transparent, non-activating overlay attached to each eligible DoraX window containing
registered regions. Do not use one screen-sized capture window and do not inject highlight
state into product SwiftUI surfaces. Window-attached overlays preserve the P0 coordinate
contract and keep developer infrastructure outside the product-layer hierarchy.

`InspectorSessionController` is the single DEBUG-only owner of Inspect Mode. It owns event
monitors, overlay reconciliation, hover state, locked selection, and the detail panel. Product
views continue to emit only metadata through `.doraxInspect`; they do not read Inspector state.

## Components

### InspectorSessionController

`@MainActor final class InspectorSessionController` owns the session lifecycle:

- `isEnabled`: whether Inspect Mode is active;
- `hoveredKey`: the current preview target;
- `lockedKey`: the selected target, if any;
- installed local/global event monitor tokens;
- overlay controllers keyed by `InspectWindowID`;
- the single detail-panel controller.

Enabling is idempotent. It sets `InspectRegistry.emitsChanges = true`, captures any window flags
that P1 must temporarily change, installs monitors, and reconciles overlays. Disabling is also
idempotent and removes every monitor and overlay, closes the detail panel, clears hover/lock
state, restores captured window flags exactly, and sets registry emission back to false.

The controller receives registry-revision changes only while enabled. A revision triggers
reconciliation, not direct drawing: stale windows are removed, newly eligible windows gain an
overlay, and missing hovered or locked keys are cleared.

### InspectorOverlay

Each eligible DoraX window receives one transparent child overlay window covering its content
root. It is borderless, non-activating, excluded from normal window ownership decisions, and
never becomes a product surface. It draws at most:

- a translucent stroke/fill around the hovered or locked registration;
- a compact label containing the semantic `InspectID` and derived ordinal.

The overlay does not capture screenshots, serialize state, or perform hit testing. It renders
the state supplied by the session controller. Overlay geometry follows its owner window during
move, resize, hide, show, and close.

### InspectorDetailPanel

There is one shared non-activating detail panel. It opens only for a locked registration and
shows:

- semantic ID and zero-based derived ordinal;
- `#fileID:#line`;
- enclosing type;
- frame in window-root coordinates;
- owning window ID;
- precision text: `Exact instrumented region` or `Nearest instrumented ancestor`.

P0 does not currently encode descendant coverage, so P1 labels a hit as an ancestor only when
the pointer lies inside an instrumented region and no more-specific registered child contains
it. This is a presentation statement about registry precision, not a claim about the exact
SwiftUI leaf under the pixel.

### InspectorHotkey

P1 registers fixed `⌥⌘I` only in DEBUG builds. It is not user-configurable and does not appear
in production hotkey settings. Registration occurs after normal app startup is established and
is removed during termination. A registration conflict fails closed and logs a developer-only
diagnostic; it must not replace a product hotkey silently.

### P0 bridge additions

`InspectRegistry` gains read-only APIs for registered window IDs and exact-key lookup. These
return snapshots and do not expose mutable storage.

`InspectModifier` extends its private root bridge so the session can resolve an
`InspectWindowID` to weak references for the owning `NSWindow` and inspection-root `NSView`.
This mapping is DEBUG-only, purged when the root leaves its window, and never invents window
zero. Coordinate conversion remains exactly:

```swift
let windowPoint = window.convertPoint(fromScreen: screenPoint)
return rootView.convert(windowPoint, from: nil)
```

## Interaction model

### Toggle

`⌥⌘I` toggles the whole session. While disabled, there are no Inspector overlays or Inspector
event monitors, registry emission is disabled, and existing `acceptsMouseMovedEvents` values
remain untouched.

### Hover

While enabled and not locked, pointer movement identifies the DoraX window under the pointer,
converts the screen point into that window's registered inspection-root coordinates, and calls
`InspectRegistry.hitTest`. The smallest matching region wins according to the P0 ordering.

Hover is preview-only. Pointer movement never captures screenshots, serializes state, opens a
panel, or mutates product state. Repeated movement over the same registry key does not redraw
or publish a new state transition.

### Lock

`⌥`-click on a hovered registration stores its exact `InspectRegistryKey`, freezes the visual
selection, and opens the detail panel. Clicking without Option is passed through unchanged.
`⌥`-click outside a registered region clears the current lock without triggering product
actions.

The monitor consumes only the Option-click used by Inspect Mode. No synthetic mouse or keyboard
events are generated.

### Escape and teardown

Escape follows two stages:

1. if a target is locked, clear the lock and close the detail panel while leaving Inspect Mode
   enabled;
2. otherwise disable Inspect Mode completely.

App termination, controller deinitialization, or loss of required window/root bindings performs
the same complete teardown as an explicit disable.

## Window reconciliation

An eligible window has all three of:

- a real `InspectWindowID`;
- a live owning `NSWindow` and inspection-root `NSView` binding;
- at least one current registry registration.

Reconciliation derives eligibility from snapshots. It creates missing overlays, updates owner
frames, and removes overlays for ineligible windows. Window close purges registry entries and
root bindings unconditionally. A recreated NSWindow with a different window number receives a
new overlay and cannot revive the previous window's lock.

## Failure handling

The subsystem fails closed:

- missing window/root mapping: no overlay and no hit;
- stale hovered key: clear hover;
- stale locked key: clear lock and close the panel;
- hotkey conflict: leave Inspect Mode unavailable and log the conflict;
- coordinate conversion unavailable: do not approximate with SwiftUI `.global` or screen
  arithmetic;
- overlay creation failure: skip that window without affecting product interaction;
- repeated enable/disable calls: no duplicate monitors, overlays, or panels.

No P1 failure may prevent General Chat, Context Dock, Global Context, or other product surfaces
from operating normally.

## Test strategy

Pure controller/state tests cover:

- idempotent enable and disable;
- hover changes only when the resolved key changes;
- lock freezes hover presentation;
- Option-click outside clears a lock;
- first Escape clears lock and second Escape disables;
- stale hovered/locked registrations clear during reconciliation;
- recreated window IDs do not inherit locks;
- teardown removes every recorded monitor and overlay;
- registry emission is enabled only for an active session.

Registry/root-binding tests cover read-only window enumeration, exact-key lookup, replacement,
and purge. AppKit tests use borderless windows to verify overlay-owner frame following and
screen-to-root hit resolution without duplicating the conversion arithmetic.

Manual verification uses the one currently instrumented surface, General Chat:

1. launch through `./scripts/dev-run.sh`;
2. toggle with `⌥⌘I`;
3. hover General Chat and see `generalChat.thread` with no layout change;
4. Option-click to lock and verify panel metadata;
5. press Escape once to unlock and again to exit;
6. repeat open/close and enable/disable cycles;
7. confirm normal clicks and typing are unchanged when Inspect Mode is off;
8. confirm no capture button or bug-packet workflow exists.

## Delivery sequence

P1 is implemented in reviewable tasks:

1. registry/root-binding read APIs and lifecycle tests;
2. pure session state machine and teardown contracts;
3. per-window overlay rendering and reconciliation;
4. hover/click/Escape event routing;
5. fixed DEBUG hotkey, detail panel, and General Chat manual proof.

Every task uses focused tests, the complete offline suite, `./scripts/dev-run.sh`,
`graphify update .`, and `git diff --check`. Each task stops for user verification before the
next task. Existing unrelated working-tree changes remain untouched, and generated Graphify
changes are not staged.

## Self-review

- Scope: overlay interaction only; all packet, IPC, scenario, repair, and automation work is
  explicitly excluded.
- Layering: overlays observe registered product surfaces; they do not become modes or own chat
  state.
- Coordinates: every hit remains window/root explicit; no `.global`-to-screen shortcut exists.
- Cost: event monitors, registry revision emission, and overlay windows exist only while enabled.
- Input safety: only the explicit Option-click is consumed; no synthetic input exists.
- Lifecycle: enable, disable, window close, stale selection, and termination each have defined
  cleanup behaviour.
- Testability: controller transitions, registry bridges, AppKit geometry, and the real General
  Chat proof each have an assigned verification boundary.
