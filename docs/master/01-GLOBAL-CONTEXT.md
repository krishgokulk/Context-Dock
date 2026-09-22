# 01 — Global Context

> **Status: DRAFT / under review.** Not merged into `docs/architecture/` yet.
> Tags: `[code]` verified in source · `[owner]` owner's stated knowledge · `[?]` needs confirmation.

---

## 1. One job

**Global Context is the Universal Search & Launch layer.** `[code — docs/architecture/PRODUCT_LAYERS.md]`

It finds things across the whole system and launches or executes them fast. It is **not** a
chat surface and **not** the frontmost-app command sheet. Its rule, from the product-layers
truth file: *"Never merge product layers."*

> **Boundary correction (owner's original list):** the owner grouped "running apps icon and
> their **chat**" under Global Context. The **icons and launching** belong here. The **chat**
> with a running app is a different layer — the `.app(bundleId)` scope (Context Dock Chat
> Mode), documented separately in `03-APP-SCOPED-CHAT.md`. Keeping chat out of this doc is
> deliberate and matches `PRODUCT_LAYERS.md`. `[code — docs/architecture/CHAT_SCOPES.md]`

---

## 2. How the user opens it

- Entry point `activateGlobalContextScope()` — `App/ILauncherApp.swift:2457`. `[code]`
- Routed as `AppRouter.globalContext` — `App/AppRouter.swift`. `[code]`
- Signalled app-wide via `Notification.Name.activateGlobalContext` — `App/NotificationNames.swift:17`. `[code]`
- Exact default hotkey / gesture that reaches this scope: **`[?]` needs confirmation** (there
  is keyboard handling around `ILauncherApp.swift:2075`, but the user-facing default binding
  should be stated by the owner or read from `HotkeysSettingsPage`).

---

## 3. What the user sees

The Global Context surface (`Search/GlobalContextSurface.swift`) is one shell with: `[code]`

1. **A search field** — you type a query.
2. **A top-match icon row** — the most likely apps/commands as tappable icons
   (`MatchDockIcon`), each showing whether the app is running and whether it can expand into
   its cached menu actions.
3. **A results list** — ranked results across every category in §4.

Per the Unified Dock Surface rule, the shell stays stable while the query changes — the sheet
is not recreated per keystroke. `[code — docs/architecture/UNIFIED_DOCK_SURFACE.md]`

---

## 4. What it searches — result categories

Grounded in `Search/SearchResult.swift` (`ResultType`) and `Search/LauncherView+Search.swift`
(`SmartQueryType`). `[code]`

| # | Category | What it is | Backing source |
|---|---|---|---|
| 1 | **Installed apps** | every app on disk | app index |
| 2 | **Running apps** | live processes, shown as icons | `GlobalMenuAppSnapshot`, `runningApp` kind |
| 3 | **App menu search** | menu actions of *any* app, from cache | `GlobalContextEngine` (`GlobalMenuDescriptor`), `AppMenuCapabilityCache` |
| 4 | **Global / universal commands** | app-independent commands | `globalCommand` kind |
| 5 | **Extensions** | built-in + user global extensions (see §6) | `extensionCommand`, `BuiltInExtensions`, `UserGlobalExtensionStore` |
| 6 | **CLI / TUI tools** | installed terminal tools | `cliTool`, `TerminalPackageManager` |
| 7 | **Files / folders / documents** | file-system results | file search |
| 8 | **Apple-app content** | contacts, calendar events, reminders, notes, mail, photos, messages | `ResultType` cases + `SmartQueryType` panels |
| 9 | **Web search** | fallback query to the web | `webSearch` type |

**Owner's original list covered categories 1, 2, 3, and 5 (4 of 9).** Categories 4, 6, 7, 8,
9 were not named — worth confirming they're all still wanted, or if some should be cut. That
choice is part of finding the app's goal.

---

## 5. The top-match icon row (running + installed apps)

`Search/GlobalContextTypingModel.swift`. `[code]` Top matches come in four kinds:
`installedApp`, `runningApp`, `globalCommand`, `cachedMenuApp`.

Each icon (`MatchDockIcon`) carries: `isRunning`, `isExpandable` (has cached menu actions to
drill into), a rank `score`, and `isExactAppPrefix` (the query is an exact app-name prefix).
Selecting launches the app, or expands it into its cached menu actions.

---

## 6. Global extensions

Two sources feed the "extension" results the owner calls "global extension": `[code]`

- **Built-in extensions** — `Services/BuiltInExtensions.swift`: `copy`, `copyPath`,
  `fileInfo`, `getInfo`, `revealInFinder`, `countWords`, `summarize`, `uppercase`,
  `lowercase`, `appInfo`, `pasteFromClipboard`. They run with no external script.
- **User global extensions** — `UserGlobalExtensionStore` (results carry a `userext://` id).
  User-defined; each has its own `searchTerms`.

> The 3-layer extension model overall (L1 keyword quick-actions / L2 context actions / L3
> web) is bigger than Global Context and gets its own doc (`07-EXTENSIONS.md`). Here we only
> document the **L1 global extensions that appear in Global Context search**.

---

## 7. Ranking & learned usage

`Services/GlobalSearchService.swift`. `[code]`

- Candidate matching is **n-gram based** (`grams(_:)`), scored per document (`matchScore`).
- A **learned-usage boost** (`learnedUsageBoost`) raises the rank of apps/actions the user
  runs often — the surface adapts to the individual over time.
- Installed and recently used apps rank high by rule
  (`PRODUCT_LAYERS.md` → Global Context rules).

---

## 8. Execution

`Services/MenuExecutionCoordinator.swift` + `GlobalMenuExecutionRequest`. `[code]`

A chosen menu item is executed through a request carrying the target bundle ID, app name,
app path, the menu `path`, and the keyboard `shortcutChar`/`shortcutModifiers`. This lets
Global Context fire another app's menu action **without the user switching to that app** —
one of the app's genuinely distinctive abilities.

---

## 9. Performance rules (must hold)

From `PRODUCT_LAYERS.md` / `PERFORMANCE_RULES.md`: `[code]`

- **No live accessibility (AX) refresh while typing.**
- **No menu scan while typing.**
- **Cache-first index**; verify live state only when needed for execution.

Reason: typing latency is the whole product here. A scan-per-keystroke makes search feel
broken.

---

## 10. Engineering map (files)

| Concern | File |
|---|---|
| Menu/app snapshot model & descriptors | `Services/GlobalContextEngine.swift` |
| Search index, matching, ranking, learned boost | `Services/GlobalSearchService.swift` |
| Result source shared by dock + result sheet | `Services/GlobalContextResultSource.swift` |
| Search coordination | `Services/GlobalContextSearchCoordinator.swift` |
| Menu execution | `Services/MenuExecutionCoordinator.swift` |
| Cached menu capabilities | `Services/AppMenuCapabilityCache.swift` |
| The surface (view) | `Search/GlobalContextSurface.swift` |
| Typing model, top-match kinds | `Search/GlobalContextTypingModel.swift` |
| Result type & metadata | `Search/SearchResult.swift` |
| Query handling & smart queries | `Search/LauncherView+Search.swift` |
| Global-context actions on the view | `Search/LauncherView+GlobalContextActions.swift` |
| Built-in extensions | `Services/BuiltInExtensions.swift` |
| Activation entry | `App/ILauncherApp.swift` (`activateGlobalContextScope`) |

---

## 11. What Global Context is NOT (boundaries)

- **Not chat.** Chatting with an app = App-Scoped Chat (`.app(bundleId)`). General questions
  = AI Assistant Mode. `[code — CHAT_SCOPES.md]`
- **Not the frontmost-app command sheet.** That is Context Dock (a separate layer).
- **Not selection-aware.** Acting on selected text/file/clipboard = Selection Shortcut Sheet.

---

## 12. Known gaps / open questions (to resolve with owner)

1. **Hotkey/gesture** that opens Global Context — confirm the default binding. `[?]`
2. **Is web search (cat. 9) still wanted**, or does it dilute a focused launcher? `[owner decision]`
3. **Apple-app content results (cat. 8)** overlap with dedicated Apple-app flows elsewhere —
   is Global Context the right home, or should it only *launch into* those? `[owner decision]`
4. **No automated tests found** specific to Global Context ranking/search. Ranking quality
   (does the right result come first?) is currently unverified. `[gap]`
5. **Learned-usage boost** has no visible user control (no "forget this" / reset). `[possible feature]`
6. **Success metric undefined.** There is no measure of "did the user find/launch what they
   meant on the first result?" — the one number that would tell you if this surface works. `[gap]`

---

*End of draft. Redline this file directly; it merges into `docs/architecture/` only after
owner confirmation.*
