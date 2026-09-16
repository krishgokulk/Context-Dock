# Dock result sheet — expansion without a window resize

Date: 2026-08-23
Status: approved, staged implementation

## The problem

The dock's result sheet opens as a half sheet: it expands, stops, and expands
again, or reveals an empty panel that rows pop into afterwards.

This is not a tuning problem. The dock animates **two independent geometries**
towards the same target and hopes they arrive together:

1. The **NSWindow frame**, set from `calculatedHeight`
   (`LauncherView+DockHeight.swift`), which sums status bar + context row + dock
   row + input bar + list.
2. The **SwiftUI card**, framed to `renderedDockHeight ?? calculatedHeight`
   (`LauncherView+ContextLifecycle.swift:51`).

`calculatedHeight` depends on content that arrives asynchronously — search
results, icons, a late menu group. So the height is a moving target: the window
commits a frame, rows land, and it commits another. The code says this in its
own comments:

- `LauncherView+KeyboardNavigation.swift:1413` — *"A reveal in flight owns the
  frame. Row churn must not interrupt it with a second setFrame — that is the
  'expands, stops, expands again' stutter."*
- `:1485` — *"The old implementation grew the transparent NSPanel first and then
  animated a shorter SwiftUI card inside it. That exposed an empty half-sheet."*
- `LauncherView+ContextLifecycle.swift:61` — *"The window height lags the content
  … the shorter card gets centered by the hosting view in a stale-tall window —
  the input visibly sinks for 'fewer results'."*

Every workaround in that file exists to referee the race:

| Workaround | Refereeing |
|---|---|
| 50 ms resize debounce | burst calls while typing |
| `heightDelta <= 24` deadband | list height settling |
| `stabilizesResize` presets | same, per preset |
| `pinnedTopY` | window walking up the screen as it grows |
| `isAnimatingDockFrame` guard | a second setFrame interrupting a reveal |
| `dockContentCommitDelay` | rows not yet laid out when the frame commits |
| `renderedDockHeight` | card and window disagreeing mid-flight |
| 5 × `.animation(nil, …)` | flicker caused by the above |

The corner pills built this week have none of these and are smooth, because
their window never resizes: it is fixed at the size of the largest thing it can
hold, and every morph is a SwiftUI frame change inside it.

## The change

Give the dock the same construction.

The launcher window becomes a **fixed-size transparent host**. The card is laid
out inside it at its natural height, pinned to the window's top edge (the
Spotlight model the code already aims at). Expansion becomes one SwiftUI
animation of the card. Nothing measures content to decide a window frame,
because no window frame depends on content.

With the race gone, the referees have nothing to referee and come out.

## Host sizing

Width: today's `calculatedWidth`, which depends on mode, not on content, and so
is not part of the race. It may still change the window frame — rarely, and
never mid-reveal.

Height: fixed for the session at the tallest the dock may ever be — the space
between the window's pinned top and the bottom of the visible frame, less a
margin. A longer result list scrolls inside its own panel rather than growing
the window, which is already true today (`effectiveHeight` is capped the same
way).

The host is re-sized only when the screen or the mode changes it, never when
content does.

## Click-through

A transparent window covering most of the screen must not swallow clicks meant
for what is underneath. Its content view returns `nil` from `hitTest` for any
point outside the card, exactly as the corner shell does — verified this week by
closing a Finder window through the shelf's edge strip.

This is the one genuinely new risk the change introduces and it is verified
first, before any workaround is removed.

## Staging

Each stage builds, runs, and is looked at before the next begins. The order
exists so that the risky part is proven while the old machinery is still there
to fall back on.

1. **Host + click-through.** Fixed-size transparent host, card pinned top,
   `hitTest` passthrough. The existing sizing path stays and keeps running.
   Verify: dock opens, looks right, and clicks pass through the empty region.
2. **Stop resizing on content.** `updateWindowSize` no longer commits frames for
   content changes; the card animates instead. Verify: expansion is one motion,
   no half sheet, no input sink.
3. **Remove the referees**, one at a time, verifying between: content-commit
   delay, `isAnimatingDockFrame` guard, deadband, `stabilizesResize`, debounce,
   `renderedDockHeight`, `pinnedTopY`.
4. **Revisit the `.animation(nil, …)` suppressions.** Each was added to stop
   flicker the race caused. Restore animation only where the flicker is gone.

Stopping after any stage leaves a working dock. That is the point of the order.

## Performance

The constraint is that this must not cost performance. It should reduce it:

- Removing per-keystroke `setFrame` removes a window-server round trip and a
  shadow invalidation from the typing path.
- `calculatedHeight` stops being computed on every content change.
- The debounce Task per resize request goes away.

What to watch: a large transparent window costs more to composite than a small
one. If that shows up, the host shrinks to the largest *plausible* dock height
rather than the whole visible frame.

## What is not changing

Mode and layer behaviour, the search engine, the result rows, the input bar, and
every product rule about which surface does what. This is a change to how one
window is sized, not to what the dock does.

## Verification

Per stage, in the running app: open the dock, type until results land, watch the
expansion; collapse; switch modes; check the input bar never moves vertically
while typing; click through the empty region into another app.

The suite stays green throughout, but it cannot prove this change — the failure
mode is visual, so every stage ends with eyes on the screen.
