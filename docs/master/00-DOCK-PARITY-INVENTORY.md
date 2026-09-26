# 00 — Dock → Corner parity inventory

> **Goal (owner, 2026-09-24):** move the ⌥⌥ Dock into the Corner with **exactly** the same
> behaviour, functions and navigation. The Dock retires only when every row here is ✅ or has an
> owner decision next to it.
> **Built 2026-09-24 from the code** on `claude/jev-popularity-comparison-t530yd`.
> Dock side read from `Search/LauncherView+KeyboardNavigation.swift`,
> `Search/LauncherView+InteractionLifecycle.swift`, the Hotkeys page and the surface files.
> Corner side read from `UI/AppChat*`, `UI/Corner*`, `UI/SelectionScope*`, `UI/GlobalContextRow.swift`
> and the Corner test files.

## How to read this

| Mark | Meaning |
|---|---|
| ✅ | Corner does it — a **test** named in the Evidence column proves it |
| 🟡 | Corner does part of it, or the code has it but no test pins it |
| ❌ | Corner does not do it |
| ❓ | Not verified from the cloud — **the Mac session must check it** |
| — | Not a parity item (owner decision / Dock-only by design) |

**Rules for whoever works a row:** reuse the Dock's code (extract it from `LauncherView` if needed),
add a swift-testing test, change the row to ✅ with the test's name, one PR per group.
The Mac agent must also correct any row it finds wrong — this list is a starting point, not gospel.

---

## A. Opening, closing, position

| # | Dock behaviour | Corner | Evidence / note |
|---|---|---|---|
| A1 | ⌥⌥ opens the launcher | — | Owner 2026-09-25: ⌥⌥ opens the Dock, ⌘⌘ opens the Corner — fixed, no setting. End state after the Dock retires still open (`00-DOCK-AND-CORNER.md` §5) |
| A2 | ⌘⌘ opens Global Context | ✅ | Opens in the Corner (Hotkeys page); `CornerGlobalContextParityTests` |
| A3 | Hotkey toggles: pressing again puts it away / brings it back | ✅ | `theHotkeyPutsAnOpenCornerAway`, `theHotkeyBringsBackAShrunkenCorner` |
| A4 | Esc closes / steps back one layer | 🟡 | Corner General Chat: `CornerGeneralChatView.handleEscape` (one layer per press). Global/app field (checked on the app 2026-09-24): Esc clears the query first, then closes — no step back through scopes |
| A5 | Idle collapse timer when nothing typed | ✅ | Corner idle shrink: `generalChatShrinksThenHidesAndHoverRestoresIt`, `pinAndComposerFocusProtectGeneralChatFromIdleShrink` |
| A6 | Position | — | Dock = centre; Corner = Left / Centre / Right (`CornerDockAnchorTests`) — Corner is richer by design |
| A7 | Dock height presets (`LauncherView+DockHeight`) | — | Corner sizes itself to content (`AppChatPromptMetrics…Tests`); not a parity item |

## B. The input field

| # | Dock behaviour | Corner | Evidence / note |
|---|---|---|---|
| B1 | Ghost-text completion; **Tab** / **→** accepts | ✅ | "The focused row is what Tab and the right arrow take" |
| B2 | Pills are atomic text: Backspace at a pill's right edge turns it back into text; ←/→ jump over a pill in one press | — | Not a Corner feature (task 5 part 2, #98): the Dock types app scopes **into the text** (inline pills, several at once); the Corner's scope is one leading chip outside the text, so there is no pill inside the text to delete or jump. Leaving the chip is B3. Owner to confirm |
| B3 | Backspace on empty field steps out of the current scope (folder → Finder search, app chat → app menus, Global inline scope pops) | ✅ | `DockKeyRules.emptyBackspace`, the Dock's ladder in its order — folder, Selection Scope, app chat, scope from Global (#98): `emptyBackspaceLadder`, `foldersAreWalkedByKey`, `backspaceWithTextIsTheField`. Scope → Global checked on the app 2026-09-24. Inline-scope pops: see B2 |
| B4 | Backspace on empty field in Selection Scope leaves the scope **and** closes | ✅ | The Corner's Selection Scope is the Selection card (D10): Backspace on its empty field closes it, now through `DockKeyRules.emptyBackspace` (#98, `emptyBackspaceLadder`). The in-place selection view inside the app field follows the same rung. Hand check owed |
| B5 | Typing a printable key while at rest expands and seeds the field | ✅ | `aPrintableCharacterExpandsAndSeeds` |
| B6 | Draft kept when switching scope / app | ✅ | `switchingModesPreservesIndependentDrafts`, `comingBackToTheSameAppKeepsWhatWasTyped` |
| B7 | "quit <app>" + ↩ quits the app the icon previews (before the list builds) | 🟡 | `AppChatMenuBrowsing.localGlobalQuitRows` exists; no test found |

## C. Results and keys

| # | Dock behaviour | Corner | Evidence / note |
|---|---|---|---|
| C1 | **↓** first press expands the result sheet **and highlights the first row**, then moves down | ✅ | The old note was wrong: the Dock's first ↓ is `expandGlobalContextTypingMatch(selectFirst: true)`, which opens and lands on row 1, exactly as the Corner does. Now one rule, `DockKeyRules.listArrow` (#98): `firstArrowLandsOnARow`, `firstDownOpensOnTheTopRow` |
| C2 | **↑ / ↓** move through grouped app/menu rows | ✅ | checked on the app 2026-09-24: ↓↓ walks the Global rows (Safari → Turn Off the Lights…) |
| C3 | **↩** runs the focused row, or the top row if none is focused | ✅ | `DockKeyRules.returnRow` (#98): `returnRunsFocusedOrTop`, `returnRunsTopOrFocused`. Top row only in a search field (Global and scopes from it); in an app chat ↩ with nothing highlighted sends the question |
| C4 | **←** leaves result focus back to the field | ✅ | `DockKeyRules.resultFocus`, read by both shells (task 5, #96): `leftLeavesResultFocus`, `leftLeavesTheRow`. Hand check on the app owed |
| C5 | **Esc** collapses the sheet to compact typing, keeps the query | ✅ | `DockKeyRules.resultFocus` (#96): `escapeCollapsesKeepingQuery`, `escapeKeepsTheQuery`. A Finder search's resting results are not a sheet Esc closes — there Esc still clears, then closes. Hand check owed |
| C6 | **Backspace** on a focused row clears focus only (never quits an app) | ✅ | `DockKeyRules` (#96): on a row it lets go and deletes nothing (`backspaceOnlyClearsFocus`, `backspaceNeverQuits` — a focused "Quit Safari" row is not run); on a pill it lets go and stays in the scope (`backspaceAndEscapeLetGo`, `backspaceOnAPillStays`). Hand check owed |
| C7 | **Tab** enters / leaves app-pill navigation (and blocks macOS Full Keyboard Navigation) | ✅ | `DockKeyRules.pillRow` (#96): `tabEntersAndLeaves`, `tabEntersPills`, `aFocusedRowOutranksThePills`. Corner: the field's pills (running apps; an app bar's pins and tabs), after a focused row and the top match. Hand check owed |
| C8 | **→** on an app row scopes that app into a pill | ✅ | `rightArrowFromDockScopesLikeAnEmptyPromptDoes`, `steppingIntoAnotherAppTakesYouToThatAppsChat` |
| C9 | Pill row: ←/→ move focus, skip separators, wrap to the field at the ends | ✅ | `DockKeyRules.pillRow` (#96): `arrowsWalkAndWrap`, `separatorsAreSkipped`, `arrowsWalkThePills`; ↩ opens the pill as a click does (the Corner's click scopes into the app). Hand check owed |
| C10 | **Space** = Quick Look on the focused file/row (only while navigating, never while typing) | ✅ | `DockKeyRules.spacePreviews` (#98): `spaceIsASpaceWhileTyping`, `spaceWithoutARowIsAKeystroke`. Hand check owed |
| C11 | **→** on a folder row enters the folder | ✅ | #98: in the Finder scope → on a highlighted folder lists it (folders first, typing filters it), Backspace on the empty field climbs out one level and past the top back to the search: `foldersAreWalkedByKey`, `appsAreNotFolders`. → on an app row scopes into the app (checked 2026-09-25). Hand check owed |
| C12 | **⌘R** refreshes the front app's live menus | ✅ | Corner (#98): ⌘R in an app scope re-reads its live menus (`refreshIsForAnAppScope`). **The Dock never had it** — the Hotkeys page advertises ⌘R but no handler exists in `LauncherView`; filed as a follow-up. Hand check owed |

## D. Scopes (what you can step into)

| # | Dock behaviour | Corner | Evidence / note |
|---|---|---|---|
| D1 | Global Context search (apps, menus, files, commands, extensions, plugins, browser URLs) | ✅ | `CornerGlobalContextParityTests` (5 tests: same index, result kinds, row filtering) |
| D2 | Frontmost-app scope: its menus + actions | 🟡 | `CornerFrontmostAppPillsTests`; plan 2026-09-08 phases — see `00-DOCK-AND-CORNER.md` §4 |
| D3 | CLI tool scope | ✅ | `CornerCLIScopeTests` (7) |
| D4 | System command scope | 🟡 | → no longer runs a command row (checked on the app 2026-09-25: → on "Sleep" does nothing; `CornerRightArrowTests`). Stepping into a system command's panel not yet verified |
| D5 | Global Extension opens its own board | 🟡 | `GlobalContextRow.run`: "in the corner the extension opens in the board" — no test named |
| D6 | Plugin: panel or one-shot run | 🟡 | Same file: Corner opens the panel inline; no Corner test named |
| D7 | Finder: folder browse / desktop-only mode / attach current folder to chat | ❓ | `AppChatPromptModel` has Finder search; browse & attach not verified |
| D8 | Clipboard as a scope | ✅ | Separate Corner pill + card (`CornerDockLayoutTests`, `CornerKeyboardOwnerTests`) |
| D9 | Notifications compact scope | ❌ | No Corner code found |
| D10 | Selection Scope with actions | ✅ | #84, checked on the app row by row 2026-09-25 (TextEdit, Finder). The Dock's rows through `SelectionActionProviding` on the captured selection (`theDocksOwnRowsReachTheCard`, `aRowRunsOnTheCapturedSelection`, `keysChooseAndRun`, `closeAndEscapeClose`); answers inside the card (`theAnswerIsDrawnInTheCard`, `followUpsAndEscape`); Share (`shareSelectionInTheCard`). Extraction still owed: #83 |
| D11 | Quick Note split editor (list + editor, ⌘N new note, ↩ asks AI into the note) | ❌ | Dock-only (`NotepadScopeView`); the Quick Note hotkey opens a separate floating note |
| D12 | Mail find actions | ❌ | No Corner code found |
| D13 | Safari page actions | ✅ | Tabs, in Safari's **Context Dock** (owner 2026-09-25): the field folds away at rest — on idle or hovering its pill — into a bar of the app's own things, its open tabs (no Global pins or tools), the way Global Context folds into its running apps; typing or the app icon expands it back; the field carries the tabs as a small pill, "+N" past what fits; a click on a tab (big or small) switches Safari. Same shell and height as Global. From the Dock's loader (`SafariTabManager`) through the shared `BrowserTabList`. Pinned actions and pinned tabs: task 5 in `00-NOW.md`. Checked on the app 2026-09-25. `CornerSafariTabsTests` |
| D14 | Share actions | ❓ | Not verified |

## E. Chat

| # | Dock behaviour | Corner | Evidence / note |
|---|---|---|---|
| E1 | General Chat: ↩ sends, whoever holds focus; never sends twice | ✅ | `CornerGeneralChatTests` (12) |
| E2 | "/app" + ↩ picks the app without sending text | ✅ | `pickingSlashAppScopesWithoutSendingText`, `slashMatchesReserveOneRowEach` |
| E3 | Provider picker menu | ❓ | Dock ~l.249–271 (AppKit menu focus quirk) |
| E4 | Frontmost-app chat: Backspace on empty saves, hides chat, returns to the app's menu search | ✅ | #98: `leaveChatForMenus` via `DockKeyRules.emptyBackspace` — the conversation is kept (it is the Dock's), a running turn is stopped, the field is the app's menu search again: `backspaceLeavesTheChat`. The Dock also unpins the launcher; the Corner's pin only holds off the idle shrink, so it is left alone. Hand check owed |
| E5 | Attachments (file, image, Finder folder, Mail context) | 🟡 | `anAttachmentAddsItsRowAndNothingElse`; Finder-folder & Mail attach ❓ |
| E6 | Approvals shown in the composer | ✅ | `anApprovalIsReservedInTheComposerNotTheBoard` |
| E7 | Live progress / result feedback | ✅ | `CornerActionFeedbackTests` (11) |

## F. Layers and gestures

| # | Dock behaviour | Corner | Evidence / note |
|---|---|---|---|
| F1 | Trackpad swipes — all rows W1–W10 | ✅ | Owner hand-tested on the trackpad 2026-09-24 after PR #79 (`CornerNavigation`, `CornerSwipe`; `CornerScopeWalkTests`) |
| F2 | ↑/↓ keys switch Global ↔ Context ↔ Media when not in a list | ✅ | ↓ Global → app and ↑ back, checked on the app 2026-09-25 (`CornerRightArrowTests`, `theLayerKeysMoveBetweenGlobalAndTheApp`) |
| F3 | Media Dock layer | — | Labs; appears only if Settings' Media layer is on (same gate in the Corner — §4b W6) |
| F4 | Pinned results | ✅ | Corner dock strip pins (`DockPinStoreTests`, `pinsAreNeverOverflowed`) |
| F5 | Running apps shown and switchable | ✅ | `removedRunningAppsLeaveTheStrip`, `runningOverflowsIntoAPlusPill` |

## Corner-only (beyond the Dock)

What the Corner's Selection card does that the Dock's Selection never did (#84, owner
2026-09-25). Each has its test, all in `CornerSelectionActionsTests`.

| # | Behaviour | Test |
|---|---|---|
| X1 | **Share inside the card**: "Share Selection" lists the Mac's share destinations in the card (every share extension, the Dock's frecency order, typing narrows); Share at the end of an answer shares the answer | `shareSelectionInTheCard`, `typingNarrowsTheDestinations`, `shareTheAnswer`, `destinationsRankTheDocksWay` |
| X2 | **Typed "send to …"**: the card shows the recipient (as the contact lookup resolves it), the channel and the exact text, and sends only on Send (↩ or a click); Esc / Cancel / closing sends nothing | `aSendWaitsForConfirmation`, `nothingIsSentWithoutConfirmation`, `filteringIsNotSending` |
| X3 | **Save to Quick Note** on an answer | `copyAndSaveTheAnswer` |
| X4 | **File preview**: one file as its thumbnail with kind and size, several as a strip, a folder as its listing; Space or a click opens the app's preview | `previewKindFollowsTheSelection`, `spacePreviewsTheFiles`, `folderPreviewSize` |
| X5 | **Computer Use consent rule**: rows that drive an app's UI run only with Computer Use for that app (Writing Tools hide without it; Finder menu rows ask Allow once / Always in the card); Replace copies without it; "Always" is listed in Settings with Remove, after which the next action asks again | `screenRowsFollowComputerUse`, `consentIsAskedInTheCard`, `allowAlwaysGrants`, `replaceFollowsComputerUse`, `removingAlwaysAllowAsksAgain` |

---

## Summary (2026-09-24)

| | ✅ | 🟡 | ❌ | ❓ | — |
|---|---:|---:|---:|---:|---:|
| Rows (52) | 21 | 12 | 8 | 7 | 4 |

*2026-09-25: D10 🟡 → ✅ (#84); D13 ❌ → ✅.*
*2026-09-26: C4, C5, C6, C7, C9 ❌ → ✅ (task 5, #96) — the rules now live in `DockKeyRules`, which the Dock's monitor and the Corner's both read.*
*2026-09-26: B3, B4, C1, C3, C10, C11, C12, E4 → ✅; B2 → — (task 5 part 2, #98).*

**Checked on the app 2026-09-24** (build `6b9f7bb`, keys sent with System Events over TextEdit):
C2, F1 ✅; A4, B3, C1 🟡; C4–C7, C9 ❌; D4, F2, C11 fixed or advanced in #81. Still ❓, not tried: B2, B4, C12, D7, D13,
D14, E3, E4; also untried, left as they were: B7, C3, C10, D2, D5, D6, D10, E5 — rows that run
commands, need a selection, or need a live model.
**D4 was a safety bug** (→ on a system-command row ran it) — fixed in #81.

**What this says:** the Corner already matches the Dock on the *big* things — Global Context, CLI
scope, General Chat, clipboard, pins, feedback — and each is pinned by tests. The gaps are in the
**small keyboard rules** (Backspace, Esc, Tab, ↑/↓ in lists) and a few **scopes** (Notifications,
Quick Note editor, Mail, Selection actions). The 18 ❓ rows are the biggest risk: nobody has proved
them either way.

## Order of work (proposal)

1. **Verify the ❓ rows on the Mac** — one pass, no code: run the app, try each key in the Corner,
   mark ✅ / 🟡 / ❌. Half a day; it turns guesses into a real gap list.
2. **Task `corner-parity`** (already queued): Selection actions (D10) + swipes (F1, F2).
3. **Keyboard rules** B2–B4, C1–C12, E4 — extract the Dock's key handling into a shared, tested
   type so both shells read the same rules.
4. **Remaining scopes** D4–D7, D13–D14.
5. **Owner decisions:** D9 Notifications, D11 Quick Note editor, D12 Mail — move, or drop from v1?
6. When every row is ✅ / — : decide A1 (what ⌥⌥ opens) and retire the Dock paths.

## Paste this into your Mac (step 1)

```
Verify docs/master/00-DOCK-PARITY-INVENTORY.md on the real app. No code changes.
For every ❓ and 🟡 row: open the Corner, try the behaviour exactly as the Dock does it (run the Dock with ⌥⌥ side by side), and set the Corner column to ✅ / 🟡 / ❌. Put a one-line note of what you saw. If a ✅ row is wrong, correct it too.
Update the Summary counts. Commit only that file, push, add one line to MEMORY.md.
```
