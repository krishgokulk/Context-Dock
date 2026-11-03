# Dynamic Bar Notch Experience & Unified Liquid Glass Design System

**Date:** 2026-11-03  
**Status:** Approved & Implementing  
**Reference:** [DynamicBar Developer Reference & AI Prompt Kit](https://kag1o.github.io/DynamicBar/developer.html#ai)

---

## 1. Executive Summary & Goals

Context-Dock provides a modular workspace companion on macOS containing an AI Prompt Launcher, Drop Shelf, Clipboard Manager, and App Context Scope. 

This initiative enhances Context-Dock with two core improvements:
1. **Dynamic Bar Notch Experience:** Transforms the top camera notch anchor into a responsive, Apple-grade Dynamic Island based on MacBook Air 2024 (M3) and modern MacBook Pro display geometry. Includes resting dual-wing status indicators, tactile hover-swell micro-interactions, drag-over file absorption into Drop Shelf, and smooth expansion to the open island layout with proper notch safe-area budgeting.
2. **Unified Liquid Glass Design System:** Unifies the translucent glass styling and customizable dark tint across **all** surfaces—Notch Island, Central Launcher (Spotlight view), Corner Dock (resting pill & strip), Drop Shelf card, Clipboard history board, and Selection scope card.

---

## 2. Hardware Geometry & DynamicBar Specifications

### 2.1 MacBook Air 2024 & Modern Display Metrics
- **MacBook Air 13.6" / 15.3" (M2/M3/M4):**
  - Camera Notch cutout: ~`190 pt` wide, `32 pt` tall (`screen.safeAreaInsets.top == 32`).
  - Menu bar height: `32 pt`.
- **MacBook Pro 14" / 16" (M1/M2/M3/M4 Pro/Max):**
  - Camera Notch cutout: ~`200 pt` wide, `36–38 pt` tall (`screen.safeAreaInsets.top == 36...38`).
- **External & Notchless Displays:**
  - Fallback virtual notch: Anchored flush at top center (`190 × 34 pt`), appearing smoothly when the pointer nears the top edge.

### 2.2 Island Dimensions & Safe Area Budget
```
┌────────────────────────────────────────────────────────────────────────┐ Top Bezel
│ Menu Bar (32pt)    ╭──────────────[Camera Cutout]─────────────╮        │
│                    │ ◀ Left Wing (50pt)   Right Wing (50pt) ▶ │        │ Closed Island
╰────────────────────┴──────────────────────────────────────────┴────────╯
                                      │
                                      ▼ (Hover / Click / Drag / Shortcut)
╭────────────────────────────────────────────────────────────────────────╮
│                         [Physical Camera Notch]                        │
│                                                                        │
│ ┌────────────────────────── Safe Area ───────────────────────────────┐  │
│ │ Top margin: 36 pt (strictly below camera cutout)                  │  │ Open Island
│ │ Horizontal insets: 32 pt left and right                           │  │ Default: 378 × 172 pt
│ │ Bottom inset: 26 pt                                               │  │ Max: 600 × 320 pt
│ │                                                                   │  │
│ │ [Launcher Field | Drop Shelf Tray | Clipboard Board | Selection]  │  │
│ └───────────────────────────────────────────────────────────────────┘  │
╰────────────────────────────────────────────────────────────────────────╯
```

* **Resting / Closed Island:** Width = `notchWidth + 100 pt` (~290–310 pt), Height = `notchHeight` (32–36 pt).
* **Open Island:** Default `378 pt` wide × `172 pt` tall. Grows dynamically up to `600 × 320 pt` for expanded boards and multi-turn conversations.
* **Safe Area:** Content must render within the safe area: `(width - 64) × (height - 62) pt` (314 × 110 pt at default size).

---

## 3. Unified Liquid Glass Visual System

The user settings provide a `Liquid Glass` toggle and a `Tint Slider` (`glassDarkness` from 0.0 pure clear glass to 1.0 nearly black smoked OLED glass).

### 3.1 Styling Architecture
All visual surfaces inherit the unified **`LiquidGlassModifier`**:
- **Backdrop Material:** `NSGlassEffectView` (macOS 26+) or `NSVisualEffectView` (`blendingMode = .behindWindow`, `state = .active`, `.hudWindow`/`.popover`).
- **Base Fill Tint:** Modulated by `AppSettings.shared.glassDarkness` (0% is clear crystal bending wallpaper light; 100% is deep smoked black).
- **Subtle Specular Rim:** 1 pt stroke (`Color.white.opacity(0.16)` in dark mode, `0.35` in light mode).
- **Smooth Corner Curves:** Continuous curvature (`.continuous`) with concave flare ears (`DynamicIslandNotchShape`) when anchored to the bezel.
- **Deep Ambient Drop Shadow:** 20 pt radius, 10 pt vertical offset, `Color.black.opacity(0.34)`.

### 3.2 Surface Parity Matrix
| Surface | Anchor / Mode | Corner Radius | Glass Tint Application |
| :--- | :--- | :--- | :--- |
| **Top Notch Island** | `.notch` (Top Center) | 20 pt + Bezel Ears | Unified Liquid Glass + concave bezel ears |
| **Launcher View** | `.center` (Spotlight) | 22 pt / Capsule | Unified Liquid Glass + specular highlight |
| **Corner Dock Strip** | `.right` / `.left` / `.notch` | 18 pt / Capsule | Unified Liquid Glass + icon magnification |
| **Drop Shelf Card** | Open Shelf Card | 22 pt | Unified Liquid Glass (shared tint) |
| **Clipboard Board** | Result Board / Card | 22 pt | Unified Liquid Glass (shared tint) |
| **Selection Card** | Context Transform Card | 22 pt | Unified Liquid Glass (shared tint) |

---

## 4. Feature Integration in the Notch

### 4.1 Drop Shelf in the Notch
- **Resting Badge:** Shows staged item count in the left wing (e.g. `􀈕 3`).
- **Drag Target Zone:** Dragging files or text anywhere near the camera notch expands the notch into a welcoming Drop Shelf drop target.
- **Expanded Tray:** Displays staged items with one-click actions: Clear, AirDrop, AI Process, or drag out to any app.

### 4.2 Clipboard in the Notch
- **Ambient Copied Flash:** Copying text, image, or link flashes a compact confirmation in the right wing (e.g. `􀉉 Copied 120 chars`).
- **Clipboard Board:** Tapping the clipboard wing opens the full clipboard history card right from the notch with search, kind filter, and paste targeting.

### 4.3 AI & App Context Selection
- **AI Live Activity:** When background AI operations or terminal commands run, the notch shows animated pulsing status (`Thinking...`, `Running build`, etc.).
- **Selection Quick Actions:** When text or files are selected in the frontmost app, the notch offers instant one-tap AI transformations.

---

## 6. Launcher Presentation & Dynamic Notch Architecture Separation

Following user requirements, Context-Dock maintains a clean, architectural separation between the **Interactive Launcher** and the **Dynamic Notch Island**:

### 6.1 Launcher Presentation Modes
The launcher is summoned anywhere across macOS via a single unified launch shortcut: **Double-press Command (`⌘⌘`)** (or custom user-recorded hotkey):
1. **Centre of Display (`.centerScreen` - Default):**
   - Floating Spotlight / Raycast-style launcher in the center of the display.
   - **Draggable:** Users can drag the window around the screen by its background glass.
   - **Position Persistence:** Remembers its dragged coordinates (`centredLauncherX`, `centredLauncherY`) so that reopening summons it exactly where the user placed it.
   - Includes a "Reset to Center" button in Appearance Settings.
2. **Bottom Dock (`.bottomDock`):**
   - Dock anchored along the bottom edge in `[ Left Corner | Centre | Right Corner ]`.
   - Supports auto-hide ("Automatically hide and show the bottom dock") sliding below the screen edge at rest.

### 6.2 Independent Dynamic Notch (Dynamic Island)
The camera notch is **not** a launcher dock position; it is an ambient, permanent Dynamic Island accessory running via `DynamicNotchController`:
- Stationed directly at the MacBook hardware camera notch (`ScreenNotchMetrics.screenWithNotch ?? NSScreen.main`).
- Auto-adjusts for hardware notch cutouts (M2/M3/M4 MacBook Air & Pro) vs notchless external monitors.
- **Micro-interactions:** Swell on hover and smooth spring-glide expansion downwards (`.spring(response: 0.38, dampingFraction: 0.82)`).
- **Page 0: Now Playing / Media Player:**
  - Album artwork, track title, and artist.
  - Universal media transport controls: Spotify, Apple Music, MediaRemote, and web browsers.
  - Interactive scrubbing seekbar (tap or drag to seek anywhere in the track).
  - Animated audio waveform equalizer bars when audio is playing.
- **Page 1: File Drop Shelf:**
  - File drag-and-drop target directly onto the camera notch.
  - Staged file grid with native thumbnails and one-click "Clear" button.
- **Page 2: Frontmost App Extensions & Approvals:**
  - **Live AI Approvals:** Glowing amber banner when Claude, Codex, or Antigravity requests approval, with instant 1-click `[ Approve ]` (green) and `[ Deny ]` (red) buttons.
  - **Frontmost App Window Management:** Window tiling controls: Tile Left (`◧`), Tile Right (`◨`), Maximize (`◻`).
  - **App Context & Usage:** App icon, title, and quick prompt search.

### 6.3 Frontmost App Chat UI (Claude Desktop & Apps)
Matches the latest UI specification (`media_1793731123519_71336fc3.png`):
- **App with pins:** Shows the pinned-actions bar beside the composer as before.
- **App with no pins:** Uses the plain compact frontmost-app chat field:
  - Main pill: `[ AppIcon | Cog ]` `Ask <App>...` `+` `📌`
  - Trailing capsule: Standalone detached window button `[ 🗖 ]` (`macwindow` icon) to open the chat in a separate window.
  - **No strip, no running-apps row** to eliminate clutter.

---

## 7. Implementation Roadmap & Verification Status

- **Phase 1: Geometry & Safe Area Metrics:** [COMPLETED]
  - Modernized `ScreenNotchMetrics.swift` with exact 2024 MacBook Air and MacBook Pro hardware dimensions (32-34 pt notch height, ~190-200 pt camera cutout width).
  - Defined open island reference metrics: `openIslandDefaultWidth = 378`, `openIslandDefaultHeight = 172`, `openIslandMaxWidth = 600`, `openIslandMaxHeight = 320`.
  - Defined safe-area insets (`safeAreaSideInset = 32`, `safeAreaTopInset = 36`, `safeAreaBottomInset = 26`) and safeArea calculation.
- **Phase 2: Unified Liquid Glass Engine:** [COMPLETED]
  - Updated `GlassBackground` in `LauncherUIUtilities.swift` to dynamically modulate base fill opacity and tint color directly with `AppSettings.shared.glassDarkness` (0% pure liquid glass to 100% smoked black).
  - Unified across `CornerCombinedCard.swift` (`BoardGlass`), `DropShelfCard.swift`, `ClipboardPreviewCard.swift`, and `AppChatPromptPill.swift` to use reactive system/app appearance and synchronized glass darkness.
- **Phase 3: Dual-Wing Live Status & Hover Swell (Drooppy Parity):** [COMPLETED]
  - Re-engineered `DynamicNotchLiveActivityView.swift`:
    - Auto-adjusts for hardware notch (Apple MacBook Air/Pro 32-37.5 pt height, ~208 pt cutout) vs notchless external monitors.
    - True jet-black finish (`Color.black.opacity(0.96)`) seamlessly matching the camera hardware.
    - Zero stroke line across the top bezel via custom `outlinePath`.
    - Page 0 (Music / Now Playing, matching Drooppy): Artwork thumbnail, track title, artist, progress scrubber, and playback controls (Previous, Play/Pause, Next).
    - Page 1 (Drop Shelf, matching Drooppy): "\(count) items", "Clear" button, staged file cards with macOS file icons/thumbnails and filenames (`SCR...png`).
    - Page 2 (AI Prompt / Search): Prompt composer and quick action chips.
    - Bottom page indicator dots (`• • •`) for instant switching.
    - Double-press Option (`⌥⌥`) launches the central Spotlight-style launcher in the center of the display (like Raycast), with zero shortcut collision.
- **Phase 4: Open Island Layout & Smooth Transitions:** [COMPLETED]
  - Enhanced `CornerDockWindow.swift`:
    - Embedded `DynamicNotchLiveActivityView` in `notchTapArea` when `prompt.phase == .dock`.
    - Integrated safe area top insets (`max(ScreenNotchMetrics.currentNotchHeight, 32)`).
    - Expanded hit-test interactive collar to cover full resting wings (`notchRect.width + wingWidth * 2`).
- **Phase 5: Drop Shelf, Clipboard & Selection Notch Parity:** [COMPLETED]
  - Drop Shelf: Added `.dropShelfTarget(shelf)` directly to the notch island view so dragging files over the notch absorbs items straight into `DropShelfStore.shared`.
  - Clipboard & Selection: Connected right-wing glanceable indicator and unified glass material.
- **Phase 6: Standalone Dynamic Island & Architecture Separation:** [COMPLETED]
  - Separated the Dynamic Island window (`DynamicNotchWindow.swift`) from the launcher dock:
    - **Launcher Presentation Modes:** Configured in Settings Appearance as either "Centre of Display (Raycast / Spotlight)" with persistent drag positioning, or "Bottom Dock" (Left Corner, Centre, Right Corner).
    - **Dynamic Notch:** Runs independently at the top display bezel for Live Activities (Media Now Playing, Drop Shelf staged files, Approvals, AI status).
    - **Single Unified Shortcut:** Double-press Command (`⌘⌘`) or custom recorded shortcut summons Context-Dock at your chosen presentation mode. Double-press Option (`⌥⌥`) remains an optional alternative trigger for center search.
- **Phase 7: Inside-Notch Global Tracking & Media Controls Parity:** [COMPLETED]
  - **Inside-the-Notch Cursor Detection:**
    - Root cause resolved: AppKit `NSTrackingArea` does not receive mouse movements when the cursor enters the top menu bar / camera cutout region due to macOS WindowServer menu bar event capture on non-activating panels.
    - Added global event monitoring via `NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged])` with top collar geometry (`y` from `screen.frame.maxY - collarH` to `screen.frame.maxY + 12`, covering the camera notch, menu bar, and bezel edge).
    - Moving the cursor directly into the camera cutout, menu bar, or bezel instantly triggers hover swell and glides the island open.
  - **Instant Interactive Media Playback & Controls:**
    - Resolved first-mouse click-through by enabling `acceptsFirstMouse(for:) -> Bool { true }` on `DynamicNotchHostView` and setting `canBecomeKey = DynamicNotchState.shared.isExpanded` on `DynamicNotchPanel`.
    - Removed container-level `.onTapGesture` from the outer view so clicks on buttons (Play/Pause, Previous, Next, Scrubber, Clear) are received directly without collapsing the island.
    - Updated `MediaPlayerObserver.togglePlayPause()` to explicitly send `play` or `pause` commands to Spotify and Apple Music via AppleScript and MediaRemoteBridge for 100% deterministic toggling.
  - Built with `./scripts/build-debug.sh` (build OK, all checks passed).
  - Launched and verified via `./scripts/dev-run.sh`.
