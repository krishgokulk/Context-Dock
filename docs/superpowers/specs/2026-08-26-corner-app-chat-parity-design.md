# Corner app chat — exact parity with the dock

Date: 2026-08-26
Status: planned, not implemented

## The problem

The corner App Chat surface answers with the wrong engine.

Context Dock's frontmost-app chat runs `handleL2Query(_:skipMenuRouter:)` in
`LauncherView+AIChat.swift` — a pipeline that resolves the dock scope, locks it
for the turn, builds a `FrontmostAppTaskPlan`, checks the Markdown memory store,
handles find tokens and task-control queries, gathers the Finder selection and
attachments, resolves a route, and only then runs the provider turn.

The corner calls `AppScopedChatService.send`, which is the **General Chat
window's** engine. It grounds itself differently.

The difference is visible, not theoretical: asked "any youtube links from all my
notes?" with Notes frontmost, the corner answered with the Notes *menu bar*
contents. The dock answers the question.

Two surfaces, two engines, one job.

## What "exact" has to mean

Not "imitated well". If the corner reproduces the dock's pipeline, the two drift
the first time either is touched. Parity has to be structural: **the same code
runs the turn, and the same conversation holds the result.**

## Why the obvious extraction is the wrong shape

The pipeline is ~300 lines that read and mutate `l2`, `searchState`, `frontmost`,
`contextDockChatFiles`, and call `requestWindowSizeUpdate` — all `LauncherView`
state. Lifting it into a service means lifting all of that with it.

And the conversation it produces, `l2.chatMessages`, has **221 references across
17 files**. `L2State` is a `struct` held as `@State`, so nothing outside the view
can observe it. A rename at 221 sites is a wide, risky change that buys only the
ability to read one array.

## The change

Move the conversation's *storage* into a shared object while leaving every call
site alone.

```swift
@MainActor
final class AppChatConversation: ObservableObject {
    static let shared = AppChatConversation()
    @Published var messages: [AIChatMessage] = []
    @Published var isLoading = false
    @Published var scope: (bundleId: String, appName: String) = ("", "")
}

struct L2State {
    // Storage moves; the spelling does not.
    var chatMessages: [AIChatMessage] {
        get { AppChatConversation.shared.messages }
        set { AppChatConversation.shared.messages = newValue }
    }
}
```

All 221 sites keep compiling and keep meaning what they meant. The dock stays the
only writer. The corner becomes a second *reader* of the same conversation.

Submission already has a path: the corner posts `.appChatPromptSubmitted`,
`LauncherView` handles it and calls the dock's own pipeline. That stays — it is
what makes the engine identical rather than similar.

## The one real risk

`@State` on a struct is what currently drives SwiftUI redraws. Once the array
lives in a class, mutating it no longer invalidates the view that owns `l2`, and
**the dock's chat stops redrawing** — the worst kind of regression, because it
looks like the model stopped answering.

`LauncherView` must observe the object for its own chat to keep updating:

```swift
@ObservedObject private var conversation = AppChatConversation.shared
```

This is the whole risk of the change, and it is verified first: send a question
in the dock and watch it stream, before anything about the corner is touched.

## Staging

1. **The object, and the dock still works.** Add `AppChatConversation`, move
   storage behind the computed property, observe it in `LauncherView`. No corner
   changes. Verify: the dock's chat answers and redraws exactly as before —
   streaming, tool chips, step traces.
2. **The corner reads it.** Render `AppChatConversation.shared.messages` in the
   corner instead of its own `messages`. Verify: a question asked in the dock
   appears in the corner and vice versa.
3. **The corner submits through the dock's pipeline.** Route Enter through
   `.appChatPromptSubmitted` with the dock kept hidden when the corner is the
   origin. Verify: the Notes question that failed now answers the way the dock
   does.
4. **Delete the corner's own engine.** Remove the `AppScopedChatService` call and
   the corner's private message list.

Stopping after any stage leaves a working dock. Stage 1 is the only one that can
break something the user already relies on.

## Keeping the dock hidden

The corner's turn must not raise the dock window. `handleL2Query` arms the chat
and calls `requestWindowSizeUpdate`, which shows the surface. The origin needs to
be carried through the notification so the dock can run the turn without
presenting itself, and reveal only if the user asks for it with the corner's
"open in dock" control.

## What is not changing

The dock's pipeline itself. Not one line of routing, grounding, or approval logic
moves — the point of this design is that the corner runs *that* code rather than
its own approximation.

## Verification

Per stage, in the running app. The failure mode is visual and behavioural, so the
suite cannot prove it. The specific case that must pass at the end: Notes
frontmost, "any youtube links from all my notes?", answered from the notes rather
than from the menu bar.
