# Context Dock — Pre-Release Audit
**Scope:** Global Context mode, launch path, stability, performance  
**Standard:** Spotlight / Raycast parity  
**Date:** 2026-06-14  
**Last verified against source:** 2026-08-10

---

## Status — re-verified 2026-08-10

Re-read against the current source before the launch pass. Items below marked
**RESOLVED** are fixed in the tree; the finding text is kept as written so the
reasoning stays readable, but do not re-open them without re-checking the code.

| # | Finding | Status |
|---|---|---|
| 1 | Hotkey dies after sleep/wake | **RESOLVED** — `8d3b879`. Both `screensDidWake` and `didWake` observed, and the NSEvent monitors behind double-tap Option are reinstalled too, which the original fix would have missed. |
| 3 | 509 `print()` calls in production | **RESOLVED** — `Services/DebugLogger.swift` shadows `print` for the whole module, so every call compiles away in Release. No call-site changes needed. Remaining interpolations are all `.count` on arrays; nothing expensive survives to be evaluated. |
| 9 | 160ms window fade | **RESOLVED** — now `0.10` in `showLauncher()`. |
| 10 | No sleep/wake cleanup for AX observers | **RESOLVED** — `AXObserverManager` clears the pool on `willSleepNotification` and re-attaches on `didWakeNotification`. |
| — | `preconditionFailure` in `AIProviderRouter` | **RESOLVED** — no `preconditionFailure` remains anywhere in the target. |
| — | `best!` force-unwrap | **NOT A DEFECT** — the one remaining use is `best == nil \|\| score > best!.score`, which short-circuits. |

Findings 2, 4–8, 11–14 and the rest of Code Health are **not re-verified** and
should be treated as still open.

---

## Summary

The core architecture is solid — debounced search, background AX reads, LRU observer pool, typed event bus, clean layer separation. The issues below are not architectural; they're polish, reliability, and a handful of hot-path problems that will make the app feel slower or less trustworthy than Spotlight/Raycast at first use.

---

## 🔴 Critical — Fix Before Release

### 1. Hotkey dies after machine sleep/wake
**File:** `App/ILauncherApp.swift`  
Carbon `EventHotKey` registrations are invalidated by the system on sleep. There is **no `NSWorkspace.didWakeFromSleepNotification` observer** anywhere in the project. After the Mac sleeps, the hotkey silently stops working until the app is restarted. Raycast/Spotlight survive sleep because they re-register.

**Fix:** Add one observer in `applicationDidFinishLaunching`:
```swift
NSWorkspace.shared.notificationCenter.addObserver(
    self, selector: #selector(handleSystemWake),
    name: NSWorkspace.didWakeFromSleepNotification, object: nil)

@objc func handleSystemWake() {
    unregisterGlobalHotkey()
    registerGlobalHotkey()
}
```

---

### 2. AppleScript on the launch hot path
**File:** `App/ILauncherApp.swift` line ~1764  
`detectAndStoreFrontmostApp()` runs `NSAppleScript.executeAndReturnError()` **synchronously** on the background thread it's called from. AppleScript has a global interpreter lock and routinely takes 150–800ms. This is called every time the launcher opens via `showLauncher()`. Even on a background thread, this causes visible lag because `frontmostAppDidChange` is then dispatched to main — arriving after the window is already shown with stale app info.

**Fix:** Replace with `NSWorkspace.shared.frontmostApplication` (already captured synchronously at the top of `showLauncher()` in `recordFrontmostApp`). The AppleScript call is a redundant fallback that adds latency without benefit — remove `detectAndStoreFrontmostApp()` or gate it behind a flag for the edge case where `NSWorkspace` returns the wrong app.

---

### 3. 509 `print()` calls shipping to production
**Files:** across entire project  
Every hotkey press, every frontmost-app switch, every search fires between 5–30 `print()` calls including `showLauncher()` alone (31 calls). `print()` is synchronous stdio and measurably slower than zero-cost logging. On slower Macs this adds up inside the 16ms frame budget. Spotlight has zero console output in production builds.

**Fix:** Wrap in a `#if DEBUG` build flag or replace with `os_log`/`Logger` (subsystem scoped, zero cost in release):
```swift
#if DEBUG
print("...")
#endif
// or:
import OSLog
private let logger = Logger(subsystem: "com.krishgokul.ContextDock", category: "Launch")
logger.debug("Window opened")  // zero cost in release
```

---

## 🟠 High Priority — Strongly Recommended

### 4. No hotkey re-registration after hotkey settings change on macOS 15+
**File:** `App/ILauncherApp.swift` `handleHotkeyChanged`  
The `hotkeyChanged` notification calls `unregisterGlobalHotkey()` then `registerGlobalHotkey()` — correct in principle. But the Carbon `EventHotKeyRef` is stored in three separate vars (`hotKeyRef`, `contextDockHotKeyRef`, `clipboardScopeHotKeyRef`) and `registerGlobalHotkey` may not re-register all three depending on settings state. Test all three hotkeys after changing any one of them.

---

### 5. Window resize fires on every search result update
**File:** `Search/LauncherView+KeyboardNavigation.swift` `updateWindowSize()`  
`updateWindowSize()` is called from **17 different sites** in `ContextLifecycle` alone, and `scheduleDockPillRebuild` (called from 14+ sites) also triggers it. The 50ms debounce coalesces most rapid calls, but `window.animator().setFrame(newFrame, display: true)` with `display: true` forces a compositor flush on every resize — during active typing this causes the window to flicker/resize on each keystroke. Raycast's window is fixed-height during typing.

**Fix:** Use `display: false` during typing. Only use `display: true` for deliberate mode transitions (L1 → L2, opening AI panel). Already partially done in the non-animated path — apply to the animated path too.

---

### 6. Global Context pill rebuild has no debounce floor for typing
**File:** `Search/LauncherView+ContextLifecycle.swift`  
`scheduleDockPillRebuild(query:delayNanoseconds: 0)` is called with **zero delay** from `onChange(of: axContext.selectedText)` and `onChange(of: axContext.selectedFilePaths)`. AX selection changes can fire 10–20 times per second during drag-selection. Each zero-delay call kicks off a pill rebuild on the main actor while the user is in the middle of a gesture. Add a minimum 80–120ms debounce on AX-triggered rebuilds.

---

### 7. `acceptsMouseMovedEvents = true` on the launcher window
**File:** `App/ILauncherApp.swift` `setupLauncherWindow()`  
This setting causes the window server to deliver **every mouse-moved event** to the app process even when the user isn't interacting with the launcher. On a machine with a fast mouse this is hundreds of events/second. It is needed for hover states in the dock, but should be set dynamically — enable when the window is key/visible, disable when hidden. Raycast does this.

---

### 8. `@MainActor` Task sleep in `scheduleBackgroundScanRunningAppMenusAfterOpen`
**File:** `Search/LauncherView+ContextLifecycle.swift` lines ~894, ~926  
Two `Task { @MainActor in ... try? await Task.sleep(...) }` blocks sleep **on the main actor** for 900ms and 1000ms after launcher open. While `await Task.sleep` yields the main thread (it does not block), the continuation is scheduled back on the main actor — competing with SwiftUI layout and user keystrokes during the critical first second of use. Move these to `Task.detached(priority: .background)` and only dispatch results back to main when ready.

---

## 🟡 Polish — Matches Raycast/Spotlight Level of Feel

### 9. Window fade-in uses 160ms — noticeably slow
**File:** `App/ILauncherApp.swift` `showLauncher()`  
```swift
ctx.duration = 0.16
```
Spotlight appears in ~80ms, Raycast in ~90ms. At 160ms Context Dock feels sluggish to invoke. Reduce to `0.10` and use a snappier curve (`easeOut` or `controlPoints: 0.0, 0.0, 0.2, 1.0`).

---

### 10. No sleep/wake cleanup for AX observers
**File:** `Accessibility/AXObserverManager.swift`  
The LRU pool of `AXSelectionObserver`s is never flushed on sleep. AX observer run-loop registrations become stale after sleep and can cause `kAXErrorInvalidUIElement` errors or silent failures when the user wakes and immediately opens the launcher. Clear the pool on `NSWorkspace.willSleepNotification` and re-attach on wake.

---

### 11. Stale `searchState` not fully cleared on re-open in dock context mode
**File:** `Search/LauncherView+ContextLifecycle.swift` `handleLauncherWindowOpened()`  
When `openingForDockContext == true`, the reset block is skipped — `aiMode.isActive`, `showMediaLayer`, `showFolderPreview`, and `searchState.isInSmartMode` are not cleared. If the user was in AI mode or media layer when they last dismissed, re-opening puts them back in that state unexpectedly. Raycast always opens clean.

**Fix:** Reset transient UI state unconditionally on open, keep only the persistent context (frontmost app, AX selection).

---

### 12. `detectAndStoreFrontmostApp` is unreachable dead code
**File:** `App/ILauncherApp.swift`  
`detectAndStoreUserContextAsync()` (line 1728) is defined but never called — `scheduleUserContextDetection()` is used instead. `detectAndStoreFrontmostApp()` (line 1753) is only called from one site inside `showLauncher()` when `settings.enableFrontmostDetection` is true. The AppleScript fallback duplicates what `NSWorkspace.frontmostApplication` already captured synchronously at the top of `showLauncher()`. Clean these up to reduce confusion and latency.

---

### 13. Window level flips between `floatingWindow` and `statusWindow` on dock-at-bottom
**File:** `App/ILauncherApp.swift` lines 771 and 1621  
The window level changes on every `showLauncher()` call depending on settings. Level changes on a visible window can cause a brief compositor redraw artifact (flash/reorder). Set the correct level once at window creation based on settings, and update it only when the setting actually changes — not on every show.

---

### 14. Missing accessibility label on the search field
**File:** `Search/LauncherView+SearchBar.swift`  
The search `TextField` has no `.accessibilityLabel()`. VoiceOver users hear "text field" with no context. Add `.accessibilityLabel("Search — Context Dock")`.

---

## 🔵 Code Health

| Issue | File | Impact |
|---|---|---|
| `best!.score` / `best!.1` force-unwrap after `nil` guard | `LauncherView+GlobalContextActions.swift:2143`, `LauncherView+GlobalAppDock.swift:1356` | Crash if `best` somehow becomes nil between check and use — use `if let` |
| `preconditionFailure` in `AIProviderRouter` | `AI/AIProviderRouter.swift:670` | Crashes in production if `.onDevice` path is hit — replace with `assertionFailure` + graceful return |
| `LegacySettingsContent.swift` 700ms × 4 chained sleeps | `UI/LegacySettingsContent.swift:7077–7097` | 2.8s worst-case sleep chain in settings — use proper async state machine |
| `LauncherView` has 420+ `@State` vars | `Search/LauncherView.swift` | SwiftUI equality check on every state change iterates all 420 vars — split into focused child view-models |
| `DispatchQueue.main` used 120× in Search layer | `Search/` | Mix of `DispatchQueue.main` and `@MainActor Task` patterns — standardise on `@MainActor` for Swift 6 readiness |

---

## Quick Wins You Can Ship Today

1. **Reduce fade-in from 160ms → 100ms** — single line, immediate feel improvement
2. **Add `NSWorkspace.didWakeFromSleepNotification` + re-register hotkey** — 10 lines, prevents #1 user complaint after first sleep
3. **Wrap all `print()` in `#if DEBUG`** — one search-replace, measurable release perf gain
4. **`display: false` in animated `setFrame`** — single char change, eliminates compositor flush on every keystroke
5. **Clear stale state on re-open unconditionally** — ~8 lines, fixes unexpected mode carry-over

