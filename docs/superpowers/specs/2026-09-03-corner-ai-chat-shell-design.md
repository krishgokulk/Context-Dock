# Corner AI Chat shell — design

Date: 2026-09-03
Status: approved design; implementation not started

## Decision

Context-Dock has two complementary AI surfaces:

- **Main app window** — full conversations, history, settings, search, Global Context,
  extensions, artifacts, consoles, and management.
- **Corner AI Chat** — the application's compact, immediate AI workspace.

Corner AI Chat is not another launcher. It contains AI modes only. Ordinary application
search, menu results, Global Context results, and extension search remain in their existing
surfaces unless an AI mode deliberately invokes them as tools.

This design supersedes the presentation and lifecycle portions of
`2026-08-31-corner-dual-chat-design.md`. It preserves that document's central boundary:
Frontmost App Chat and General Chat share a shell but remain separate product modes with
separate authority, state, and execution pipelines.

## Product model

The first implementation milestone supports:

1. **Frontmost App AI** — follows the current user-facing application and uses the dock's
   existing frontmost-app conversation and execution path.
2. **General AI** — uses the existing General Chat model, sessions, provider, attachments,
   app scopes, approvals, tools, and persistence.

Future adapters may add Selection Scope AI, Clipboard AI, and Quick Notes AI. Those are
explicitly not part of the repair milestone. Adding a mode must not add another window,
composer, lifecycle controller, or chat engine.

## Shared shell

One `CornerChatShell` owns the visual and interaction contract:

- one glass container;
- one bottom-anchored composer row;
- one transcript/suggestion region above the composer;
- one mode identity control;
- one place for activity, approvals, errors, and evidence receipts;
- one size and animation policy;
- one presentation state machine.

Mode adapters supply identity, draft, messages, suggestions, progress, approvals, actions,
and submission callbacks. The shell never changes the authority of a mode and never copies
its conversation into corner-only storage.

### Stable mode identity

The leading composer identity always names what the user is addressing:

- Frontmost App AI: application icon and name, such as `Code`.
- General AI: provider icon plus `General`.
- Future modes: stable names such as `Selection`, `Clipboard`, or `Quick Note`.

The compact mini state shows only the current mode's icon. It must never render or clip an
expanded composer into the mini frame.

## Presentation state machine

There is exactly one source of truth for corner chat presentation:

```text
hidden -> compact -> expanded -> mini -> hidden
              ^         |          |
              +---------+----------+
```

- `hidden`: panel contributes no interactive rectangle and is ordered out when no other
  corner surface is visible.
- `compact`: composer only, plus inline app matches or attachments when needed.
- `expanded`: transcript, suggestions, activity, or approval content above the composer.
- `mini`: current mode icon only; hovering or invoking the hotkey restores the prior
  compact/expanded state.

The state machine, not an individual mode model, controls panel visibility and geometry.
Mode models may report whether work is active, but may not independently hide or resize the
window. This removes the current split-brain failure where App Chat becomes `.hidden` while
`CornerChatPresentation.isVisible` remains true, causing the full input row to be clipped
inside a 52 by 44 pill.

### Stand-down protection

The corner remains expanded or compact while any of these is true:

- pointer is inside;
- composer is focused;
- mode is pinned;
- a turn is generating or executing;
- an approval is awaiting a decision;
- an attachment/app picker is open.

When none applies, the existing dwell shrinks it to `mini`; the mini dwell then moves it to
`hidden`. Switching Spaces counts as leaving, but never cancels a running conversation.

## Mode switching

- The global corner hotkey opens Frontmost App AI first.
- Horizontal left/right swipes over an empty composer switch modes.
- Left/right arrow keys switch modes only when the draft is empty and the text field has no
  cursor movement to perform.
- Switching preserves each mode's draft, attachments, conversation, and in-flight work.
- Returning to Frontmost App AI resolves the latest external frontmost application.
- Context-Dock itself is never selected as the frontmost target merely because the corner
  panel became key.

The first milestone switches between Frontmost App AI and General AI. The state machine must
support an ordered mode list so future AI adapters can join without rewriting gestures.

## Content sizing and scrolling

The composer is always at the bottom. Content grows upward.

- Empty mode: compact composer height.
- Suggestions, slash-app matches, attachments, activity, or approvals: grow only by the
  content required, up to the maximum corner height.
- Conversation: animate upward to the measured transcript requirement, capped at the
  maximum; overflow scrolls.
- Scroll content receives bottom inset equal to the composer and any approval/action shelf.
- New messages, activity steps, and approval cards scroll into view without hiding earlier
  content behind the composer.
- Unsupported large artifacts offer `Open in Main Window` rather than expanding forever or
  clipping.

The shell uses the same metrics and transitions for every mode. General AI must not open as
an empty full-height card.

## Activity instead of an unexplained spinner

Corner AI Chat shows an operational activity timeline, not private model chain-of-thought.
The timeline is derived from existing structured stream/status/tool events, for example:

- Understanding your request
- Reading the selected text
- Checking Reminders access
- Waiting for approval
- Running Create Reminder
- Verifying the result
- Complete

The latest step may animate; completed steps remain readable and collapse behind a step
count after the answer finishes. Tool invocations, permission gates, evidence, failures, and
verification are durable result metadata. A spinner may accompany the active step but may
never be the only explanation while structured progress exists.

Frontmost App AI continues to expose the dock pipeline's live step stream. General AI maps
`activeProgress` and `activeStatus` into the same shell component. The corner does not start
a second request or invent progress text.

## Approvals and cross-app access

An AI mode may use only its current scope. When a General AI request requires another app,
the existing structured `EnableAppRequest` is rendered in the shared approval/action region:

- identify the requested app;
- explain why it is required;
- show the proposed route or tool;
- provide explicit allow and decline actions;
- after approval, show the tools/capabilities added to that chat;
- re-run or continue the originating request through the existing pipeline.

Execution approvals from `ApprovalCenter` use the same region. Pending approval protects the
corner from auto-hiding. The same request can be resolved from the corner or the main window
without duplication.

## Conversations and New Chat

Corner AI Chat is persistent in exactly the same way as its source modes:

- Frontmost App AI reads and writes the existing per-app dock conversation.
- General AI reads and writes `GeneralChatWindowModel.shared` and its session stores.
- Closing or hiding the corner never clears history.
- Switching modes never clears history.
- The corner provides **New Chat**, not a destructive Clear control.

For General AI, New Chat archives/clears the transcript while preserving the current
`/`-selected app workspace and attachments policy already owned by the model. In an
app-scoped thread, it follows `GeneralChatWindowModel.newChat()` rather than calling
`clearActiveThread()`. Frontmost App AI uses the dock's existing new-session operation.

## Composer capabilities

The shared composer provides consistent controls while delegating operations to its mode:

- multiline text and attachment-only sends;
- files, images, pasted images, screenshots, area capture, and text capture where supported;
- inline `/app` lookup and keyboard selection in General AI;
- removable attached-app chips;
- cancel while sending;
- New Chat;
- pin/unpin;
- open the same conversation in the main window.

Commands such as `/message` and `/terminal` must be parsed by the existing General Chat app
directory and routing code. They are not hard-coded corner commands.

## Enablement and settings

Add a top-level **Enable Corner AI Chat** option. When disabled, its hotkey and panel content
are inactive without affecting conversations or the main app window.

The architecture allows later settings for enabled modes, default mode, auto-hide delay,
activity detail, gesture switching, and draft retention. The first repair milestone should
add only the top-level enable switch unless an existing settings pattern makes the remaining
controls trivial and independently testable.

## Error handling

- Provider errors, limits, and authentication failures render the shared structured error.
- A stalled tool turn ends through the existing watchdog and restores composer usability.
- Declining an app/tool request leaves the draft and conversation intact.
- Failed app lookup never attaches Context-Dock as a fallback scope.
- Mode switching during generation does not lose, duplicate, or redirect the answer.
- The corner never leaves an invisible key panel or a visible panel with a hidden mode.

## Implementation boundaries

The repair should converge, not add another compatibility layer:

1. Introduce the shared shell and presentation state machine.
2. Adapt Frontmost App AI without changing its dock execution pipeline.
3. Adapt General AI without changing its model/session ownership.
4. Remove duplicated General-only stand-down and geometry state.
5. Remove the corner Clear wiring and use the appropriate New Chat operation.
6. Add the top-level setting and route the hotkey through it.
7. Delete obsolete corner-only presentation paths once parity tests pass.

Do not merge General Chat and Context Dock Chat, move routing into the view, or create a new
conversation store.

## Verification

### Automated

- Every presentation transition has one owner and consistent panel visibility.
- Hidden contributes no size or hit target; mini renders icon-only content.
- Hover, focus, pin, generation, picker, and approval each protect against stand-down.
- Empty-field arrows/swipes switch modes; non-empty drafts retain cursor ownership.
- Independent drafts, attachments, messages, and in-flight turns survive mode changes.
- Frontmost target rejects Context-Dock and follows app/Space changes.
- General activity maps live progress/status into visible named steps.
- Cross-app enable and execution approvals appear once and resolve once.
- New Chat preserves the General app workspace and never calls destructive Clear.
- `/message` and `/terminal` filter and attach through the existing directory.
- Transcript and approval regions reserve composer space at every supported height.

### Manual acceptance

1. Enable Corner AI Chat and invoke the hotkey over VS Code; the Code composer focuses on
   the first click.
2. Ask a multi-step frontmost-app question and observe named live activity, tool use, and
   the final durable step trace.
3. Switch to General AI with an empty-field swipe/arrow; the shell remains stable and the
   General draft/history is preserved.
4. Type `/message` and `/terminal`, attach/remove each app, and verify the filtered picker
   stays above the composer without crashing.
5. Ask General AI to act in an unattached app; verify the explicit scope request, approve
   it, inspect the added tools, and receive one continued answer.
6. Start New Chat and verify the transcript resets while the selected app workspace remains.
7. Switch modes and Spaces during active generation; verify the answer stays in its
   originating conversation.
8. Leave the corner unpinned; verify expanded to mini to fully hidden. Return during each
   phase and verify smooth restoration.
9. Confirm mini is icon-only, no clipped app chip, invisible hit target, or stuck panel.
10. Open the main window and verify the identical conversation, approvals, progress result,
    and attachments appear exactly once.

## Out of scope for the repair milestone

- Implementing Selection Scope AI, Clipboard AI, or Quick Notes AI adapters.
- Moving ordinary launcher/search/Global Context results into Corner AI Chat.
- Exposing private raw model chain-of-thought.
- Rebuilding full history navigation, artifact editing, or the terminal console inside the
  corner.
- Changing provider selection, routing authority, or permission policy.
