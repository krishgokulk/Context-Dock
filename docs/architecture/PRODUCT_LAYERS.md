# DoraX Product Layers

> **Architecture truth, updated 2026-10-27 for #327.** Detailed product behavior:
> [App Pets, Global Context and Combined Chat](../superpowers/specs/2026-10-27-app-pets-combined-chat-design.md).

## Layer rule

**One Dock shell, one orchestration harness, several jobs that must remain explicit.**

- Global Context and the active App Pet share shell/state and differ by `SurfaceFocus`.
- App Pet conversation is anchored to one app profile.
- Combined Chat coordinates two or more explicitly connected Pet profiles.
- Selection is an explicit input/action mode, not a launcher and not silently uploaded.
- Media remains media-only.
- Centre, corner and detached Pet are presentations, not separate products or engines.
- Query intent + `RequestLane` choose headless data work versus visible UI work. A visible surface
  never decides authority.

“One product” therefore does not mean one mixed list. Each focus renders only its own content and
passes work through the same capability, approval, execution and verification contracts.

## Global Context

**Job:** Mac-wide launcher/home.

- Search apps, files, extensions, commands and tools.
- Show running and pinned apps as dormant Pet icons.
- Click an icon to switch the Dock to that Pet; drag it out to detach a persistent Pet.
- Cache-first while typing; no live AX/menu scan on the keystroke path.
- Never become a conversational transcript or silently execute a cross-app plan.

## App Pet

**Job:** understand and work with one app.

- Show the app identity, conversation, actions and current task state.
- Assemble its App Pet Profile: knowledge, skills, connectors, routes, modes and per-app memory.
- Prefer data/headless routes. Start hidden if a route only needs the process. Ask before taking
  the screen when visible UI is only DoraX's fallback.
- Stay anchored to that app until the user switches Pet or consents to add another participant.
- Use `/mods` only as bounded behavior overlays; modes never change scope, authority or approvals.

An App Pet replaces the user-facing split between “Context Dock” and “Context Dock Chat.” Search
rows and conversation are still different content phases inside the Pet focus.

## Combined Chat

**Job:** one conversation and typed task graph across two or more Pets.

- Discover the minimum required participants from the request.
- Preview and request scope consent before connecting another Pet.
- Promote the existing `ConversationID`; never copy or fork the transcript just because scope grew.
- Give each Pet only the data required for its step.
- Keep participant consent separate from action approval.
- Present one plan, live step status and combined receipt.

“General Chat” may remain a compatibility name for a zero/one-participant conversation during
migration. The target user-facing product is Combined Chat when multiple Pets participate.

## Shared native capability layer

Selection, clipboard, windows, files, native sharing and notifications are host capabilities used
by every Pet through the same typed registry and gates. They are not copied into each profile.

The shared request path is:

```text
scope → intent → context → capability discovery → plan
      → approval → execution → verification → receipt
```

## Selection Scope

**Job:** act on or attach the user's explicit selection.

- Opens from its dedicated hotkey or an explicit attach action.
- Supports selected text, file, folder, URL, image and clipboard items.
- May attach the selection to an App Pet or Combined Chat after the user chooses.
- Must not replace a normal Dock launch or silently send selected content to a provider.
- Remains fast, stable and action-oriented—not a launcher or independent chat product.

## Media Dock

**Job:** media state and controls only.

- No launcher results.
- No App Pet or Combined Chat transcript.
- Uses the shared visual shell only when enabled as a Labs mode.

## Persistence rule

A conversation belongs to its scope/participants, not to the window that displays it. The Dock,
detached Pet and full chat window are views into the same stores. A detached Pet is never a second
agent process or a second safety path.

## Code organization target

```text
Context-Dock/
  Shell/              one Dock, centre/corner placement, shared input/rows/animation
  Surfaces/
    GlobalContext/
    AppPets/
    CombinedChat/
    Selection/
    Media/             Labs
  Services/            native context/capability hosts
  AI/                  shared orchestration and provider adapters
  Memory/              transcript, summaries and per-Pet memory
```

Move code only through scoped implementation plans. Reuse `DockEngine`/current stores and move
logic out of `DockCore*`; never copy an engine to fit the new names.
