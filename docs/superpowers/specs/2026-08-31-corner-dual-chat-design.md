# Corner dual-chat surface — design

## Purpose

The bottom-right corner chat is one compact entry point with two explicit modes:

1. **Frontmost App Chat** — the existing app-scoped conversation that follows the
   user-facing frontmost application.
2. **General Chat** — the existing unscoped General AI Chat, including its full composer,
   slash-app selection, tools, approvals, streaming progress, and persisted conversation.

These remain different product layers. They share a window shell and presentation rules;
they do not share scope, drafts, histories, or execution state.

## User-visible behaviour

### Hotkey cycle

The existing corner App Chat hotkey becomes the corner-chat mode key:

- Hidden -> open Frontmost App Chat.
- Frontmost App Chat -> switch immediately to General Chat.
- General Chat -> switch immediately to Frontmost App Chat for the current frontmost app.
- Further presses continue alternating.

The 150 ms duplicate-event guard remains. Switching modes never opens the large General
Chat window, clears a conversation, or sends the current draft.

### Mode identity

One stable composer stays at the bottom of the corner card.

- App mode shows the target application's icon and name.
- General mode shows the selected provider and a clear `General Chat` identity.

The identity control is clickable and switches modes using the same transition as the
hotkey. Content above it morphs in place; no second floating container appears.

### Complete General Chat behaviour

Corner General Chat observes and operates `GeneralChatWindowModel.shared`. It must expose
the behaviour available from the existing General Chat composer and transcript:

- the current General Chat thread and its persisted history;
- provider/model selection and provider-specific placeholder;
- multiline drafting and follow-up turns;
- `/` app selection from `ChatAppDirectory`, including entries such as Messages and
  Terminal, with Return selecting the leading match rather than sending the slash text;
- attached app scopes and removal of detachable scopes;
- file and image attachments, pasted images, and attachment-only sends;
- the existing attach menu actions that fit the compact surface;
- streaming assistant text, live progress/reasoning rows, structured result cards, files,
  app launches, and tool results through `AIChatMessageView`;
- command/capability approval cards from the shared `ApprovalCenter` inbox;
- cancel, retry, failure, and provider-limit states already produced by the shared model;
- clear/new-conversation behaviour without affecting App Chat history.

The corner must call existing model operations such as `send`, `attachApp`, `attachFiles`,
and `clearActiveThread`. It must not reimplement routing or create a second model request.
Features that require large workspace UI, such as the thread sidebar, terminal console, or
artifact preview, appear as compact result/action rows that open the existing full General
Chat window on the same active thread. The corner remains usable after that handoff.

### Frontmost App Chat behaviour

Existing App Chat behaviour remains intact:

- app actions and commands appear above the composer;
- the app-specific conversation and draft are preserved independently;
- switching apps or Spaces updates App mode to the current frontmost app;
- General mode does not retarget when the frontmost app changes;
- switching back to App mode resolves the latest frontmost application before rendering.

## Architecture

### `CornerChatPresentation`

A new main-actor observable coordinator owns only corner presentation state:

- `mode: CornerChatMode` (`frontmostApp` or `general`);
- visibility and hotkey-cycle decisions;
- independent draft handoff for the two modes;
- the mode-switch transition request.

It does not own messages and does not execute queries.

### Existing model ownership

- `AppChatPromptModel` remains the App mode owner and continues reading
  `AppChatConversation.shared`.
- `GeneralChatWindowModel.shared` remains the General mode owner and is the corner's sole
  sender, session selector, attachment owner, and live-progress source.
- `CornerDockController` owns the single `CornerDockPanel`, coordinates keyboard
  activation, and forwards the hotkey to `CornerChatPresentation`.
- `CornerDockSurface` selects mode-specific content inside the existing fixed host.

This follows the Unified Dock Surface rule: one shell and shared geometry/animation, with
mode-specific content and stable independent state.

## Reliable click and keyboard activation

The panel starts as `.nonactivatingPanel` so its transparent fixed host does not steal
clicks from the application below it. That style also explains the intermittent composer
failure: App Chat can receive a visual click without reliably becoming the key window.

Both chat composers therefore use one explicit activation path:

1. Mouse-down inside the active composer calls `CornerDockController.armKeyboard()`.
2. The controller temporarily removes `.nonactivatingPanel`, activates Context-Dock,
   orders the panel front, makes it key, and focuses the active text field.
3. Mode switches transfer first responder to the newly visible composer.
4. Dismissal or completed idle shrink calls `disarmKeyboard()` and restores the
   nonactivating style.

The interactive rectangle must be refreshed before focus is requested so the fixed host's
hit testing cannot reject the first click after a size or mode transition.

## Lifecycle

- Pointer inside, pinned, focused, or generating: remain expanded.
- Pointer outside and unpinned after the existing dwell: shrink to the active mode icon.
- Hovering the icon restores the same mode and its unchanged draft/transcript.
- Switching mode resets the dwell but not the pin.
- A General Chat send in flight remains visible even if the user switches temporarily to
  App mode; returning shows the same live turn.
- Dismissing the corner does not cancel either chat pipeline.

## Error and handoff behaviour

- A missing provider or exhausted quota renders the same shared General Chat error/result
  state; the corner does not invent fallback state.
- Approval prompts remain tied to the originating shared request and can be answered from
  either the corner or full General Chat window.
- Opening the full General Chat window reloads/selects the same active session and never
  duplicates the pending turn.
- Unsupported large content presents an `Open in General Chat` action rather than clipping
  or silently dropping the result.

## Testing

### Unit tests

- Hidden -> App -> General -> App hotkey cycle.
- Duplicate hotkey events inside 150 ms do not double-cycle.
- App and General drafts survive repeated mode changes independently.
- Frontmost-app updates affect only App mode.
- General mode binds to `GeneralChatWindowModel.shared` messages, sending state, progress,
  attachments, and active scope.
- `/message` and `/terminal` filtering uses `ChatAppDirectory`; Return attaches the leading
  match and clears the slash draft without sending it.
- App and General histories never overwrite one another.
- Pin, pointer, focus, and active generation prevent idle shrink.

### Window and integration tests

- First click inside either composer makes the panel key and the field first responder.
- Clicking transparent host space still reaches the application underneath.
- Switching modes while expanded keeps one panel and stable bottom composer geometry.
- General Chat submission produces one user turn and one provider request.
- Shared approvals can be resolved from the corner.
- Opening the full General Chat window during or after a corner turn shows the same thread
  and progress/result.

### Manual acceptance

1. Open App mode over VS Code and type without a second click.
2. Press the hotkey repeatedly and observe App -> General -> App in one shell.
3. Type separate drafts in both modes and confirm neither is lost.
4. In General mode, use `/message` and `/terminal`, select each result, and send a query.
5. Change provider, attach a file/image/app, and verify the real General Chat response.
6. Exercise a request requiring approval and resolve it in the corner.
7. Open full General Chat and confirm the same thread and response are present once.
8. Verify hover, pin, active-answer, idle-shrink, app switch, and Space switch behaviour.

## Out of scope

- A second General Chat engine, store, or floating window.
- Merging General Chat authority with frontmost-app authority.
- Rebuilding the full sidebar, terminal console, or artifact preview inside the compact
  corner card.
- Changing existing provider routing, permission policy, or execution contracts.
