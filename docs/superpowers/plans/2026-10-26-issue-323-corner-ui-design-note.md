# Task 323 — Corner UI: design note (Phase 0 audit)

Spec: issue #323 + `2026-10-26-corner-ui-from-claude-desktop.md` §2.7 / §2.8 (PR #321).
Status: **Phase 0 only — no Swift touched.** Phase 1 waits for #318 (PR #320) to merge.

## 1. The issue's "first implementation step": do compact App Chat and the full window share a model and a panel?

**Conversation: shared in storage, not in memory. Right panel: NOT shared — that is the real work.**

| Piece | Compact App Chat | Full window (⌃C) |
|---|---|---|
| Live conversation object | `AppChatConversation.shared` (`Search/LauncherState.swift`); DockCore is the only writer | `GeneralChatWindowModel.shared` (`AI/GeneralChatWindowModel.swift`) |
| Persistence | `GeneralChatSessionStore.dockPanelKey` → `dock_app_<bundleId>` (and `dock_app_cli://`, `dock_folder_`) | same key, via `GeneralChatSessionStore.load/save(scope:)` |
| Engine | `AppScopedChatService` (static, stateless — it is **not** the shared model) | same |
| Right panel | `CornerLivePanel` (Progress / Files / Connectors / Can do here), hosted only by `AppChatPromptPill` | `sidePanel` inside `GeneralChatWindowView` — tabs terminal / preview / artifacts / scope (`ScopeInventory`) |

- The two surfaces already hand a thread across through the store. `GeneralChatSessionStore.dockPanelKey`'s own comment says
  the window "is a second view of that conversation rather than a copy of it". So the transcript survives expand **if** the
  window re-reads the store (`openSession(scope, title:, seed:)`) and the dock has flushed its in-memory messages first.
  A turn still running in `AppChatConversation` is the one case to handle (finish/flush, or show it live).
- `CornerLivePanel` and the window's `sidePanel` are **two designs today**. `CornerLivePanel` is also hard-wired to
  `AppChatConversation.shared`, so it cannot be hosted in the window as-is.
- The existing expand glyph in the compact App Chat header (`AppChatPromptPill` ~L1010, `model.openInDock()`) is
  *Open in the dock* (`handOff`), not Open in the window. `CornerGeneralChatView` ~L303 already calls
  `GeneralChatWindowController.shared.show()` — but without selecting a thread or the Chat tab.
- Footer today (`AppChatListCard.footer`, `BoardFooter`): pin + gear only. The expand glyph is absent there.
- Sizes today: `AppChatPromptMetrics.width = 372`, `chatHeight = 340` (+ per-message growth), `CornerDockLayout.cardWidth = 372 /
  cardHeight = 620`, `DockShellWidth.base = 600`. Panel is `CornerLivePanelLayout.panelFraction = 0.42` of the card.
  Centre vs corner: same one-size rule (owner 2026-09-25) — to verify by eye, not assume.

## 2. Plan (Phase 1)

### §2.7 — size + footer expand
1. **Size bump**: raise the compact chat card constants in one place (`AppChatPromptMetrics` / `CornerDockLayout`), keeping
   corner and centre on the same number. Pin the numbers in `CornerDockLayoutTests` / `CentredCornerTests`.
2. **Expand control in the footer** beside pin + gear, in every chat scope (App Chat, General Chat). Remove the
   header-only variants. Not shown for Global Context (layer rule).
3. **Route**: new `GeneralChatWindowController.show(opening: GeneralChatScope)` →
   `chrome.mode = .chat`, `model.openSession(scope, …)` after flushing `AppChatConversation` to the store.
   Esc / collapse in the window returns focus to the compact shell. ⌃C unchanged.

### §2.8 — one rail, two densities
- Extract the rail into **one** view (`CornerRail`, name TBD) driven by a small value-type `RailModel` (scope, usage,
  connectors, can-do counts, app pack, skills, mods, outputs) built from the stores the cards already read
  (`MCPServerManager`, `AppAdapterManager`, `ScopeInventory`, `TurnFileExtractor`, `ArtifactStore`). It takes
  conversation inputs as parameters, so it no longer hard-wires `AppChatConversation.shared`.
- Two densities via an enum, same component: `.compact` = Scope · Connectors · Can do here · Progress (what ships today);
  `.full` = all of Scope / Usage / Connectors / Can do here / App Pack+Plugins / Skills / Mods / Outputs.
- Window: replace the card content of `sidePanel`'s `.scope` tab with the rail; keep the terminal/preview/artifacts tabs
  (those are the Outputs card's detail). Files tree rejected → Outputs card.
- Material: window's corner radius + `glassDarkness` Liquid Glass taken from the compact shell's constants, not copied.

### Tests
swift-testing for: footer shows expand only in chat scopes; size constants equal across anchors; `RailModel` card set per
density; open-in-window selects the scope and `.chat` mode. UI checked by eye with screenshots per AGENTS.md (can only be
done on the Mac builder — this cloud session is Linux and cannot build the Xcode project).

## 3. Files #323 and #318 both touch

#318 (PR #320, `claude/issue-318-unify-dock-surface-561302`) currently changes: `UI/CornerDockWindow.swift`,
`UI/CornerChatPresentation.swift`, new `UI/SurfaceFocus.swift`, `AGENTS.md`, `.claude/CLAUDE.md`, `docs/architecture/PRODUCT_LAYERS.md`,
`docs/master/DORAX-BLUEPRINT.md`. (As of d8b6a85; it is still moving.)

| File | #318 | #323 | Collision |
|---|---|---|---|
| `UI/CornerDockWindow.swift` | yes (focus/⌘ routing) | size, footer hosting, expand wiring | **yes** |
| `UI/CornerChatPresentation.swift` | yes | hand-off to window | **yes** |
| `UI/CornerBoardLayout.swift` | expected (issue text) | `CornerLivePanelLayout` → rail layout | **likely** |
| `UI/AppChatPromptPill.swift`, `UI/AppChatListCard.swift`, `UI/CornerGeneralChatView.swift` | not yet | footer/header expand glyph | possible |
| `UI/CornerDockLayout.swift`, `AppChatPromptMetrics` | not yet | size constants | possible |
| `UI/CornerLivePanel.swift` | no | extracted into the shared rail | no (today) |
| `UI/GeneralChatWindowView.swift`, `App/GeneralChatWindowController.swift`, `AI/GeneralChatWindowModel.swift` | no | window rail + open-with-scope | no |
| `AGENTS.md`, `docs/architecture/PRODUCT_LAYERS.md` | yes | docs only if the layer text changes | low |

Safe to do before #318 lands (zero overlap): the rail extraction itself (`CornerLivePanel` → shared view + `RailModel` +
tests) and the window-side `show(opening:)` — **but** the issue says to wait, so Phase 0 stops here.

## 4. Open questions for the owner
1. Does the full window get light arrange/split + open-in-new-window, or only the rail show/hide toggle? (Default if no answer: toggle only.)
2. Exact content of the **Mods** card. (Default: hidden until a mod applies to the scope.)
3. If a turn is still running when expand is pressed: carry it live into the window, or wait for it to finish?
