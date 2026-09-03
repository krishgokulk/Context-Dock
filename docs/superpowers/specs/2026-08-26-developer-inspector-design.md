# Developer Inspector — design

**Date:** 2026-08-26
**Status:** approved, pending implementation plan

## The problem

Fixing a UI defect in DoraX currently costs a ritual: run the app, reproduce the state,
screenshot it, guess which file renders it, attach the screenshot to a Claude Code or Codex
session, describe what is wrong, wait, rebuild, reproduce again. The screenshot is the only
evidence that survives the handoff, and a screenshot carries none of what the agent actually
needs — which component this is, what the app believed at that moment, or where the code lives.

The guess is the expensive part, and it is expensive for a structural reason. The surface
files are containers, not renderers: `GeneralChatSurface.swift` is 54 lines,
`ContextDockSurface.swift` 66, `GlobalContextSurface.swift` 70. The rendering lives in the
`LauncherView+*.swift` extensions and in `AIMessageViews.swift`, which is 3037 lines and shared
by both chat surfaces. Pointing at a pixel and asking "which file is this" has no single answer.

## What this is not

This is developer infrastructure that **observes** the existing surfaces. It is not a new
DoraX mode, not a product layer, and not something a user is meant to understand. The
architecture rule that each surface keeps one job is unaffected: the inspector adds no
behaviour to any surface, only a metadata-emitting modifier at feature boundaries.

## Scope of the pixel→source claim

The system does **not** promise pixel → exact source file, and no achievable design can.
`#fileID` on a `shared.*` component names `AIMessageViews.swift` and not which of its ~40
view structs. The packet therefore carries a ranked `sourceCandidates` set — declaring
file and line, enclosing type, the ViewModel that fed it, the surface container — and the
agent narrows from there. The packet's value comes from runtime state and measured bounds,
not from the filename.

## Module layout

New folder `Context-Dock/Developer/`. Most of it compiles only under `#if DEBUG`; the
vocabulary ships because it feeds `accessibilityIdentifier`.

```
Developer/
  InspectID.swift              vocabulary (ships)
  InspectRegistry.swift        window + ID + instanceToken → frame/source
  InspectModifier.swift        .doraxInspect(_:) — the one-line call site
  InspectorOverlay.swift       DEBUG: hover highlight, ⌥-click lock, detail panel
  UIBugPacket.swift            packet model + markdown renderer
  UIBugCaptureService.swift    screenshot + state + registry snapshot
  DoraXDevChannel.swift        DEBUG: authenticated local IPC
  ScenarioRunner.swift         DEBUG: named scenarios, baseline compare
  RepairSession.swift          disk-backed loop state, survives relaunch
```

## 1. Vocabulary

`InspectID` is a `String`-backed struct with static members, not free-form strings: typos
become compile errors, and the full set is enumerable so scenarios can be validated against it.

Phase 1 covers both chat surfaces, roughly 25 IDs:

```
generalChat.thread .message .message.assistant .message.user
generalChat.toolCard .toolTimeline .input .attachments
generalChat.providerPicker .sidebar .send
contextDockChat.thread .input .header .actionRow
shared.messageBubble .markdownBody .codeBlock .streamingCursor
```

`shared.*` is placed in `AIMessageViews.swift` and covers both surfaces from one placement.

Instrumentation stops at feature boundaries. No IDs on `Text`, `HStack`, `Spacer`, `Divider`,
or icons — the agent searches downward from a region; it does not need a DOM.

## 2. The modifier

```swift
extension View {
    func doraxInspect(_ id: InspectID,
                      file: String = #fileID,
                      line: Int = #line,
                      type: String = #function) -> some View
}
```

The call site writes `.doraxInspect(.generalChat.toolCard)` and nothing else. Source location
arrives through default arguments, so it cannot drift from the code it describes — the failure
mode of any hand-maintained file-name table.

Three effects:

- `accessibilityIdentifier(id.rawValue)` — always compiled, ships. This is what lets the
  scenario runner's AX entry step find the window, and it is free.
- geometry reporting into `InspectRegistry` — `#if DEBUG`.
- lifetime deregistration — `#if DEBUG`.

## 3. Registry identity and coordinates

### Identity is per instance, never per ID

`generalChat.message` exists once per message on screen. A key of `(window, InspectID)` holds
one entry and silently loses the rest, and — worse — `onDisappear` on any one message would
remove the entry belonging to a different, still-visible message.

The key is therefore:

```
RegistryKey = (windowID, InspectID, instanceToken)
```

`instanceToken` is a UUID created once per modifier instance and held for that instance's
lifetime (a `@State` value, so SwiftUI's own view identity governs it). The registry API is
`upsert(window:id:instance:metadata:)` and `remove(window:id:instance:)`.

Ordinals (`generalChat.message #0`, `#1`, `#2`) are **derived at read time for presentation
and for scenario addressing**. They are never identity. Sorting for ordinal assignment is by
frame origin within the window, so `#0` means the topmost message rather than whichever
instance happened to register first.

Window close purges every entry for that window, unconditionally — a window can be destroyed
without its subviews' `onDisappear` running in any guaranteed order.

### Coordinates are explicit

SwiftUI's `.global` coordinate space is the hosting view's coordinate space, not macOS screen
coordinates, and DoraX has around ten `NSPanel`s. Treating the two as interchangeable produces
hit testing that looks random and is nearly impossible to debug from the symptom.

This confusion is already live in the tree: `LauncherView+ContextLifecycle.swift:59` takes
`proxy.frame(in: .global)` and assigns it directly to an `NSWindow` property.

The registry therefore stores `(windowID, frame in that window's root coordinate space)` and
converts explicitly at match time:

```
screen point → window.convertPoint(fromScreen:) → root space → compare
```

Conversion is a single named function with its own tests, so a coordinate bug surfaces as a
failing unit test rather than as a mis-highlighted region.

### Hit testing

Smallest-area entry containing the converted point, within the window under the pointer. Ties
break by registration depth. Uninstrumented regions resolve to the nearest ancestor that is
instrumented, and the panel says so rather than pretending precision it does not have.

## 4. Inspector overlay

`⌥⌘I` toggles Developer Inspect Mode. While off, the subsystem costs nothing and
`acceptsMouseMovedEvents` is untouched — the pre-release audit's finding about always-on
mouse-moved delivery stands, and this feature must not quietly undo it.

While on: hover draws a highlight and the ID label. `⌥`-click locks the component and opens a
panel with the ID and derived ordinal, `#fileID:#line`, enclosing type, ranked
`sourceCandidates`, live bounds, and the owning ViewModel's state. A `[Capture Bug]` button
ends the interaction.

Hover is preview only. Everything expensive — screenshot, state serialisation, packet
assembly — happens on the click, never on pointer movement.

## 5. Bug packet

`UIBugPacket` is a second capture kind alongside the existing `DoraXDiagnosticReport`, shown
in the same `DiagnosticsPanel`. That panel already exists to package evidence for the one
process that can change the code; this extends it from semantic failures (a bad agent answer)
to visual ones.

Contents: cropped and full-window screenshot; InspectID and derived ordinal; ranked
`sourceCandidates`; measured bounds against the expectation the user states; the owning
ViewModel's state; the last 10 seconds of log; a one-line note from the user; and build,
branch, and commit.

The log slice is partial by construction and must be labelled as such in the packet. 26 files
use `OSLog`; 463 `print(` call sites do not, and nothing outside `OSLog` can be read back after
the fact. The packet collects what `OSLogStore` can return for this process and states the
window it covers, rather than implying a complete trace. Converting the remaining `print` sites
is separate work and not a prerequisite — the packet's primary evidence is state and bounds.

**Deliberately excluded: git blame / recent-commit evidence.** Two to four agent sessions edit
this tree concurrently, so commit recency on a file records that someone else touched it, not
that it caused the defect. It is noise wearing the costume of evidence, and an agent will act
on it.

The field is named `sourceCandidates`, not `relatedFiles`, so the ranking's uncertainty is
visible at every call site.

## 6. Repair session and rebuild survival

The packet renders to markdown and goes to `ClaudeCodeCLIService` with the repository root as
working folder.

DoraX cannot rebuild itself while running. The build step runs `scripts/dev-run.sh` detached,
and that script kills and replaces the running app **mid-loop**. Loop state therefore lives on
disk and the relaunched app resumes from it; without this the loop dies silently at the first
rebuild.

All developer state is rooted at `$DORAX_SUPPORT_ROOT`, which defaults to
`~/Library/Application Support/Context-Dock` and is overridden for test instances (§7). Repair
sessions belong to the developer's working instance, never to a scenario instance.

```
$DORAX_SUPPORT_ROOT/dev/repairs/<id>/
  request.json      packet metadata, target ID, stated expectation
  packet.md         what was sent
  state.json        phase, attempt count, authority grant
  attempts/001/ 002/ …
  artifacts/        screenshots, captured state, scenario output
```

Lifecycle: capture → CLI edits → `dev-run.sh` replaces DoraX → new instance reads the session →
resumes verification.

### Authority is the harness's, not the model's

Tool level `full` is a developer setting for ad-hoc CLI use. It is **not** the repair loop's
default. `RepairSession` carries an explicit authority grant, project-scoped:

| Granted | Withheld |
|---|---|
| read repo | `git push` |
| edit repo | destructive `git reset` / history rewrite |
| `git diff` / `status` | writes outside the repository root |
| build | release, signing, notarization |
| launch test instance | arbitrary external system change |
| run an approved scenario | |

This is the same split DoraX already applies to its agent: the model reasons, the harness owns
authority. A repair loop that can push is a repair loop that can push a wrong fix unattended.

## 7. Developer control channel

### Not the URL scheme

`ilauncher://` is registered in `Info.plist` and any process on the machine can open it. Using
it as the drive channel would make `submit`, `run scenario`, `invoke repair`, and `capture
state` callable by anything, with no caller identity — a local automation API created by
accident.

The URL scheme keeps at most one thin bootstrap verb, `ilauncher://dev/activate-inspector`,
which does nothing but toggle a DEBUG-only UI mode.

### Authenticated local IPC

The real channel is a Unix domain socket, `#if DEBUG` only, refusing to open unless developer
mode is enabled:

```
$DORAX_SUPPORT_ROOT/dev/
  command.sock
  session-token      random per launch, 0600
```

Every request carries protocol version, session token, command, target InspectID, and
arguments. The channel rejects on: non-DEBUG build, developer mode disabled, invalid or
expired token, wrong instance identity, unknown command, malformed payload. Each rejection is
a tested case.

Verbs — `open`, `type`, `submit`, `wait`, `capture` — address components by InspectID and call
the same methods the UI calls. **No synthetic mouse or keyboard events anywhere.** Synthetic
input into the user's session is prohibited outright, and warped-pointer verification has
already been shown here to prove nothing.

### Instance isolation asserts, it does not infer

The scenario runner launches its own instance and refuses to attach to any process that has
not positively identified itself as a test instance:

```
DORAX_TEST_INSTANCE=1
DORAX_SUPPORT_ROOT=/tmp/Context-Dock-Scenario-<UUID>/
```

Asserting the flag fails closed. Inferring "is this the user's live app" fails open, and the
failure mode is driving the user's real session — the one outcome this design must make
impossible rather than unlikely.

## 8. Scenarios

A scenario is a file: an entry step (hotkey or AX, the one path in-process cannot exercise),
then deterministic channel steps. The runner captures per step and diffs against a stored
baseline.

```
scenario "general chat answers about the frontmost app"
  launch  test-instance
  entry   hotkey ⌥Space
  open    generalChat.thread
  type    generalChat.input "what's happening in Code?"
  submit  generalChat.send
  wait    generalChat.message.assistant timeout 30s
  capture generalChat.thread
```

## 9. Testing

swift-testing, offline, no API key and no network.

**Registry lifecycle under SwiftUI reuse** — the family where this actually breaks:

- 20 instances of one InspectID coexist
- one instance disappears; only that instance's entry is removed
- a stale `remove` for a replaced instance cannot delete the replacement
- window closes; every entry for that window is purged
- window recreated with the same InspectID; no entry survives from the old one
- rapid geometry change; last value wins, no history retained
- ordinal derivation is stable and frame-ordered, not registration-ordered

**Coordinate conversion** — screen → window → root, round-trip, across multiple windows and
non-zero window origins, with an explicit case for the `.global`-is-not-screen trap.

**Channel authorization** — missing token, wrong token, expired token, wrong instance ID,
release build, unknown command, malformed payload. These matter more than another markdown
rendering test.

**Scenario ID coverage** — every InspectID referenced by a scenario exists in the vocabulary
and registers during that scenario. Without this, deleting `.generalChat.input` leaves
scenarios that rot silently and fail later for the wrong reason.

**Packet rendering** — markdown structure, `sourceCandidates` ordering, redaction of anything
outside the repo.

Overlay rendering and the live CLI loop stay manual; they need a model and a screen.

## 10. Phasing

| Phase | Deliverable | Value at this point |
|---|---|---|
| P0 | vocabulary, modifier, registry, lifecycle + coordinate tests | none visible; the foundation everything else queries |
| P1 | inspector overlay | first usable value — point at a thing, learn what it is |
| P2 | packet + DiagnosticsPanel integration | replaces the screenshot ritual |
| P3 | CLI handoff, RepairSession, rebuild survival | the loop closes; rebuild survival is the work |
| P4 | authenticated channel + isolated test instance | drive without replay |
| P5 | scenario runner + baselines | verification without a human |

P5 is the goal and must not be started first. It depends on the ID layer, the channel, and
instance isolation, all of which are earlier phases.

## 11. Risks

| Risk | Mitigation |
|---|---|
| Registry identity collision; a stale instance removing a live entry | `instanceToken` identity, unconditional window purge, dedicated lifecycle tests |
| Developer channel becomes an accidental local control API | DEBUG-only, developer-mode gated, authenticated socket, isolated test instance, URL scheme demoted to one inert verb |
| Coordinate-space confusion producing apparently random hit testing | explicit window-relative storage, one named conversion function, its own tests |
| Concurrent agent sessions editing the same surface files during the P0 grind | stage explicit paths only; never `git add -A` |
| `onGeometryChange` churn during animation | last-value-wins upsert, no history |
| Over-trusting `sourceCandidates` | named for its uncertainty; ranked not singular; git-blame evidence deliberately excluded |
| The loop pushing an unverified fix | project-scoped authority grant in `RepairSession`; push and destructive git withheld |

## Architecture after these decisions

```
                 DoraX UI
                    │
            .doraxInspect(ID)
                    │
                    ▼
            InspectRegistry
       window + ID + instanceToken
                    │
          ┌─────────┼─────────┐
          ▼         ▼         ▼
      Inspector   Packet    Scenario
       Overlay    Capture     Runner
                    │           │
                    ▼           │
             RepairSession      │
             (on disk)          │
                    │           │
               Claude CLI       │
            project authority   │
                    │           │
                  edit          │
                    ↓           │
                  build         │
                    ↓           │
             DoraX replaced     │
                    ↓           │
            reload RepairSession│
                    │           │
                    └─────┬─────┘
                          ▼
              isolated test instance
              DORAX_TEST_INSTANCE=1
                          │
              authenticated local IPC
                          │
                          ▼
                deterministic replay
                          │
                screenshot + state
                          │
                          ▼
                       VERIFY
                    /          \
                  pass         fail
                   │             │
                 stop      evidence → next
                             bounded attempt
```
