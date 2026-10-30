# App Pets stage 1 — Pet identity and single-Dock scope switching

> **Issue:** #338. **Status:** planned; blocked on #327 / PR #337 merge.
> **Required skill:** `superpowers:test-driven-development` for implementation and
> `superpowers:verification-before-completion` before hand-off.

**Goal:** Make a running-app icon select that app's Pet inside the current Dock, preserving the
Pet's conversation and never foregrounding the underlying app unless the user chooses Open/Show.

**Architecture:** Add a small stable identity type over the existing `GeneralChatScope` app/CLI
keys. Carry the selected identity through the existing `SurfaceFocus`, `CornerChatPresentation`
and `AppChatPromptModel` path. `CornerDockStrip` delegates a running-app click to that scope path;
`DockAppClick` remains only for explicit app-opening actions. Conversation persistence continues
through `GeneralChatSessionStore` and `AppPanelChatStore`.

**Tech stack:** Swift 5, SwiftUI, AppKit, swift-testing.

**Spec:**
[`2026-10-27-app-pets-combined-chat-design.md`](../specs/2026-10-27-app-pets-combined-chat-design.md)
§§2–5 and issue #338.

**Global constraints:** One Corner shell; no second engine/store/registry; centre and corner must
behave identically; selected Pet state does not grant access; app activation is an explicit action;
preserve current pin and Safari-tab behavior; retain compatibility names while migrating.

**Review focus:** Associated-value focus exhaustiveness, exact click-vs-open separation, no
conversation reset on switching, keyboard navigation, running/pinned/tab regression risk and
main-actor ownership.

## Task 1: Define stable Pet identity and scope conversion

**Files:**

- Create: `Context-Dock/AI/AppPetIdentity.swift`
- Modify: `Context-Dock/AI/GeneralChatSessionStore.swift`
- Create: `Context-DockTests/AppPetIdentityTests.swift`

1. Write failing tests for:
   - app bundle IDs round-trip between `AppPetID` and `.app(bundleId:)`;
   - CLI commands normalize exactly as current `.cli(command:)` storage does;
   - `.general`, `.thread` and `.folder` are not Pets;
   - storage keys remain compatible with existing app and CLI conversations.
2. Run only `AppPetIdentityTests` and confirm failure because the type/conversions do not exist.
3. Add a value type with typed cases, for example `AppPetID.app(bundleID:)` and
   `AppPetID.cli(command:)`; expose `GeneralChatScope.petID` and `init(petID:)` without changing
   existing `storageKey` values.
4. Rerun the focused tests.
5. Commit only these files: `feat(app-pets): add stable Pet identity`.

## Task 2: Carry the selected Pet in surface focus

**Files:**

- Modify: `Context-Dock/UI/SurfaceFocus.swift`
- Modify: `Context-DockTests/SurfaceFocusTests.swift`
- Modify: `Context-Dock/UI/CornerChatPresentation.swift`
- Modify: `Context-DockTests/CornerChatPresentationTests.swift`

1. Replace the anonymous selected-app focus with an identity-bearing state such as
   `.pet(AppPetID)`. Do not put names, icons or mutable application state in the identifier.
2. First update tests to prove:
   - Command and `leaveApp` return every selected Pet to Global;
   - zoom-in returns to the real frontmost Pet, not the previously selected Pet;
   - changing selected Pet does not create a new `CornerChatPresentation` or General window;
   - per-scope drafts remain independent.
3. Add `CornerChatPresentation.showPet(target:)` as the semantic selection entry point. It should
   reuse `showFrontmostApp(target:)`/`AppChatPromptModel.summon` internals while recording that the
   scope was selected rather than inferred from the frontmost app.
4. Keep `showFrontmostApp` for normal launch and selection-answer paths; do not rename every
   compatibility symbol in this stage.
5. Update all exhaustive switches and rerun both focused suites.
6. Commit: `feat(app-pets): carry selected Pet through Dock focus`.

## Task 3: Separate Pet selection from app activation

**Files:**

- Modify: `Context-Dock/UI/CornerDockStrip.swift`
- Modify: `Context-Dock/UI/AppChatMenuBrowsing.swift`
- Modify: `Context-Dock/UI/AppChatPromptModel.swift` only if a public semantic wrapper is needed
- Modify: `Context-DockTests/CornerDockPhaseTests.swift`
- Modify: `Context-DockTests/CornerGlobalContextParityTests.swift`
- Add or modify the smallest strip interaction rule test file; keep AppKit calls behind a pure rule
  rather than attempting UI event synthesis in swift-testing.

1. Extract a pure click-intent rule for strip slots with distinct outcomes:
   `selectPet`, `openPin`, `openTab`, and explicit `openApplication`.
2. Write failing table tests before wiring the view:
   - running app in Global/Dock → `selectPet`;
   - running app while another Pet is active → `selectPet`;
   - Safari tab → `openTab`;
   - app action/pin retains its existing explicit behavior;
   - explicit Open from the icon menu → `openApplication`.
3. Change `CornerDockStrip.appIconBody` so a normal running-app click calls the current model's
   scope-selection path (`scopeIntoApp`/`showPet`) and never `DockAppClick.click`.
4. Keep `DockAppClick.click` behind explicit Open/Show and compatible app-pin actions. Update stale
   comments that call every icon click a switch to the real app.
5. Ensure selecting a Pet calls the existing session-boundary/load path for
   `dock_app_<bundleID>` and does not clear `AppChatConversation` before the new scope loads.
6. Rerun the focused phase/parity/strip tests.
7. Commit: `feat(app-pets): switch Dock scope on app icon click`.

## Task 4: Preserve Global navigation and explicit Open behavior

**Files:**

- Modify: `Context-Dock/UI/CornerDockWindow.swift`
- Modify: `Context-Dock/UI/CornerChatPresentation.swift`
- Modify: `Context-DockTests/SurfaceFocusTests.swift`
- Modify: `Context-DockTests/CornerChatPresentationTests.swift`
- Modify the existing icon-menu test file selected by `graphify query`; do not create a parallel
  menu model.

1. Add failing cases for selected Pet → Command → Global and empty Backspace → Global, including a
   non-empty draft case that must preserve text and remain scoped.
2. Update the command-tap bridge to pass the selected `AppPetID` instead of reconstructing a bare
   `.app` marker.
3. Confirm Global → Command still resolves the app that owns the menu bar now.
4. Add an explicit **Open App** menu action if the current menu lacks one; it is the path that may
   call `DockAppClick`/`NSWorkspace` and foreground the app.
5. Rerun focused navigation and menu tests.
6. Commit: `fix(app-pets): preserve Global navigation and explicit app opening`.

## Task 5: Migration and regression coverage

**Files:**

- Modify: `Context-DockTests/AppPanelChatStoreTests.swift` if present; otherwise create it
- Modify: the nearest existing `GeneralChatSessionStore` test file found by graphify; if none
  exists, create `Context-DockTests/GeneralChatSessionStoreTests.swift`
- Modify: `Context-DockTests/CornerSafariTabsTests.swift`
- Modify: `Context-DockTests/DockStripCompositionTests.swift` only if composition changed

1. Prove existing `dock_app_<bundleID>` history appears after Pet selection and survives
   Pet A → Pet B → Pet A.
2. Prove a selected generic Pet with no rich adapter still scopes honestly and exposes only its
   registered capabilities.
3. Prove Safari tabs remain tabs and do not become Safari Pet selections.
4. Prove pinned-but-not-running behavior remains explicit launch behavior; stage 1 does not make a
   closed app look headless-capable.
5. Run the focused suites, then `./scripts/check.sh`.
6. Run `graphify update .` and inspect the changed relationships.
7. Commit: `test(app-pets): cover Pet switching persistence and regressions`.

## Task 6: Mac visual and behavior verification

No code is complete until this Mac-only gate passes.

1. Launch the exact pushed SHA with the standard test-worktree block and `./scripts/dev-run.sh`.
2. Capture reference and changed screenshots for both:
   - bottom-corner Global Context → Finder Pet → Safari Pet;
   - centred `⌥⌥` Global Context → Finder Pet → Safari Pet.
3. By hand verify:
   - clicking Safari changes the composer to **Ask Safari** but Safari does not come forward;
   - Finder → Safari → Finder restores Finder's conversation/draft;
   - Command and empty Backspace return to Global;
   - typed Backspace edits text instead of leaving the Pet;
   - **Open Safari** explicitly foregrounds Safari;
   - Safari tab, pinned app and right-click menu behavior did not regress.
4. Add screenshots and any intentional differences to the PR description. Fix unexplained shell
   size, padding, alignment, clipping or animation differences before asking the owner to test.

## Stop condition

Stage 1 ends after #338 is owner-checked and merged. Do not fold participant consent (#339), memory,
`/mods`, detachment or proactivity into this PR. The next implementation plan is written against
the merged Stage 1 types, not guessed in advance.
