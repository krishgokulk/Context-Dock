# Unified Spotlight-Pet Surface Specification

> **Status:** Current (owner-approved 2026-11-09).  
> **Topic:** Unified single-entry dock surface combining Global Context (Spotlight/Raycast-style search) and Frontmost App Pet (conversational AI) into one context-biased, zero-modal launcher.  
> **Source of Truth for:** `Context-Dock/Search/AppChatRowRanker.swift`, `Context-Dock/Services/GlobalSearchService.swift`, `Context-Dock/Services/UsageTracker.swift`, `Context-Dock/UI/AppChatPromptModel.swift`, `Context-Dock/UI/AppChatPromptPill.swift`.

---

## 1. Executive Summary & Design Vision

Historically, DoraX separated launcher search from app conversations by requiring the user to tap `⌘` or empty `Backspace` to toggle between **App Pet** and **Global Context**. In practice, this created cognitive friction: users had to remember what mode they were in before typing.

The **Unified Spotlight-Pet Surface** dissolves this modal division:
1. **Single Universal Input:** One hotkey (`⌘⌘` or user shortcut) opens one Liquid Glass dock bar over any active application.
2. **Context-Biased Instant Search ($<1\text{ms}$):** Simultaneous query evaluation across frontmost menus, global applications, system commands, files, and clipboard history.
3. **Ghost Text Autocomplete:** High-confidence matches display inline completion accepted via `→` or `Tab`, executed in one stroke with `Return`.
4. **Adaptive Frecency Learning:** Automatically boosts commands and apps used frequently and recently via `UsageTracker` and `AppUsageLearner`.
5. **Incidental File Collision Shield:** Natural-language questions (e.g. *"how to fix clang error"*) penalize raw file matches by $-100$, guaranteeing that `[ 🤖 Ask Pet ]` and `[ 🌐 Search Web ]` rank at the top rather than accidental log files.
6. **Zero-Lag Conversation Escalation:** When a query has no exact command match or is conversational, pressing `Return` smoothly transitions into the active App Pet with ambient window context.

---

## 2. Dynamic Results Board Layout

The surface sits along the bottom or center edge in Liquid Glass material:

```
┌────────────────────────────────────────────────────────────────────────┐
│  DYNAMIC RESULTS BOARD (Expands upward above the input field)          │
│                                                                        │
│  ★ TOP MATCH (Hero Row - Automatically highlighted)                    │
│    [  ] File ▸ Export as PDF…            Safari Menu        ↵ Run     │
│                                                                        │
│  ── CONTEXTUAL ACTIONS (Frontmost App: Safari) ──────────────────────  │
│    [ 📄 ] Export…                          Safari Menu        ⌘2        │
│    [ 🔗 ] Copy Clean URL                  Safari Action      ⌘3        │
│                                                                        │
│  ── GLOBAL APPS & COMMANDS ──────────────────────────────────────────  │
│    [ 🚀 ] ExpressVPN.app                  Applications       ⌘4        │
│                                                                        │
│  ── CLIPBOARD HISTORY ───────────────────────────────────────────────  │
│    [ 📋 ] "https://developer.apple.com…"  Copied 2m ago      ⌘5        │
│                                                                        │
│  ── INTELLIGENT AI & WEB ───────────────────────────────────────────── │
│    [ 🤖 ] Ask Safari Pet: "exp"           Active Tab Context ⇥ Chat    │
│    [ 🌐 ] Search Google for "exp"         Safari             ⌘↵        │
├────────────────────────────────────────────────────────────────────────┤
│  🔍 exp[ort as PDF…]                     [  Safari ]  [ ⌥K Actions ]  │
│     ▲ typed   ▲ ghost completion (gray)    ▲ active app  ▲ hotkey hint │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Deterministic Intent Classification (<1ms)

Before ranking candidate rows, `UnifiedIntentClassifier` categorizes the query string synchronously:

```swift
public enum QueryIntentArchetype: Sendable {
    case navigational      // Direct app or menu keyword (e.g. "safari", "export", "save")
    case explicitFile      // Exact file path or extension (e.g. "resume.pdf", "~/Downloads")
    case conversational    // Question or instruction (e.g. "how to fix...", "draft reply...")
    case webResearch       // Search operators, "vs", "latest", "weather"
}
```

### Detection Invariants
1. **Conversational Intent Trigger:**
   * Contains question words: `how`, `why`, `what`, `where`, `who`, `when`, `which`, `can I`, `should I`, `is it`.
   * Contains directive verbs: `explain`, `summarize`, `draft`, `fix`, `debug`, `translate`, `compare`, `solve`, `write`.
   * Structure: Ends in `?` or contains $>3$ words without file extensions.
   * **Effect:** Promotes `[ 🤖 Ask Pet ]` to row #1, `[ 🌐 Search Web ]` to row #2, and applies a **$-100$ Incidental File Match Penalty** to local files.
2. **Explicit File Intent Trigger:**
   * Contains standard file extension: `.pdf`, `.swift`, `.png`, `.jpg`, `.dmg`, `.zip`, `.json`, `.md`.
   * Contains path markers: `~/`, `/Users/`, `Desktop/`, `Downloads/`.
   * **Effect:** File matches are boosted by $+50$; AI chat stands down to secondary row.
3. **Navigational / Menu Intent Trigger:**
   * Prefix or acronym match against installed apps or frontmost app menu hierarchy.
   * **Effect:** Matching command is highlighted as Hero row with inline ghost text.

---

## 4. The Unified Ranking Formula

Every candidate row is ranked by `AppChatRowRanker` using the unified score:

$$\mathbf{TotalScore} = \text{MatchScore} + \text{FrecencyBoost} + \text{FrontmostBoost} + \text{SourceWeight} - \text{IncidentalPenalty}$$

### 1. MatchScore (`DockTextMatch`):
* Exact match: $+20,000$ points.
* Prefix match: $+10,000$ points.
* Acronym match: $+5,000$ points (e.g. `vsc` $\rightarrow$ `Visual Studio Code`).
* Substring / fuzzy match: $+1,000$ points.

### 2. FrecencyBoost (`UsageTracker.swift`):
Combines recency decay with logarithmic frequency:
$$\text{RecencyScore} = \begin{cases} 100 & (< 1 \text{ day since last use}) \\ 70 & (< 7 \text{ days}) \\ 40 & (< 30 \text{ days}) \\ 5 & (\ge 90 \text{ days}) \end{cases}$$
$$\text{FrecencyBoost} = \text{RecencyScore} + \log_{10}(\text{AccessCount} + 1) \times 10$$

### 3. Frontmost App Context Boost:
* $+500$ points applied to any command, menu item, or document belonging to the frontmost application.
* Ensures that typing `save` in Word surfaces `Word ▸ File ▸ Save`, not an obscure background service.

### 4. SourceKind Weight (`GlobalSearchService.SourceKind`):
* `runningApp`: $3,000$ | `pinnedApp`: $2,000$ | `builtInCommand`: $1,500$ | `recentDocument`: $1,200$ | `frontmostMenu`: $850$ | `installedApp`: $400$.

### 5. Incidental File Penalty:
* When `QueryIntentArchetype == .conversational`, all raw disk file results receive $-100$ points.

---

## 5. Ghost Completion & Keyboard Invariants

### Ghost Completion Protocol
* As the user types, the top candidate's title is checked for a prefix match against the query.
* The un-typed suffix is displayed directly inside the text field in semi-transparent Liquid Glass text (`[minal]` after `ter`).
* **`→` (Right Arrow) or `Tab`:** Accepts the ghost completion, populating the input string without executing.
* **`Return`:** Executes the ghost-completed item immediately in a single keystroke.

### Comprehensive Keyboard Map

| Key | Context | Behavior |
| :--- | :--- | :--- |
| **`↵` (Return)** | Highlighted row is Command/File | Executes action immediately ($0\text{ms}$ AI delay). |
| **`↵` (Return)** | Highlighted row is `Ask Pet` | Smoothly crossfades into active Pet conversation transcript. |
| **`⇥` (Tab)** | Ghost completion available | Accepts ghost text into the input field. |
| **`⇥` (Tab)** | No ghost completion | Pins composer into **App Pet Chat Mode** (shows prompt expansion). |
| **`→` (Right Arrow)** | Ghost completion available | Accepts ghost text. |
| **`→` (Right Arrow)** | Highlighted row has sub-items | Steps into sub-menu / folder hierarchy. |
| **`↓` / `↑`** | Results board open | Moves active selection highlight up/down. |
| **`Space`** | File or Clipboard clip highlighted | Opens macOS **Quick Look** preview overlay. |
| **`⌘1` – `⌘9`** | Results board open | Executes row by visual index immediately. |
| **`⌘↵`** | Any query | Searches default web browser for the exact query string. |
| **`⌘C`** | Row highlighted | Copies row title, file path, or clip content to clipboard. |
| **`Esc`** | Query non-empty | Clears input field back to resting state. |
| **`Esc`** | Input empty | Closes the Dock shell cleanly. |

---

## 6. Clipboard Clips Integration

* **Ambient State (Empty Input):** If clipboard was updated within the last 5 minutes, an ambient pill appears above the resting strip: `[ 📋 Copied: "..." ]`. Tapping `⌥V` acts on it immediately.
* **Inline History Match:** If typed words match recent clipboard content (managed by `ClipboardScopeService`), a dedicated `case clipboard(ClipboardEntry)` row surfaces in the board.
* **Filter Prefix (`cb` / `clip`):** Typing `cb` or `clip` narrows the board directly into the full-height `ClipboardBoardCard` history browser.

---

## 7. Global Commands & Quick Calculations

When the query matches mathematical or system expressions, `SystemCommandsRegistry` evaluates results inline:
* **Math:** `1280 * 720` $\rightarrow$ Displays `921,600` with `↵ Copy` action.
* **Conversions:** `50 eur to usd`, `16 gb in mb`, `72 f to c`.
* **System Actions:** `dark mode`, `lock screen`, `empty trash`, `sleep`, `bluetooth on/off`.

---

## 8. Migration & File Impact

1. **`Context-Dock/Search/AppChatRowRanker.swift`:**
   - Integrate `UnifiedIntentClassifier`.
   - Add `ConversationalPenalty` to `AppChatRow.file` scoring.
   - Inject `AppChatRow.action` for `AskAppPetIntentRow` and `SearchWebRow`.
2. **`Context-Dock/UI/AppChatPromptModel.swift`:**
   - Remove modal `SurfaceFocus.global` vs `.frontmost` boundary requirement.
   - Route `Return` execution based on the highlighted unified row.
3. **`Context-Dock/Services/GlobalSearchService.swift`:**
   - Add `+500` frontmost app boost to in-memory score builder.
4. **`Context-DockTests/`:**
   - Add `UnifiedIntentClassifierTests.swift` (20 test cases).
   - Add `UnifiedRowRankingTests.swift` verifying conversational questions rank `Ask AI` above incidental log files.
