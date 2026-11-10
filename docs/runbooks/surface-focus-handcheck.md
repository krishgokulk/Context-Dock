# Runbook: Unified Surface Focus & Global Context Hand-Check

This runbook guides both human developers and autonomous AI agents in verifying the **Unified Corner Surface** (`CornerDockWindow` / `AppChat*`) and its **Surface Focus transitions** (`SurfaceFocus.swift`).

---

## 1. Core Architecture (The Unified Surface Rule)

Per `AGENTS.md` and `#327` / `#318`:
- **Frontmost App UI** (`.frontmost`) and **Global Context UI** (`.global`) are **NOT two separate windows**.
- They are **one single floating Corner capsule** sharing the exact same shell, running-apps row, text input field, and underlying `DockEngine`.
- **The only difference is focus (`SurfaceFocus`)**:
  - `.frontmost`: Scoped to the currently active application (e.g., Antigravity, Safari, Xcode, Finder).
  - `.global`: Scoped machine-wide across all applications, documents, system tools, and menus.

---

## 2. Visual Identification Guide

### Surface State Comparison

| Feature | 1. Frontmost App UI (`.frontmost`) | 2. Global Context UI (`.global`) |
| :--- | :--- | :--- |
| **Leading Element** | App Icon badge + Settings gear ⚙️ | Search magnifying glass 🔍 |
| **Placeholder Text** | `Ask <App Name>...` (e.g., `Ask Antigravity...`) | `Search apps, tools and menus......` |
| **Trailing Elements**| Attachment `+` pill, Pin 📌 button | Clean field or trailing filter pills |
| **Scope** | Current frontmost application | Mac-wide (all running apps & commands) |
| **Reference Image** | `docs/screenshots/surface-focus/frontmost-app-focus.png` | `docs/screenshots/surface-focus/global-context-zoom.png` |

---

## 3. Keyboard & Gesture Transition Rules

Defined purely in `SurfaceFocusRules.swift`:

| From | Action / Key Event | To (Destination) | Behavior / Rationale |
| :--- | :--- | :--- | :--- |
| **Outside** | **`⌘⌘` (Double-tap Command)** | **Frontmost App** | Summons the Context Dock of the active app (`activateContextDockFromDoubleCommand`). |
| **Outside** | **`⌥⌥` (Double-tap Option)** | **Global Context** | Summons the Corner centered in Global Context search mode (`toggleCentredCorner`). |
| **Frontmost App** | **Single `⌘` (Command) tap** | **Global Context** | Instant zoom out to machine-wide scope on an empty field. |
| **Global Context** | **Single `⌘` (Command) tap** | **Frontmost App** | Instant zoom back into the frontmost app on an empty field. |
| **Frontmost App** | **`↑` Arrow** (or swipe down) | **Global Context** | Zoom out gesture. |
| **Global Context** | **`↓` Arrow** (or swipe up) | **Frontmost App** | Zoom in gesture. |
| **App Pet / Subscope** | **`⌫` (Backspace)** | **Global Context** | Unwinds from child scope back to home Global Context on empty field. |

---

## 4. Agent Autonomous Verification (How Agents Hand-Check Themselves)

Coding agents with shell access can verify this behavior live on macOS without requiring human intervention:

### Step 1: Ensure Context-Dock is Running
```bash
./scripts/dev-run.sh
```

### Step 2: Summon Frontmost App via Notification / Hotkey
Simulate the `⌘⌘` summon or broadcast the launch notification:
```bash
osascript -e 'tell application "Context-Dock" to activate'
osascript -e 'tell application "System Events" to tell process "Context-Dock" to set frontmost to true'
```
Or trigger via the distributed notification center:
```bash
python3 -c "import Foundation; Foundation.NSDistributedNotificationCenter.defaultCenter().postNotificationName_object_('com.ilauncher.showWindow', None)"
```

### Step 3: Inspect AX Hierarchy for Frontmost UI
Inspect the active window elements to confirm:
1. Window title or role contains `AXWindow` or `AXFloatingWindow`.
2. Input placeholder text contains `Ask ` (e.g. `Ask Antigravity...`).
3. App icon element exists.

```bash
osascript << 'EOF'
tell application "System Events"
    tell process "Context-Dock"
        set w to first window
        return (value of attribute "AXRole" of w)
    end tell
end tell
EOF
```

### Step 4: Trigger Focus Switch to Global Context
Simulate a single `⌘` (Command) tap or keydown event:
```bash
osascript -e 'tell application "System Events" to key code 55' # Command key event
```
Or send `Backspace` or `↑` on an empty field:
```bash
osascript -e 'tell application "System Events" to key code 126' # Up Arrow
```

### Step 5: Verify Placeholder Changed to Global Context
Verify that the search field's placeholder has transitioned to `Search apps, tools and menus......`.

### Step 6: Dismiss Surface Cleanly
```bash
osascript -e 'tell application "System Events" to key code 53' # Escape
```

---

## 5. Human Hand-Check Checklist

When the developer or QA tests by hand:

1. [ ] **Frontmost App Summon**:
   - Focus any app (e.g., Safari or TextEdit).
   - Double-tap `⌘` (`⌘⌘`).
   - Confirm the capsule appears with the app's icon and placeholder `Ask Safari...` or `Ask TextEdit...`.
2. [ ] **Toggle to Global Context**:
   - With the search field empty, tap `⌘` once.
   - Confirm the app badge changes into the magnifying glass `🔍` and placeholder reads `Search apps, tools and menus......`.
3. [ ] **Toggle Back to Frontmost App**:
   - Tap `⌘` once again.
   - Confirm it returns immediately to `Ask <App>...`.
4. [ ] **Arrow Navigation**:
   - Press `↑` on the empty field $\rightarrow$ confirms switch to Global Context.
   - Press `↓` on the empty field $\rightarrow$ confirms switch to Frontmost App.
5. [ ] **Escape Dismissal**:
   - Press `Esc` $\rightarrow$ capsule dismisses cleanly with zero residual windows or window server lag.
