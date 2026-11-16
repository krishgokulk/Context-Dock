# Motion and Navigation Performance Architecture

This document defines the motion, tactile feel, and navigation performance architecture for Context-Dock, benchmarking against top-tier macOS launchers including **Lumio** (`cavaldos/Lumio`), **Spotlight**, and **Raycast**.

---

## 1. The Smoothness Gap: Why Traditional Launchers Feel Clunky

In standard SwiftUI launcher implementations (and earlier versions of Context-Dock):
1. **Independent Row Crossfades:** Each row independently conditionally renders its own background (`Color.primary.opacity(isFocused ? 0.10 : 0)`). When navigating between rows, one row fades out while the next fades in. During fast keystrokes, two rows are simultaneously half-highlighted or ghosting occurs.
2. **The 0ms Jump Hack:** To avoid the dual-highlight ghosting, teams often resort to `.transaction { $0.animation = nil }`. While this eliminates the crossfade artifact, it degrades the interface into a jarring, 0ms teleporting experience that lacks physical momentum and tactile weight.
3. **Stationary Mouse Jitter (Pointer Fighting):** As lists scroll or search results refresh under a resting mouse cursor, standard SwiftUI `.onHover` fires on whichever row happens to pass under the cursor. This steals selection away from keyboard navigation, causing the selection highlight to bounce erratically between keyboard focus and mouse hover.
4. **Desynchronized Scrolling:** Scrolling the container via `ScrollViewReader.scrollTo` using an arbitrary duration curve (e.g. `.easeOut(0.12)`) while the selection state updates at a different rate causes the selection pill and scroll viewport to move out of phase.
5. **Static Icons:** Icons remain rigid and lifeless when stepped into, failing to give tactile visual confirmation of selection.

---

## 2. The 5 Core Architectural Techniques (The Lumio Benchmark)

Lumio achieves its signature native Spotlight-like feel through 5 core motion techniques. Context-Dock formalizes these into reusable primitives in `Context-Dock/UI/FluidSelection.swift`.

### 1. Single Continuous Gliding Capsule (`matchedGeometryEffect`)
Instead of $N$ separate highlights fading independently, there is **only one physical selection pill** rendered across the list's `@Namespace`. When the focused index changes, SwiftUI translates and morphs the single capsule from the previous row’s frame to the new row’s frame using hardware-accelerated CoreAnimation layers.

```swift
// FluidSelection.swift
public struct FluidSelectionPill: ViewModifier {
    public let isSelected: Bool
    public let namespace: Namespace.ID
    // ...
    public func body(content: Content) -> some View {
        content.background {
            if isSelected {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(strokeColor, lineWidth: 0.5))
                    .padding(.horizontal, paddingHorizontal)
                    .matchedGeometryEffect(id: "fluidSelectionPill", in: namespace)
            }
        }
    }
}
```

### 2. Damped Spring Physics (`FluidMotion.selectionGlide`)
Zero-teleportation, zero-overshoot motion. The capsule uses an critically damped spring:
- `response: 0.28s`
- `dampingFraction: 0.85`

This response is fast enough to keep up with rapid 30Hz arrow key repeats without lagging behind, yet damped enough to arrive at target rows with zero oscillation or bounce.

### 3. Pointer Motion Gate (`MouseGate`)
To eliminate the conflict where stationary mouse cursors fight keyboard navigation when rows scroll or update:

```swift
@MainActor
public final class MouseGate {
    private var lastLocation: NSPoint = NSEvent.mouseLocation

    public func moved() -> Bool {
        let current = NSEvent.mouseLocation
        let dx = abs(current.x - lastLocation.x)
        let dy = abs(current.y - lastLocation.y)
        guard dx > 1.5 || dy > 1.5 else { return false }
        lastLocation = current
        return true
    }
}
```
Rows gate `.onHover` behind `mouseGate.moved()`. If the mouse is stationary, hover events are ignored, allowing arrow keys to glide freely through lists even if the cursor is resting squarely in the middle of the result sheet.

### 4. Leading Icon Micro-Zoom Beat (`FluidIconZoom`)
When a row steps into focus, its leading icon performs a subtle micro-zoom beat (scale $1.08\times$) powered by a responsive spring (`response: 0.22, dampingFraction: 0.65`). This provides immediate visual feedback and tactile haptics to the user's eyes before reading the title text.

```swift
public struct FluidIconZoom: ViewModifier {
    public let isFocused: Bool
    public func body(content: Content) -> some View {
        content
            .scaleEffect(isFocused ? FluidMotion.iconScale : 1.0)
            .animation(FluidMotion.iconPop, value: isFocused)
    }
}
```

### 5. Synchronized Viewport Spring Scrolling
`proxy.scrollTo` must run inside `withAnimation(FluidMotion.selectionGlide)`. The scroll viewport and the gliding selection capsule move along the **identical mathematical curve**, eliminating relative jitter between the item and the list container.

---

## 3. Engineering Guidelines for Lists & Surfaces

Any surface in Context-Dock that displays navigable items (Search Results, Menus, App Switchers, Slash Pickers, Action Sheets) must adhere to these rules:

### Standard Implementation Pattern

1. **State & Namespace:**
   ```swift
   @State private var mouseGate = MouseGate()
   @Namespace private var selectionSpace
   ```

2. **Container Animation:**
   Add `.animation(FluidMotion.selectionGlide, value: focusedIndex)` to the row container `VStack`.

3. **Row Highlight & Icon:**
   ```swift
   rowIcon
       .fluidIconZoom(isFocused: isFocused)

   rowContent
       .fluidSelection(isSelected: isFocused, namespace: selectionSpace, cornerRadius: 8, paddingHorizontal: 8)
   ```

4. **Hover Handling:**
   ```swift
   .onHover { hovering in
       if hovering, mouseGate.moved() {
           withAnimation(FluidMotion.selectionGlide) {
               model.focusedIndex = index
           }
       }
   }
   ```

5. **Scroll Synchronization:**
   ```swift
   .onChange(of: model.focusedIndex) { _, index in
       guard let index, model.rows.indices.contains(index) else { return }
       withAnimation(FluidMotion.selectionGlide) {
           proxy.scrollTo(model.rows[index].id)
       }
   }
   ```

---

## 4. Current Adoption Across Context-Dock

The fluid navigation architecture is actively implemented across all primary launcher surfaces:
- **`AppChatListCard.swift`**: All rows (`commandRow`, `cliSuggestionRow`, `appRow`, `askAIRow`, `fileRow`, `globalRow`, `dockRow`, `actionRow`).
- **`SelectionScopeCard.swift`**: All action rows and Finder file inspection rows.
- **`ChatSlashAppPicker.swift`**: `/` quick app jump popover.
- **`ChatSlashModPicker.swift`**: `/mods` Pet mode selector popover.
- **`FluidSelection.swift`**: Shared core primitives (`FluidMotion`, `MouseGate`, `FluidSelectionPill`, `FluidIconZoom`).
