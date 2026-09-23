# LauncherView.body Decomposition Implementation Plan

> **DONE — 2026-09-22.** Release builds at `6484913` with no build-setting override: zero
> aborts, a signed app, suite 1851 / 0. Full account on issue **#25**.
>
> **Read this before reusing the plan below, because its task order was wrong.** Three things
> it got wrong, all found by executing it:
>
> 1. **Target reachable leaves, not big members.** Only view members `body` can transitively
>    reach contribute to its opaque type. 309 lines of genuine leaf that `body` cannot reach
>    moved the count by **8**; 341 reachable lines moved it by **768**. `scripts/view-leaves.py`
>    computes the closure and ranks by it — use its output, not a size ranking.
> 2. **A leaf is a member that calls no other view member.** A view taking opaque children as
>    `@ViewBuilder` parameters becomes generic over their types and substitution recurses back
>    in. Tasks 3-8 below name `appPanelView`, `searchBarWithPinnedApps` and friends, all of
>    which compose other members and would have bought nothing.
> 3. **Count view *functions*, not just properties**, and read wrapped signatures to the brace.
>    `appPillButton` declares `-> some View` fourteen lines below its name.
>
> What actually worked: eight extractions and one `@ViewBuilder` split took 3,811 opaque types
> to under the threshold. Tasks 0, 1, 9 and 10 ran as written; 2-8 were replaced by leaf
> extraction. 44 reachable leaves (~1,500 lines) remain and are optional — the build passes —
> but each still shrinks the type.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `xcodebuild -configuration Release` complete, by reducing `LauncherView.body`'s opaque type until SILGen can finish substituting it.

**Architecture:** The compiler aborts because `body`'s `some View` type expands into a single type holding the launcher's entire UI. A computed property returning `some View` is *not* a boundary — only a nominal type is. Every task therefore converts inlined content into `struct … : View` or `ViewModifier`, and measures the result against the compiler's own dump. Nothing else counts as progress.

**Tech Stack:** Swift 5 language mode, SwiftUI, macOS 26.1 deployment target, swift-testing, Xcode-beta toolchain (Swift 6.4).

**Spec:** Issue **#25** and its 2026-09-22 comments carry the measurements this plan argues from. Decision `5077f556` is unrelated background. The owner chose decomposition over the `SWIFT_COMPILATION_MODE = incremental` workaround on 2026-09-22, accepting that `ship.sh` stays broken until this lands.

**Tooling this plan adds:** `scripts/state-surface.sh <property> <file>` prints exactly the inputs a view property needs before it can become a type of its own — every extraction task starts by running it. `scripts/release-type-size.sh` builds Release and reports the size of `body`'s opaque type — every task ends by running it.

## Global Constraints

- **No `AnyView`.** Erasure would terminate substitution instantly and defeat SwiftUI's structural identity diffing on a view that re-renders per keystroke and drives the corner's 0.9 s morph. If a task cannot be done without `AnyView`, stop and report rather than using it.
- **No behaviour change.** Same views, same order, same modifiers, same animations. This is a type-level refactor.
- **Modifier order is load-bearing.** Several key handlers return `.ignored` so a later one takes the press; several `.onReceive` handlers race. Preserve order exactly.
- **One slice per commit.** The tree is edited by other sessions concurrently.
- **Never `git add -A`.** Stage explicit paths. Run `git log --oneline -3` and `git status` before starting each task and again before reporting.
- **Quit the app before `./scripts/test.sh`** — it refuses while the app runs. `osascript -e 'tell application id "com.krishgokul.ContextDock" to quit'`. `dev-stop.sh` does not exist.
- **Never run two `xcodebuild`s at once**, including against a worktree — it produces `build.db … database is locked`, `passedTests: 0`, and `Test crashed with signal kill`. Check `pgrep -fl xcodebuild` first.
- **Baseline to hold:** suite **1851 / 0**. Confirm tests ran by their `@Suite` display name, not the type name.

---

## Task 0: The measurement, and why it is the only progress signal

No task in this plan may be called done on "it builds in Debug" — Debug has always built. The signal is the size of the type the compiler prints while aborting.

**Files:** none. This task produces a number and a habit.

**Interfaces:**
- Produces: `opaque_type` count for the current HEAD, recorded on #25 as the running baseline.

- [ ] **Step 1: Measure**

```bash
cd /Users/gokulakannan/Developer/Context-Dock
./scripts/release-type-size.sh
```

It refuses if another `xcodebuild` is running, builds Release (~12 minutes), and prints the commit, the opaque-type count, the `ModifiedContent` count and the first few decls of the type — which name the current worst offender. That last list is how the previous two rounds were targeted, and it worked: after the subscriptions were collapsed the top changed from `SubscriptionView<Published.Publisher<…>>` to nested `onKeyPress`, and after those were collapsed `onKeyPress` appears **zero** times.

To re-measure a log you already have, pass its path.

- [ ] **Step 2: Compare against the baseline**

Baseline at `eea4c7f`: **3,811 opaque types**, 24,713 `ModifiedContent`, 142,793 dump lines.

**Do not hand-roll this count.** The compiler emits the substituted type twice — once plainly and once prefixed with `| ` inside the stack dump — while `Please submit a bug` appears only at the very end. A range between those two markers spans both copies and reports exactly double, which reads as a catastrophic regression and is not. That mistake was made on this plan's own first run; the script reads the first copy only.

- [ ] **Step 3: If it says BUILD SUCCEEDED**

Then this plan is finished early. Stop and verify with Task 9 rather than continuing to extract.

- [ ] **Step 4: Record the number**

Add a one-line comment to #25 with the commit and the count. A task that does not lower this number was the wrong task, and is reverted rather than kept.

---

## Task 1: Delete two dead view properties

Free reduction before any real work: two large properties on the body path have no references at all. Same class of finding as the L2 island deleted in `5f2f487`.

**Files:**
- Modify: `Context-Dock/Search/LauncherView+ContextActionsUI.swift` (`contextChipSection`, 141 lines)
- Modify: `Context-Dock/Search/LauncherView+DockAppActions.swift` (`globalRunningAppStrip`, 130 lines)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing. Two symbols cease to exist.

- [ ] **Step 1: Re-verify both are unreferenced, because HEAD moves**

```bash
cd /Users/gokulakannan/Developer/Context-Dock
for v in contextChipSection globalRunningAppStrip; do
  echo "$v: $(grep -rn "\b$v\b" --include='*.swift' Context-Dock/ | grep -v "var $v" | wc -l) refs"
done
```

Expected: `0 refs` each. **If either is non-zero, skip it and say so** — another session may have wired it up since this plan was written.

- [ ] **Step 2: Check for the trap that hid the L2 island**

```bash
grep -rn "contextChipSection\|globalRunningAppStrip" --include='*.swift' Context-Dock/ | grep -v "LauncherView+ContextActionsUI.swift\|LauncherView+DockAppActions.swift"
```

Expected: no output. Two dead things referencing *each other* is what made the L2 island survive a file-by-file look.

- [ ] **Step 3: Delete both properties**

Remove each `var … : some View { … }` in full, including its `@ViewBuilder` attribute and its doc comment.

- [ ] **Step 4: Build**

```bash
./scripts/build-debug.sh 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```

Expected: `** BUILD SUCCEEDED **`. A compile error here means the property was reachable after all — revert and report.

- [ ] **Step 5: Test**

```bash
osascript -e 'tell application id "com.krishgokul.ContextDock" to quit' 2>/dev/null
./scripts/test.sh 2>&1 | tail -6
```

Expected: `1851 / 0`, unchanged. An unchanged suite is the evidence nothing depended on the deleted code.

- [ ] **Step 6: Commit**

```bash
git add Context-Dock/Search/LauncherView+ContextActionsUI.swift Context-Dock/Search/LauncherView+DockAppActions.swift
git commit -m "refactor(launcher): delete two view properties nothing references"
```

- [ ] **Step 7: Re-measure** — run `./scripts/release-type-size.sh`.

---

## Task 2: Collapse the content chain's modifiers into ViewModifiers

Seven computed properties in `LauncherView+ContextLifecycle.swift` form a linear chain, each adding modifiers to the one below. 71 modifiers across the chain, each one a layer on `body`'s type. The technique is already proven twice in this codebase — read `LauncherApprovalSubscriptions.swift` and `LauncherKeyHandlers.swift` before starting; they are the worked examples and their headers explain the mechanism.

**Files:**
- Create: `Context-Dock/Search/LauncherLifecycleHandlers.swift`
- Modify: `Context-Dock/Search/LauncherView+ContextLifecycle.swift:45-1181`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `contentWithModifiers` remains the chain's base and keeps its name; the six links above it are replaced by modifiers applied to it.

Chain as it stands, with line ranges and modifier counts:

| property | lines | modifiers |
|---|---|---|
| `contentWithModifiers` | 45-401 | 24 |
| `contentLifecycleView` | 403-470 | 2 |
| `contentSettingsHandlersView` | 472-562 | 8 |
| `contentCoreLifecycleHandlersView` | 564-647 | 8 |
| `contentLifecycleHandlersView` | 649-693 | 6 |
| `contentNotificationHandlersViewA` | 695-1058 | 8 |
| `contentNotificationHandlersView` | 1060-1181 | 15 |

- [ ] **Step 1: Read the two worked examples**

`Context-Dock/Search/LauncherApprovalSubscriptions.swift` and `Context-Dock/Search/LauncherKeyHandlers.swift`. Note how handlers stay as closures at the call site — that is what preserves access to the view's state — and how the modifier itself holds no state and decides nothing.

- [ ] **Step 2: Group the chain into modifiers by kind, not by current property**

Three modifiers, because these are three genuinely different things and a reader should be able to find one:
- `LauncherLifecycleHandlers` — `onAppear`/`onDisappear`/`onChange` of settings and scope (from `contentLifecycleView`, `contentSettingsHandlersView`, `contentLifecycleHandlersView`).
- `LauncherNotificationHandlers` — every `NotificationCenter.default.publisher(for:)` subscription (from `contentCoreLifecycleHandlersView`, `contentNotificationHandlersViewA`, `contentNotificationHandlersView`).
- `contentWithModifiers`'s own 24 layout modifiers stay where they are for now; they are layout, not handlers, and Task 3 moves that content wholesale.

Each takes one closure per handler, named for what it handles, and applies them in the existing order inside its own `body`.

- [ ] **Step 3: Do one group at a time and build between them**

Do not rewrite all three in one edit. Three separate passes, `./scripts/build-debug.sh` after each. Two mechanical traps, both hit while writing this plan's predecessors:
- an argument list can contain its own parentheses (`.onKeyPress(keys: [.init("y")], phases: .down)`), so a pattern anchored on the first `)` misses it;
- a comment can sit *between* a modifier's closing brace and the next call, so a block does not end where the chunk does.

- [ ] **Step 4: Build**

```bash
./scripts/build-debug.sh 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```

- [ ] **Step 5: Test**

```bash
osascript -e 'tell application id "com.krishgokul.ContextDock" to quit' 2>/dev/null
./scripts/test.sh 2>&1 | tail -6
```

Expected: `1851 / 0`.

- [ ] **Step 6: Commit and re-measure**

```bash
git add Context-Dock/Search/LauncherLifecycleHandlers.swift Context-Dock/Search/LauncherView+ContextLifecycle.swift
git commit -m "refactor(launcher): the content chain's handlers are modifiers"
```

Then re-measure with `./scripts/release-type-size.sh`. **Expected reduction is modest** — the previous round removed 17 layers against 3,811 and moved the number very little. If the count drops by roughly the number of modifiers collapsed and no more, that is the correct result, and it confirms the content, not the chain, is the problem. Record it and continue to Task 3, which is where the size actually is.

---

## Task 3: Extract `appPanelView` into a nominal view

The first real content extraction, and deliberately the easiest: 264 lines that touch **three** pieces of state. Proving the pattern here makes the rest mechanical.

**Files:**
- Create: `Context-Dock/Search/AppLivePanel.swift`
- Modify: `Context-Dock/Search/LauncherView+LivePanel.swift` (remove the property, call the new view)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `struct AppLivePanel: View` with `@Binding var livePanelVisible: Bool`, `var searchState: SearchState`, and a `FocusState<Bool>.Binding` for the search field. Exact signature is derived in Step 2, not guessed here.

- [ ] **Step 1: Derive the inputs rather than assuming them**

```bash
cd /Users/gokulakannan/Developer/Context-Dock
./scripts/state-surface.sh appPanelView Context-Dock/Search/LauncherView+LivePanel.swift
```

It prints two lists: the stored properties the body reads, which become bindings or values, and the `LauncherView` methods it calls, which become closure parameters. At the time of writing:

```
-- stored properties it reads --
isSearchFieldFocused
livePanelVisible
searchState

-- LauncherView methods it calls --
appCLIConsentTool
checkRemInstalled
clearSearchContext
panelWelcomeView
reloadAppPanelData
remChatBubble
```

**Re-run it rather than trusting that list** — the property may have grown since. Note what the script caught that a hand-written grep for state alone had missed: six method calls. Two of them (`panelWelcomeView`, `remChatBubble`) return views, so decide per call whether the new type takes them as `@ViewBuilder` closures or whether those small views move with it.

Methods that mutate `LauncherView` state stay on `LauncherView` and are passed in as closures. Do not move method bodies in this task.

- [ ] **Step 3: Create the view**

A `struct` in its own file, with one `@Binding`/value/closure per name the two commands printed, and the property's body moved in verbatim. The file header says why the type exists — pointing at #25 — in the style of `LauncherApprovalSubscriptions.swift`.

Deliberately no reference code here. This codebase has been bitten by it: the Plugins Phase 1 plan carried reference code detailed enough to transcribe, four of six tasks needed a fix round, and nearly every defect was in the plan's own code rather than the implementer's work. Derive the signature from Steps 1-2 and the real property; do not transcribe a guess.

- [ ] **Step 4: Call it from where the property was**

Replace the property body with a call passing the derived inputs. Keep the property name so call sites do not change, or update both call sites (`LauncherView.swift:3636`, `LauncherView+SearchBar.swift:3055`) — check which is smaller when you get there.

- [ ] **Step 5: Build**

```bash
./scripts/build-debug.sh 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```

- [ ] **Step 6: Test**

```bash
osascript -e 'tell application id "com.krishgokul.ContextDock" to quit' 2>/dev/null
./scripts/test.sh 2>&1 | tail -6
```

Expected: `1851 / 0`.

- [ ] **Step 7: Hand the layout check to the owner**

Relaunch with `./scripts/dev-run.sh` and ask the owner to open the live panel and confirm it looks and behaves as before. **An agent cannot verify this**: synthetic input does not exercise a real SwiftUI layout, and this repo has a memory saying so. State plainly that the check is outstanding rather than implying it passed.

- [ ] **Step 8: Commit and re-measure**

```bash
git add Context-Dock/Search/AppLivePanel.swift Context-Dock/Search/LauncherView+LivePanel.swift
git commit -m "refactor(launcher): the live app panel is a view of its own"
```

Then re-measure with `./scripts/release-type-size.sh`. **This is the task that tells you whether the plan works.** A 264-line subtree leaving `body`'s type should move the opaque count visibly. If it moves by single digits, stop and report before doing Tasks 4-8 — the model of the problem is wrong and grinding through seven more extractions will not fix it.

---

## Task 4: Extract `l2ChatSection`

250 lines. Three call sites, one of them outside `LauncherView` (`ContextDockChatSurface.swift:51`), which makes it the first extraction that improves more than one surface.

**Files:**
- Create: `Context-Dock/Search/L2ChatSection.swift`
- Modify: `Context-Dock/Search/LauncherView+AIChat.swift`, `Context-Dock/Search/LauncherView+SearchBar.swift:416`, `Context-Dock/Search/ContextDockChatSurface.swift:51`

**Interfaces:**
- Consumes: the pattern established in Task 3.
- Produces: `struct L2ChatSection: View`, signature derived as in Task 3.

- [ ] **Step 1: Derive the inputs**

```bash
./scripts/state-surface.sh l2ChatSection Context-Dock/Search/LauncherView+AIChat.swift
```

Stored properties become bindings or values; `LauncherView` methods become closure parameters. Method bodies stay on `LauncherView`.
- [ ] **Step 2: Create the view** — as Task 3 Step 3.
- [ ] **Step 3: Update all three call sites.**
- [ ] **Step 4: Build** — `./scripts/build-debug.sh`.
- [ ] **Step 5: Test** — expect `1851 / 0`.
- [ ] **Step 6: Owner checks the L2 chat in both the dock and the Context Dock surface.** Outstanding until they say so.
- [ ] **Step 7: Commit, then Task 0 steps 2-5.**

---

## Task 5: Extract `aiModeControls`

189 lines, one call site (`LauncherView+SearchBar.swift:2651`).

**Files:**
- Create: `Context-Dock/Search/AIModeControls.swift`
- Modify: `Context-Dock/Search/LauncherView+ContextActionsUI.swift`, `Context-Dock/Search/LauncherView+SearchBar.swift:2651`

- [ ] **Step 1: Derive the inputs**

```bash
./scripts/state-surface.sh aiModeControls Context-Dock/Search/LauncherView+ContextActionsUI.swift
```

- [ ] **Step 2: Create the view.** Stored properties become bindings or values; methods become closure parameters, bodies staying on `LauncherView`.
- [ ] **Step 3: Update the call site.**
- [ ] **Step 4: Build.**
- [ ] **Step 5: Test** — expect `1851 / 0`.
- [ ] **Step 6: Owner checks AI mode controls.**
- [ ] **Step 7: Commit, then Task 0 steps 2-5.**

---

## Task 6: Extract `aiChatSection`

133 lines, two call sites in `LauncherView+SearchBar.swift` (508, 513).

**Files:**
- Create: `Context-Dock/Search/AIChatSection.swift`
- Modify: `Context-Dock/Search/LauncherView+AIChat.swift`, `Context-Dock/Search/LauncherView+SearchBar.swift`

- [ ] **Step 1: Derive the inputs**

```bash
./scripts/state-surface.sh aiChatSection Context-Dock/Search/LauncherView+AIChat.swift
```

- [ ] **Step 2: Create the view.** Stored properties become bindings or values; methods become closure parameters, bodies staying on `LauncherView`.
- [ ] **Step 3: Update both call sites.**
- [ ] **Step 4: Build.**
- [ ] **Step 5: Test** — expect `1851 / 0`.
- [ ] **Step 6: Owner checks the AI chat section.**
- [ ] **Step 7: Commit, then Task 0 steps 2-5.**

---

## Task 7: Extract `searchBarWithPinnedApps`

The root of the content and the largest remaining subtree — everything the dock draws hangs off it. Left until now on purpose: extracting a child first shrinks every ancestor's type, so by this point most of the weight is already gone and this becomes a small wrapper rather than a 2,000-line move.

**Files:**
- Create: `Context-Dock/Search/SearchBarSection.swift`
- Modify: `Context-Dock/Search/LauncherView+DockBase.swift:149,226`

- [ ] **Step 1: Re-measure first.** If the Release build already succeeds by this point, skip to Task 9. That is a real possibility and skipping is the correct response, not a missed opportunity.
- [ ] **Step 2: Derive the inputs** with `./scripts/state-surface.sh searchBarWithPinnedApps Context-Dock/Search/LauncherView+DockBase.swift`. Expect a much larger surface than the earlier tasks; if it exceeds roughly a dozen inputs, group the related ones into a small `struct` passed as one value rather than passing a dozen bindings.
- [ ] **Step 3: Create the view.**
- [ ] **Step 4: Update `mainContent`.**
- [ ] **Step 5: Build.**
- [ ] **Step 6: Test** — expect `1851 / 0`.
- [ ] **Step 7: Owner checks the whole dock — search, results, pinned apps, the corner morph.** This one touches everything; it is the most important hand check in the plan.
- [ ] **Step 8: Commit, then Task 0 steps 2-5.**

---

## Task 8: Extract `aiExtensionQuickActions`

The last of `mainContent`'s four children that is not `EmptyView()`.

**Files:**
- Create: `Context-Dock/Search/AIExtensionQuickActions.swift`
- Modify: `Context-Dock/Search/LauncherView+ContextActionsUI.swift:18`, `Context-Dock/Search/LauncherView+DockBase.swift:148`

- [ ] **Step 1: Re-measure. Skip to Task 9 if Release already builds.**
- [ ] **Step 2: Derive the inputs** with `./scripts/state-surface.sh aiExtensionQuickActions Context-Dock/Search/LauncherView+ContextActionsUI.swift`.
- [ ] **Step 3: Create the view.** Stored properties become bindings or values; methods become closure parameters, bodies staying on `LauncherView`.
- [ ] **Step 4: Update the call site.**
- [ ] **Step 5: Build.**
- [ ] **Step 6: Test** — expect `1851 / 0`.
- [ ] **Step 7: Owner checks the quick actions row.**
- [ ] **Step 8: Commit, then Task 0 steps 2-5.**

---

## Task 9: Prove the Release build, end to end

**Files:** none, unless a defect is found.

- [ ] **Step 1: Clean Release build from nothing**

```bash
cd /Users/gokulakannan/Developer/Context-Dock
pgrep -fl xcodebuild || echo clear
rm -rf .build/XcodeReleaseDerivedData
xcodebuild -project Context-Dock.xcodeproj -scheme Context-Dock \
  -configuration Release -derivedDataPath .build/XcodeReleaseDerivedData \
  -jobs 1 build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`, with **no** `SWIFT_COMPILATION_MODE` override. `rm -rf` matters: a crashed earlier run leaves a stale `Contents/MacOS/__preview.dylib` that fails the *next* build at `CodeSign` with "code object is not signed at all", which reads as a signing problem and is not.

- [ ] **Step 2: Confirm the product exists and is signed**

```bash
APP=.build/XcodeReleaseDerivedData/Build/Products/Release/Context-Dock.app
ls -la "$APP/Contents/MacOS/"
codesign -dv "$APP" 2>&1 | head -3
```

- [ ] **Step 3: Full suite one more time** — expect `1851 / 0`.

- [ ] **Step 4: Owner runs the Release build by hand.** Every hand check deferred in Tasks 3-8 is still owed; list the ones still outstanding rather than assuming the Debug checks covered them.

- [ ] **Step 5: Close #25** with the final opaque count, the commits, and the fact that `SWIFT_COMPILATION_MODE` was never changed.

- [ ] **Step 6: Record the decision** — `add_decision` covering what actually reduced the type and by how much, so the next person adding 200 lines to `body` knows the ceiling exists and where it is.

---

## Task 10: Correct CLAUDE.md

Found while writing this plan; wrong in ways that would mislead the next session.

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Fix the state claim.** CLAUDE.md says `Search/ContentView.swift` declares `LauncherView` with "420+ `@State` vars". `ContentView.swift` is **14 lines** and contains no `@State` at all. The state is in `Search/LauncherView.swift`: 74 `@State`, plus `@StateObject` 9, `@ObservedObject` 14, `@Environment` 4, `@EnvironmentObject` 2, `@AppStorage` 1, `@FocusState` 1 — **105 stored properties**, in a 3,899-line file.
- [ ] **Step 2: Fix the "Large Files" section**, which tells readers to `awk` ranges out of `ContentView.swift`.
- [ ] **Step 3: Fix the skills table.** It lists `view-refactor` for "Refactor large views (LauncherView, ContentView)", but no such skill is installed — `.claude/skills/` has no `view-refactor`. Either remove the row or install the skill.
- [ ] **Step 4: Commit.**

```bash
git add CLAUDE.md
git commit -m "docs: CLAUDE.md named the wrong file for LauncherView's state"
```

---

## Stop conditions

Report rather than continue if any of these happen:

1. **Task 3 barely moves the number.** The model of the problem is wrong; seven more extractions will not save it. Re-open the `SWIFT_COMPILATION_MODE = incremental` decision with the owner, armed with the new measurement.
2. **A task needs `AnyView` to work.** Stop; that trade is the owner's, not the implementer's.
3. **The suite moves off `1851 / 0`.** A view extraction should change no behaviour; a failing test means something real broke.
4. **`git status` shows changes you did not make.** Another session is in the file. Leave them alone, say so, and coordinate before continuing.
