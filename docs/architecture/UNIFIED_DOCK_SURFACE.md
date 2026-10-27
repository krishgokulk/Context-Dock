# Unified Dock Surface Architecture

> **Architecture truth, updated 2026-10-27 for #327.** Read with
> [Product Layers](PRODUCT_LAYERS.md) and the
> [App Pets design](../superpowers/specs/2026-10-27-app-pets-combined-chat-design.md).

## Core idea

One Dock shell. Stable state. Focus-specific content. Centre and corner are placements; a detached
Pet is another presentation of the same app scope.

```text
DockShell
  placement: centre | corner(anchor)
  focus: global | pet(appID) | combined(conversationID) | selection | media
  shared input, rows, material, keyboard state, animation and sizing
```

The retired Dock window is not revived. `Search/DockCore*` remains a windowless engine through
`DockEngine` until its logic moves; no new floating shell may copy it.

## Shell ownership

The shared shell owns:

- one rounded Liquid Glass window/material;
- input/composer family and keyboard ownership;
- row/card/icon families;
- running/pinned Pet strip;
- focus and back navigation;
- stable width/height rules and smooth transitions;
- light/dark, accessibility and screen-placement behavior.

Focus content owns only the information and controls for its job.

## Focus transitions

| Start | Action | Destination |
|---|---|---|
| Closed over an eligible app | normal launch | that frontmost App Pet |
| Closed with no eligible app | normal launch | Global Context |
| App Pet | tap Command | Global Context |
| App Pet with empty composer | Backspace | Global Context |
| Global Context | click running/pinned app | that App Pet in the Dock |
| Global Context | drag app icon out | detached persistent Pet |
| App Pet | accept another required Pet | same conversation promoted to Combined Chat |

Typed text is never discarded by a focus shortcut. Escape/back behavior stays one level at a time.

## Global Context content

- Universal search results, apps, files, extensions, commands and tools.
- Pet strip at rest and during search when layout allows.
- Launcher rows only; no transcript pretending to be search.

## App Pet content

- App identity, mode and running/headless state.
- App-scoped conversation and action/search phases.
- Relevant capabilities, attachments, progress, receipts and optional context panel.
- A clear affordance to return to Global Context and to detach/reattach the Pet.

## Combined Chat content

- Conversation plus visible participant Pet chips.
- One plan/progress trace across participants.
- Scope-connection cards separate from action-approval cards.
- Provider/context state and one final combined receipt.

## Detached Pet

A detached Pet may have compact/resting and expanded/conversation states, but it does not own a
second transcript, provider session, capability registry or approval path. Reattaching it returns
the same Pet/conversation to the Dock.

## Selection and media

Selection uses the shell as an explicit selection-aware card and may attach content to a Pet/chat.
It is not the normal launch destination and does not silently upload content. Media is a compact
Labs focus for media state/actions only.

## Premium-feel rules

1. No window recreation for focus changes.
2. Preserve input focus and typed text.
3. Keep the field and primary controls spatially stable.
4. Crossfade/animate content; never snap between unrelated containers.
5. One component family for rows, icons, pills, approvals, receipts and toasts.
6. Centre and every corner placement receive the same behavior and by-eye comparison.
7. Nothing clips when the Pet strip, participant chips or progress panel appears.

## Implementation rule

Do not build a custom window for Global, Pet, Combined Chat, Selection or a detached Pet. Evolve
the Corner shell/presentation controllers and plug focus content into it. The only exception is the
existing full chat window, which remains a larger view into the same conversation stores—not a
different product or execution path.
