# Corner General Chat: carry out what it works out

**Goal:** the corner's General chat runs what it resolves, says who it is talking to, and shows
its work — the three things the frontmost-app corner chat already does.

**Evidence:** one session, four symptoms, four causes. Each cause is a line of code, not a theory.

---

## What was seen

Typed `/message` then `/code`, asked for a summary and a draft to a person, then "yes, open it in
message":

1. Only the Messages icon appears at the top, though two apps were attached.
2. The draft was written as prose in the transcript; Messages never opened, the adapter never ran.
3. No reasoning or step rows, unlike the frontmost-app corner chat.
4. "I worked out what to run but couldn't carry it out on this surface. Try asking again, or ask
   in General Chat." — said *inside* General Chat.

## Why

### 1. The header can only draw one app

`CornerGeneralChatView.swift:227`

```swift
private var scopedAppName: String? {
    model.activeScopeAppName ?? model.scopeAppNames.first
}
```

`.first`. A combined workspace is `Messages + Code`, and the header renders one icon and one name,
so the second app is invisible at the only place the eye starts. The membership is correct
underneath — `currentMembership` has both — the header just cannot say so.

### 2 and 4 are the same bug: recovery is gated to app scope

`AppScopedChatService.swift:1666`

```swift
if ChatAnswerSanitizer.isProtocolOnly(text), case .app(let bundleId) = scope {
```

When the model writes its tool call as text instead of calling it, that is a call that never ran.
The surface refuses to show JSON as an answer — correctly — and then recovers by resolving the
request deterministically through `ChatRouteResolver`. But only `case .app`. In `.general` and in a
combined `.thread`, there is no recovery, so `ChatAnswerSanitizer.protocolFallback` is shown
instead: the exact sentence in symptom 4.

That is also symptom 2. "Open it in message" resolved to a Messages call, the model emitted it as
text, and nothing carried it out. The adapter was never reached — not missing, never called.

The dock has had the answer since `LauncherView+AIChat.swift:2343`:

```swift
func recoveredFromProtocolOnly(_ response: String, query: String) async -> String
```

Two surfaces, one failure, one of them fixed.

### 3. The corner's General chat never renders progress

`LiveAgentProgressView` has exactly two call sites — `AppChatPromptPill` (the frontmost-app corner
chat) and `GeneralChatWindowView` (the window). `CornerGeneralChatView` has none, though the model
already publishes `progressByScopeKey` and `statusByScopeKey` for every scope. The data is
produced and thrown away.

---

## Tasks

### Task 1 — Recover a protocol-only answer in every scope

**File:** `Context-Dock/AI/AppScopedChatService.swift`

Widen the recovery past `case .app`. For a combined thread, try each member app's routes in
membership order; for `.general` with no app, fall back to the general executable-action resolver
the dock uses. Keep the honest fallback when nothing resolves — the message is right when it is
true.

Test first, in `Context-DockTests/`: a protocol-only answer in a combined thread resolves to a
route; one with no route keeps the fallback.

### Task 2 — The header says who the chat is with

**File:** `Context-Dock/UI/CornerGeneralChatView.swift`

Render the full membership: icons for each app up to three, then "+N", with the names in the help
text and the accessibility value. One app keeps today's look exactly.

### Task 3 — Show the work

**File:** `Context-Dock/UI/CornerGeneralChatView.swift`

Render `LiveAgentProgressView(steps:)` from the model's progress for the active scope while a turn
is running, the way `AppChatPromptPill` does. Same component, same placement relative to the
transcript, so the two corner chats read as one surface in two modes.

### Task 4 — Audit the rest of the corner for the same class

The class is "one surface knows how to do it, the other was never given it". Check, and write down
each answer even when it is fine:

- attachments and Finder selection in corner General vs App
- stop/cancel mid-turn
- approvals raised inside a corner General turn (`ApprovalSurface.corner`)
- artifacts extracted from a corner answer
- console log entries for corner turns

### Task 6 — "No linked route" is not "cannot"

The Code chat answered honestly and was still wrong about what it could do. It said: no
update-check route linked, `code` CLI only prints the installed version, no adapter reader for the
release channel — so *"I can tell you what runs, not what's latest."*

But `run_command` exists, and `ArgvCommandGate` is explicit that anything off the auto-allowlist
"takes the approval path, which is the correct default for an executable we do not recognise."
One `curl` against the endpoint the model itself named, behind an approval card the user reads,
answers the question. The power was there; nothing told the agent it was there.

That is the gap, and it is a prompt-and-policy gap, not a missing mechanism:
`ScopedAppPromptBuilder` frames capability as *linked routes for this app* — adapters, CLI, MCP,
menus — so "no route" reads to the model as "impossible" instead of "not one-click; ask."

Fix: when a scoped turn finds no route for a read-only question, teach the escape hatch
explicitly — propose the exact command, run it through the approval path, report what came back.
Keep the guardrails as they are: writes still go through the file capabilities, `&&` still
rejected, nothing new auto-runs.

Acceptance: "is there a newer VS Code" in the Code chat proposes a `curl` the user can approve,
and answers from the response instead of ending in advice.

### Task 7 — Delegating to an installed coding agent

The user's real question: Claude Code and Codex are installed and can do this outright — why does
DoraX never offer to use them?

Nothing stops it: they are CLI tools like any other, linkable to an app, already reachable through
`cli.run`. What is missing is that it is nobody's idea. Worth a decision before code, because it
trades autonomy for cost and privacy — a delegated turn sends context to another agent and can run
for minutes.

Proposal to settle: an explicit, opt-in "Ask Claude Code" route offered only when a scoped turn has
no route and the request looks like work an agent could do, never silently.

### Task 8 — Ask the user in options, not prose

Today a clarifying question is a numbered list in prose and the user types "1". The `/` app picker
already proves the better shape in this exact surface: a list above the composer, ↑/↓ to move,
Return to take, and the turn continues with what was chosen.

Give the model a way to *ask* in that shape — a structured choice (single or multi select) rendered
as selectable rows in the corner card and in the window, with the answer fed straight back into the
same turn rather than starting a new one. Reuse `ChatSlashAppList`'s row, height and keyboard rules
so the two lists are one control with two sources.

Acceptance: "update" in the Code chat shows three tappable options; picking one continues the turn
without retyping; multi-select confirms with Return.

### Task 5 — Verify

`./scripts/test.sh` from this checkout, `git diff --check`, `./scripts/dev-run.sh`, then by hand:
`/message` + `/code` shows both; "draft a message to X" opens Messages; steps appear while thinking.
