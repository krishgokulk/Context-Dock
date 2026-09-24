# 00 — Dock and Corner: one product, two shells, one migration

> **Status: CURRENT — owner-confirmed direction (2026-09-24).** Read with
> [`DORAX-BLUEPRINT.md`](DORAX-BLUEPRINT.md) Part 1–2 and
> [Hotkeys as built](00-COMPLETE-APP-PLAN.md#hotkeys-as-built-code).
> Tags: `[code]` read from source · `[owner]` owner's statement · `[plan]` written in a plan, not verified as built · `[?]` needs checking.

---

## 1. The one-paragraph version

DoraX draws its surfaces in **two shells**. The **Dock** is the original, larger UI that opens in
the **centre** of the screen. The **Corner** is the newer, **compact** UI that sits along the
**bottom** of the screen. Both run the **same engine** and are meant to have the **same behaviour
and navigation** `[owner]`. The owner is moving features **from the Dock into the Corner, one at a
time** `[owner]`. The Corner is the future everyday UI; the Dock stays until everything it does has
a Corner home.

---

## 2. The two shells

| | **Dock** (original) | **Corner** (compact, the direction) |
|---|---|---|
| Opens with | **⌥⌥** double-press Option — "show launcher" `[code]` | **⌘⌘** double-press Command — Global Context *in the corner* `[code]`; plus the App Chat / Selection / Clipboard hotkeys the user records `[code]` |
| Where | Centre of the screen | Bottom edge — **Left / Centre / Right** (Settings → Appearance → Corner Position, `cornerDockAnchorRaw`) `[code]`. Centred, it reads as a dock `[code: settings text]` |
| Size | Full sheet with rows and pills | One compact input that grows only as far as the task needs |
| Look | Liquid Glass | Liquid Glass; **Glass Darkness** slider (0% = pure glass) applies to both `[code: glassDarkness]` |
| States | Result sheet, pills, chat | Phases `hidden · mini · dock · prompt · suggesting · chat` (`UI/AppChatPromptModel.swift`, `AppChatPromptPhase`) `[code]` |
| Code home | `Search/LauncherView*` (39 extension files) | `UI/Corner*`, `UI/AppChat*`, `UI/SelectionScope*`, `Search/ClipboardPanelWindow`, `UI/DropShelf*` `[code]` |

**What the Corner holds** (all along the bottom, beside each other — Settings text `[code]`):
the chat, the clipboard, the selection card and the shelf. "Corner" is the historical name; with
Centre chosen, it is a bottom-centre dock.

---

## 3. The rule: same behaviour, same keys, compact shape

The Corner is **not a different product** — it is the same surfaces in a smaller shell. So:

1. **Same engine.** Both shells call the same chat engine (`AppScopedChatService` →
   `ScopedTurnRunner`), the same approval inbox, the same verifiers (`docs/master` 03/04/08) `[code]`.
   A shell never gets its own copy of a pipeline.
2. **Same navigation.** A key means the same thing in both shells: ⌘ tap switches Global ↔ app
   scope, → scopes into the highlighted app, ↩ runs, Esc steps back / closes
   (Hotkeys → Dock Key Map) `[code]`. If a key has to behave differently in the Corner, that is a
   design decision written down here — not an accident.
3. **Same names.** General Chat, App Chat, Global Context, Selection, Clipboard — identical labels in
   both shells (blueprint → Names).
4. **One shell per screen, never a second floating box** — the Unified Dock Surface rule in
   CLAUDE.md applies to the Corner too: new states are *phases* of the Corner, not new windows.
5. **Compact first.** In the Corner, a result appears above the input and the input never moves;
   the card grows only as far as the answer needs, then stands back down.

---

## 4. Migration tracker — what has moved, what has not

"Moved" means the Corner does the job itself, not hands it to the Dock.

| Job | Dock | Corner | Status | Source |
|---|:-:|:-:|---|---|
| Global Context search | ✅ | ✅ | **Moved** — ⌘⌘ opens it in the corner | `[code]` Hotkeys page |
| Global Context at rest as a dock strip (running apps + pins) | — | ✅ | **Corner-only**, built through Task 5 | `[plan]` spec 2026-09-15 "as built" note |
| App Chat (ask the frontmost app) | ✅ | ✅ | **Moved** | `[code]` App Chat hotkey |
| General Chat | ✅ | ✅ | **Moved** — parity tasks 1, 2, 3, 6, 8 done | `[code]` CLAUDE.md current sequence |
| Frontmost app's menu commands + actions | ✅ | 🟡 | **In progress** — plan 2026-09-08 Phases 1–4; Phase 3 retires the Dock's copy | `[plan]` `[?]` which phase is done |
| Clipboard | ✅ | ✅ | **Moved** — ambient pill + card | `[code]` `ClipboardPanelWindow` |
| Selection | ✅ | ✅ | **Moved** — selection card; auto-scopes on launch when no hotkey is set | `[code]` |
| Drop shelf | — | ✅ | **Corner-only** | `[code]` `DropShelfWindow` |
| Extensions as a scope (e.g. Currency Converter) | ✅ | ❌ | **Not moved** — the Corner finds the row, then hands it to the Dock | `[plan]` 2026-09-10 scope stack, "plan only" |
| CLI tools as a scope (+ terminal) | ✅ | ❌ | **Not moved** — same hand-off | `[plan]` 2026-09-10 Phases 3–4 |
| Media Dock | ✅ | ❌ | **Not moved** — and Labs in v1 | `[code]` `MediaDockSurface` |
| Full-window chat | Chat Window (separate) | — | Stays a separate window by design | `[code]` Chat Window hotkey |

**Keep this table current.** Each PR that moves a job updates its row. When the last Dock-only row
reads "Moved", the Dock can retire (§5).

**Plan checkboxes are not a status source:** the 09-15 and 09-03 corner plans show 0 of 44 and
0 of 33 boxes ticked even where the work shipped. Status comes from the code or the owner, not the
boxes.

---

## 4a. Selection in the Corner — only half moved (owner report, 2026-09-24)

**Correction to §4:** the Selection row says "Moved". It is **partial** `[owner]` `[code]`.

| | Dock (before) | Corner card today (`UI/SelectionScopeCard.swift`, 137 lines) |
|---|---|---|
| Shows the selection + source app | ✅ | ✅ "1 char · TextEdit" |
| Ask about the selection | ✅ | ✅ field at the bottom |
| **Actions for the selection** — app menu commands, extensions, Shortcuts, AI presets (the Selection Shortcut Sheet's job, doc `05`) | ✅ filtered live as you type | ❌ none — the card has only the text, a pin and the field |
| **Close** | Esc | Esc only (`onKeyPress(.escape)`); **no visible close button**. Auto-hides after 8 s idle unless pinned (`SelectionScopeModel.idleDwell`) |

Why it feels incomplete: the Corner took over *showing* the selection but not *acting on* it, so the
surface lost its one job ("selection-aware action engine", `docs/architecture/SELECTION_SHORTCUT_SHEET.md`).

**Done when** (acceptance for moving Selection):
1. Typing in the card's field filters the same actions the Dock showed — menu commands of the source
   app, selection extensions (`Services/SelectionScopeExtensionPolicy.swift`,
   `Search/SystemExtensionActionSource.swift`), Shortcuts, AI presets — above the field, the way the
   clipboard preview sits above its input.
2. ↑/↓ moves through them, ↩ runs one, the field stays where it is (same keys as the Dock, §3 rule 2).
3. An empty field + ↩ asks the question, as today.
4. A visible ✕ closes the card; Esc still does too.
5. Reuse the Dock's action source — do not write a second ranking (§3 rule 1). If it is locked inside
   `LauncherView`, extract it first, as the 2026-09-08 plan did for menu matching.

**Related bug found while testing:** the Selection Scope hotkey was recorded as **⇧S**. A Shift-only
global hotkey captures every capital S typed anywhere, so typing "S" in TextEdit opened this card.
Fix: the recorder must require ⌘, ⌥ or ⌃ (`UI/Settings/HotkeysSettingsPage.swift`, `startRecording()`).

## 5. The end state (owner decisions still open)

When every Dock job has a Corner home:

1. **What does ⌥⌥ open?** Options: the Corner centred (one shell for everything), General Chat in
   the Corner, or keep the Dock as a "big view" of the same state. `[owner decision]`
2. **Retire `LauncherView`'s Dock paths** — the frontmost-app plan already schedules this for its
   job (Phase 3). This is also the biggest cleanup in the codebase plan (39 `LauncherView+*` files).
3. **Rename "Corner"?** With Centre as an option it is really "the bottom dock". Users see neither
   word today; decide before writing onboarding. `[owner decision]`

---

## 6. Stale text to fix (for the Mac session)

- `docs/superpowers/plans/2026-09-08-corner-frontmost-app-surface.md` — its table says the Dock
  (⌥⌥) owns Global Context; today ⌘⌘ opens Global Context **in the corner**. Add an "as built" note.
- `docs/architecture/UNIFIED_DOCK_SURFACE.md` / `PRODUCT_LAYERS.md` — describe one shell; add that
  the rule covers **both** shells and that the Corner is the migration target.
