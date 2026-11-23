# Unified Global Launcher & Bounded File Search Specification

> **Status:** Draft / Proposed (Owner review 2026-11-23).  
> **Topic:** Total unification of DoraX into a single zero-modal Liquid Glass launcher, dual hotkey alignment (`⌘⌘` & `⌥⌥` → Global Context), strict user-selected folder boundaries for file search, frontmost app action grouping, self-learning top hints, and dual AI escalation (General AI Chat vs Frontmost App Pet).  
> **Source of Truth for:** `Context-Dock/App/ILauncherApp.swift`, `Context-Dock/UI/GlobalResultSection.swift`, `Context-Dock/UI/GlobalQuery.swift`, `Context-Dock/UI/GlobalFallbacks.swift`, `Context-Dock/UI/AppChatMenuBrowsing.swift`, `Context-Dock/AI/FileSearchService.swift`, `Context-Dock/App/AppSettings.swift`.

---

## 1. Executive Summary & Design Vision

Historically, DoraX maintained separate concepts of "Context Dock" (app-focused menu bar) and "Global Context" (cross-app launcher), with `⌘⌘` and `⌥⌥` triggering different modes or presentations.

### The Unified Surface Axiom:
There is **only ONE launcher surface**:
1. **Universal Hotkeys:** Both `⌘⌘` (double-Command) and `⌥⌥` (double-Option) summon the **same Unified Global Surface** at the user's preferred placement (Center or Bottom).
2. **Context-Biased by Default:** The surface automatically senses the **Frontmost App** without locking the user into a modal cage. Frontmost app menus and actions are promoted right beneath the Hero Top Hit.
3. **Strict Bounded File Search:** Files and folders are searched **strictly within user-selected directories configured in App Settings** (`settings.useCustomSearchDirectories` / `settings.searchDirectories`), protecting privacy and performance.
4. **Self-Learning Top Hints:** Powered by `UsageTracker` and `GlobalPickMemory`, the launcher learns which commands, apps, and files you open for any given query (or time of day) and elevates them to the **Top Hit**.
5. **Dual AI Escalation:**
   - **`[ ✨ Ask Dora ]` (`↵`):** Universal Mac-wide AI conversation with core system primitives.
   - **`[ 🤖 Ask <App> Pet ]` (`⌥↵`):** In-depth App Pet with active window perception, app-specific `.doraxpack` skills, and sdef automation.
   - **`[ 🌐 Search Web ]` (`⌘↵`):** Instant Google search in default browser.

---

## 2. Dynamic Results Board Hierarchy

When the user types a query or presses `↓` (Down Arrow) on the resting pill, results expand upward in a Siri/Raycast-grade layout:

```
┌────────────────────────────────────────────────────────────────────────┐
│  UNIFIED DOCK RESULTS BOARD (Expands on ↓)                             │
│                                                                        │
│  ★ TOP HIT (Learned Frecency Favorite / Exact Match)                   │
│    [ 🚀 ] Safari.app                     Applications       ↵ Open     │
│                                                                        │
│  ── CONTEXTUAL ACTIONS (Frontmost: Safari) ──────────────────────────  │
│    [ 📄 ] Export as PDF…                 Safari Menu        ⌘2        │
│    [ 🔗 ] Copy Clean URL                 Safari Action      ⌘3        │
│                                                                        │
│  ── APPLICATIONS ────────────────────────────────────────────────────  │
│    [ 🚀 ] Slack.app                      Applications       ⌘4        │
│    [ 🚀 ] Terminal.app                   Applications       ⌘5        │
│                                                                        │
│  ── COMMANDS & SHORTCUTS ────────────────────────────────────────────  │
│    [ ⚙️ ] Lock Screen                    System Action      ⌘6        │
│    [ 🌙 ] Dark Mode                      System Action      ⌘7        │
│                                                                        │
│  ── OPEN TABS ───────────────────────────────────────────────────────  │
│    [ 🌐 ] GitHub Pull Requests           Safari Tab         ⌘8        │
│                                                                        │
│  ── FILES & FOLDERS (Strictly user-configured folders) ──────────────  │
│    [ 📁 ] ~/Documents/Roadmap.pdf        Documents Folder   ⌘9        │
│                                                                        │
│  ── INTELLIGENT AI & WEB FALLBACKS ─────────────────────────────────── │
│    [ ✨ ] Ask Dora: "<query>"            General AI Chat    ↵ / Tab    │
│    [ 🤖 ] Ask Safari Pet: "<query>"      Frontmost Context  ⌥↵         │
│    [ 🌐 ] Search Google for "<query>"    Default Browser    ⌘↵         │
├────────────────────────────────────────────────────────────────────────┤
│  🔍 [ ✳️ Safari ⌄ ]  Search or ask anything…     [ + ] [ 📌 ] [ ⌃ ]   │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Detailed Component Architecture

### 3.1 Hotkey Unification (`ILauncherApp.swift`)
- Both `doubleOption` (`⌥⌥`) and `doubleCommand` (`⌘⌘`) route to the same universal entry point: `activateUnifiedGlobalLauncher()`.
- If the launcher is already open and focused, pressing the hotkey dismisses it.
- Opening the launcher sets `model.summon(app: AppChatPromptModel.globalScopeName, bundleID: "")`, ensuring Global Context is active while immediately capturing `NSWorkspace.shared.frontmostApplication` as the contextual anchor.

### 3.2 Bounded File Search & Finder Integration
- **Strict Settings Boundary:**
  - `FileSearchService` and `appendFinderDiskMatches` check `AppSettings.shared.useCustomSearchDirectories`.
  - When `useCustomSearchDirectories == true`, file search is strictly constrained to `AppSettings.shared.searchDirectories.map(\.path)`.
  - When `useCustomSearchDirectories == false`, file search defaults to safe standard user roots (`~/Desktop`, `~/Documents`, `~/Downloads`) and ignores hidden directories, system caches, and node_modules.
- **Finder Frontmost Window Integration:**
  - When Finder is the frontmost application:
    - The active Finder folder's contents (`FinderFrontFolder.current` or Desktop) are surfaced as the **Contextual Actions** section.
    - Right Arrow (`→`) or Tab navigates into subfolders in-place.
    - Space opens native macOS **Quick Look** (`QLPreviewController`).

### 3.3 Self-Learning Top Hints & Frecency Ranking
- **`GlobalPickMemory`:**
  - Records `(query, rowKey)` pairs whenever an item is executed.
  - Queries with $\ge 3$ characters inherit learned picks (e.g. `saf` immediately proposes Safari if previously selected).
- **`UsageTracker`:**
  - Calculates frecency scores based on access frequency and recency decay (14-day half-life).
  - Items with high frecency receive up to `+200` score points, ensuring daily routines naturally rise to the top of their respective sections.

### 3.4 Dual AI Fallback Architecture (`GlobalFallbacks.swift`)
When a query is conversational or the user reaches the fallbacks:
1. **`Ask Dora` (General AI Chat):**
   - Identifier: `fallback-ask-dora`
   - Icon: `sparkles`
   - Action: Transitions the Liquid Glass shell into the seamless General Chat transcript.
   - Shortcut: `↵` (Return) or `Tab`.
2. **`Ask <App> Pet` (Frontmost App Pet):**
   - Identifier: `fallback-ask-pet`
   - Icon: Frontmost app icon
   - Action: Transitions the Liquid Glass shell into that app's App Pet transcript, injecting live window context and `.doraxpack` capabilities.
   - Shortcut: `⌥↵` (Option-Return).
3. **`Search Google`:**
   - Identifier: `fallback-web`
   - Icon: `globe`
   - Action: Opens default browser search.
   - Shortcut: `⌘↵` (Cmd-Return).

---

## 4. Implementation Roadmap

### Phase 1: Dual Hotkey Alignment (`ILauncherApp.swift`)
- Map `⌘⌘` and `⌥⌥` to open the same unified Global Context launcher.
- Ensure smooth toggle behavior (hotkey opens, hotkey closes).

### Phase 2: Dual AI Fallbacks (`GlobalFallbacks.swift` & `AppChatMenuBrowsing.swift`)
- Implement `Ask Dora` and `Ask <App> Pet` fallback pills.
- Add keyboard shortcuts (`↵`, `⌥↵`, `⌘↵`) for instant execution.

### Phase 3: Bounded File Search Enforcement
- Wire `AppSettings.shared.useCustomSearchDirectories` and `AppSettings.shared.searchDirectories` into all Spotlight and file search passes.
- Restrict disk searches to user-approved folders.

### Phase 4: Contextual Frontmost Actions Grouping (`GlobalResultSection.swift`)
- Group frontmost app actions immediately below Top Hit when an app is active.
- Verify unit tests across `GlobalQueryTests`, `GlobalResultSectionTests`, and `CornerGlobalContextParityTests`.
