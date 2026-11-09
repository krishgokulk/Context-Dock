# Unified Dock Surface Architecture

> **Architecture truth, updated 2026-10-27 for #327.** Read with
> [Product Layers](PRODUCT_LAYERS.md) and the
> [App Pets design](../superpowers/specs/2026-10-27-app-pets-combined-chat-design.md).

## Core idea

One Dock shell. Stable state. Focus-specific content. Centre and corner are placements; a detached
Pet is another presentation of the same app scope.

```text
DockShell
  placement: centre | corner(anchor) (`DockAnchor`)
  focus: .frontmost | .global | .pet(AppPetID) (`SurfaceFocus`, SurfaceFocus.swift)
  conversation: .general | .appPet(AppPetID) | .combined (`ConversationKind`, AppPetIdentity.swift)
  modes / overlays: selection card, drop shelf, media (Labs)
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

## Focus transitions & Unified Intent Routing

> **Update (2026-11-10):** Under the Unified Spotlight-Pet Surface (`docs/superpowers/specs/2026-11-10-unified-spotlight-pet-surface.md`), Global Context and Frontmost App Pet are **unified into a single input bar**. Users no longer need to tap `Command` to switch layers. Queries simultaneously search frontmost menus, global apps, files, and clipboard clips, with natural-language questions automatically escalating to the App Pet.

| Start | Action | Destination |
|---|---|---|
| Closed (anywhere) | normal launch (⌘⌘ or hotkey) | Unified Dock Launcher (Context-biased to frontmost app) |
| Unified Launcher | type command / app / file name | Highlighted command/file executes on ↵ |
| Unified Launcher | type question / AI instruction | Escalates to Frontmost App Pet on ↵ |
| Unified Launcher | tap Tab | Pins composer into App Pet Chat Mode |
| Unified Launcher | click running/pinned app | Switches active Pet context |
| Unified Launcher | drag app icon out | detached persistent Pet |
| Unified Launcher | New chat / Ask Dora | General Chat |
| General Chat | use an app ability for one turn | General Chat, with a temporary app step chip |
| General Chat | choose Open in App Pet | same conversation anchored to that App Pet |
| App Pet | accept another required Pet | same conversation promoted to Combined Chat |

Typed text is never discarded by a focus shortcut. Escape/back behavior stays one level at a time.

## Unified Board content

- Universal search results, apps, files, extensions, commands and tools.
- Frontmost app contextual actions and menus boosted by +500.
- Pet strip at rest and during search when layout allows.
- Conversational questions and instructions rank `[ 🤖 Ask Pet ]` and `[ 🌐 Search Web ]` at the top with incidental file penalty.

## App Pet content

- App identity, mode and running/headless state.
- App-scoped conversation and action/search phases.
- Relevant capabilities, attachments, progress, receipts and optional context panel.
- A clear affordance to return to Global Context and to detach/reattach the Pet.

## General Chat content

- Dora identity, never the frontmost app icon/name.
- Mac-wide transcript with no permanent app anchor.
- Per-turn app/source chips in the plan and receipts when abilities are used.
- An explicit **Open in <App> Pet** action when the user wants persistent app scope and Pet memory.
- No inherited Pet memory or app-only restriction after a temporary app route finishes.

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

Do not build a custom window for Global, General Chat, Pet, Combined Chat, Selection or a detached Pet. Evolve
the Corner shell/presentation controllers and plug focus content into it. The only exception is the
existing full chat window, which remains a larger view into the same conversation stores—not a
different product or execution path.
