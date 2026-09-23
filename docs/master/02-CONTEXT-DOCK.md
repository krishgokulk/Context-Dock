# 02 — Context Dock (frontmost-app command layer)

> **Status: DRAFT / under review — written against current code (audit-clean).** Not merged yet.
> Tags: `[code]` verified in source · `[owner]` owner's stated knowledge · `[?]` needs confirmation.
>
> **Not the chat.** This is the *command* layer for the frontmost app (run menus/actions).
> Chatting with that app is `03-APP-SCOPED-CHAT.md`. Same app, different job.

---

## 1. One job

**Context Dock = the frontmost-app command layer.** `[code — PRODUCT_LAYERS.md]`
Show the current app's menus, actions, adapters and extensions, and **execute** them — fast,
native, without leaving the app.

Rules (from `PRODUCT_LAYERS.md`): scope stays the frontmost app; the result sheet stays
**stable** while the query changes (no per-keystroke sheet rebuild); live menu state may
update but the UI must not recreate the sheet each keypress; execution must feel native and
instant.

---

## 2. What the user sees / does

- The dock, scoped to whatever app is in front, shows that app's runnable commands as
  **pills** (`DockPill`).
- Typing filters the pills; selecting one **runs** it in the app.
- The sheet is a stable surface — the Unified Dock Surface (one shell, mode-specific content).
  `[code — UNIFIED_DOCK_SURFACE.md]`

---

## 3. How pills are assembled

`ContextDockPillCoordinator` `[code — Search/ContextDockPillCoordinator.swift]` takes an
`Input` of: current query, last query, a **debounce delay** (`delayNanoseconds`), whether to
refresh context, **cached pills**, **preview pills**, and whether the query is
"question-style". It merges cached + preview results under the debounce so the sheet stays
stable and typing stays fast — the performance rule made concrete.

Sources of the commands:
- **Verified app menu commands** — `AppMenuCapabilityCache` (leaf menu items + shortcuts),
  refreshed from the app's live AX tree.
- **App adapter actions** — `AppAdapterManager`.
- **App extensions** — the extension system (`07`).

---

## 4. Execution

`MenuExecutionCoordinator` + `GlobalMenuExecutionRequest` — the same execution path Global
Context uses (`01` §8): a request carrying bundle id, menu path, and shortcut fires the app's
menu action directly. `[code]`

---

## 5. How the frontmost app is detected

- `AppDelegate.previousFrontmostApp` — because when the dock is open, `frontmostApplication`
  is Context-Dock itself, so the *previous* frontmost app is the real target. `[code]`
- The accessibility pipeline (`AXObserver`, `AXEventBus`, `CrossAppRouter`) tracks app
  activation and focus so the dock knows which app it's scoped to. `[code — CLAUDE.md AXEventBus]`

---

## 6. Boundaries

- **Not chat** (that's `03`). **Not Global Context** search (`01`). **Not selection-aware**
  (`05`). Scope is always the frontmost app.

---

## 7. Engineering map

| Concern | File |
|---|---|
| Pill assembly + debounce | `Search/ContextDockPillCoordinator.swift` |
| Contextual actions on the view | `Search/LauncherView+ContextualActions.swift` |
| Context detection / lifecycle | `Search/LauncherView+ContextDetection.swift`, `+ContextLifecycle.swift` |
| Menu cache | `Services/AppMenuCapabilityCache.swift` |
| Execution | `Services/MenuExecutionCoordinator.swift` |
| AX pipeline | `Accessibility/AXObserver`, `AXEventBus`, `Automation/CrossAppRouter` |

---

## 8. Known gaps / open questions

1. **Menu-cache freshness** — a stale cache can offer a command that no longer exists; live
   verification before execution mitigates, but the timing window is `[?]`.
2. **Overlap with Global Context** — both show/execute app menu commands (`01` cat. 3). What
   makes this the *frontmost* command layer vs Global Context's cross-app menu search is the
   fixed scope; keep that boundary explicit or the two blur. `[owner decision]`
3. **No tests** on pill assembly/ranking or execution correctness. `[gap]`

---

*End of draft. Redline directly; merges after owner confirmation.*
