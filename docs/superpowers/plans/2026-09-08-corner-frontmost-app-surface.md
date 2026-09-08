# Corner becomes the frontmost-app surface

**Decided 2026-09-08.** The two entry points get one job each:

| Surface | Opened by | Owns |
|---|---|---|
| Dock | double-tap Option | Global Context, Media, General chat |
| Corner | the app hotkey | **the frontmost app** — chat, its menu commands, its actions |

Today the dock owns both, and the corner's app chat can ask a question but cannot show the
app's own commands. This plan moves the frontmost-app job to the corner and retires the
dock's copy of it. It follows the DoraX rule in CLAUDE.md: one job per surface, and
"Context Dock is not Global Context".

## Why the corner cannot just call the dock's code

The dock's live menu filtering is ~150 lines of **local closures inside one function body**
in `LauncherView+ContextualActions.swift` (`dedupeMenuItems` 5197, `menuItemMatchesQuery`
5240, `frontmostLiveMenuMatches` 5265, `scopedRunningMenuMatches` 5279). They call eight
helpers that are **methods on `LauncherView`** — a SwiftUI struct with 420+ `@State` vars —
even though not one of them reads view state:

| Helper | Lives on LauncherView at |
|---|---|
| `normalizedDockPillText` | `LauncherView+ContextDockPills.swift:3199` |
| `dockPillTokens` | `LauncherView+ContextDockPills.swift:3215` |
| `pillEditDistance` | `LauncherView+ContextDockPills.swift:3542` |
| `isRejectedTopMenuItem` | `LauncherView+ContextDockPills.swift:3280` |
| `isGenericAppMenu` | `LauncherView+ContextDockPills.swift:3284` |
| `shouldExposeCachedMenuItem` | `LauncherView.swift:1014` |
| `rankedTextMatchScore` | `LauncherView+GlobalContextActions.swift:1110` |
| `distributedMenuItems` | `LauncherView+ContextualActions.swift:4225` |

Nothing outside that view can rank a menu item. That is the blocker, and it is also why
the ranking has never had a direct test.

## Phase 1 — extract the matcher, show it in the corner

The shippable slice. Ends with: typing in the corner's app chat filters the frontmost app's
menu commands live, above the input, the way the clipboard preview sits above it.

1. **`FrontmostMenuMatcher`** — new file, pure, no view, no AX calls. Takes items + query +
   a policy, returns ranked matches. The eight helpers move here as static funcs; the text
   rules (normalize, tokens, edit distance, ranked score) come with them unchanged.
2. **`LauncherView` forwards to it.** The methods above become one-line calls so the dock's
   behaviour is provably identical — same ranking, same limits, same dedupe key.
3. **Tests first**, against the matcher directly: exact title, prefix, substring, token
   overlap, the `>= 4` edit-distance rung, dedupe by path, shallower path wins ties,
   empty query distributes across menus rather than ranking.
4. **`AppChatMenuPreview`** — the corner surface. Rows: title, path crumb, shortcut. Driven
   by `AppChatPromptModel.query`.
5. **Slot it into `CornerDockWindow`** beside `slots.preview` / `slots.clipboard`. Size from
   a pure metrics function of model state — never a measured height
   (memory: `corner-pill-size-must-be-pure`).
6. **Keyboard**: gate arrows/Enter on which corner surface holds the keyboard
   (memory: `corner-surfaces-share-one-key-monitor`) — the clipboard and the chat already
   share one monitor, this is a third claimant.
7. **Running a row** goes through `MenuExecutionCoordinator`, so the existing consent and
   irreversible-action gates hold (`IrreversibleMenuConsentTests`). A menu click stays the
   last resort it is today (memory: `menu-clicks-are-last-resort`) — here the *user* picks
   the row, which is the one case where it is not a guess.

## Phase 2 — the app's actions, not only its menus

Adapter actions, skills and CLI tools for the frontmost app, in the same list, ranked
together with menu commands. `AppChatSuggestionProvider` already assembles them for the
resting state; this makes them filterable. Issue #13 (suggestions are alphabetical, so the
useful ones never surface) is the same problem and gets fixed here.

## Phase 3 — retire the dock's frontmost path

Delete the dock's app-scope menu route once the corner covers it. The dock keeps Global
Context, Media and General chat. This is where `LauncherView` finally gets smaller.

## Phase 4 — scope pills and keyboard

Move whatever of the dock's app-scope keyboard model still earns its place, and settle what
the scope pill means when the dock no longer has an app scope.

## Not in scope

Corner General chat is untouched — it is a different surface with a different job.
