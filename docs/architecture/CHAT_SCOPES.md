# Chat Scopes, App Pets and Combined Chat

> **Architecture truth, updated 2026-10-27 for #327.** This defines storage and scope; visual
> behavior lives in [Unified Dock Surface](UNIFIED_DOCK_SURFACE.md).

## The one rule

**A conversation belongs to its scope and participant set, not to the surface showing it.**

```text
ConversationID
  participants: [] | [PetID] | [PetID, PetID, …]
  transcript: full local history
  summary: rolling factual conversation memory
  provider: user-selected default + provider projection state
  presentation: Dock | detached Pet | full chat window (views only)
```

Two views of one conversation show the same messages, task state, approvals and receipts. Nothing
is copied when a Pet is detached or the full window opens.

## Scope meanings

| Participants | Product meaning | Compatibility storage |
|---|---|---|
| none | **New chat / DoraX Chat**; capability discovery starts with no app grant | current `.general` path |
| one app/tool Pet | App Pet conversation when anchored there; otherwise a general thread with one connected participant | current `.app(bundleId)` / `.cli(command)` stores |
| two or more Pets | Combined Chat | current combined-thread app set, promoted into first-class participants |

Adding a Pet promotes the same `ConversationID`; removing a participant changes future scope but
does not erase prior messages or that Pet's memory.

Opening an App Pet resumes its latest active non-archived conversation. New chat is explicit.
The v1 detached Pet binds to that active conversation; one detached presentation per app prevents
ambiguous synchronization. The full chat window remains the place to browse/switch older threads.

## Scope connection

When a request needs an app outside the current participant set:

1. Resolve the minimum Pet set from the capability index.
2. Show which Pet is needed and why.
3. Ask once to connect it to the thread.
4. On acceptance, update the participant set and continue the same request.
5. On refusal, preserve the thread and offer the best result possible within current scope.

Connecting a Pet grants visibility to its allowed profile/capabilities for this thread. It does
not approve a write, outbound action, Computer Use or provider change.

## Grounding

Every surface calls the same grounding builders. For each turn:

- include only participating Pet profiles and step-relevant context;
- keep frontmost-window/page/selection facts distinct from durable memory;
- retrieve relevant conversation turns and per-Pet verified memory instead of sending full history;
- preserve provider privacy and context budgets;
- never expose one participant's unrelated private data to another participant's tool step.

Existing `ScopedAppPromptBuilder`, `AppScopedChatService` and `GeneralChatSessionStore` are evolved,
not duplicated.

## Memory ownership

- Full transcript and rolling summary belong to the conversation.
- Verified app preferences/facts/routines belong to that App Pet.
- Combined Chat writes back only verified, relevant outcomes to each Pet.
- Mode selection belongs to Pet + conversation and is visible on messages after it changes.
- A provider context window is a projection, never the source of truth for history.

## Full chat window

The full window is the larger view of the same conversations:

- sidebar rows use Pet/Combined Chat names and participant icons;
- `/` adds a Pet after scope consent;
- switching rows does not cancel or move in-flight work;
- each answer is filed into the `ConversationID` that requested it;
- closing a sidebar row removes presentation only, not transcript or Pet memory.

## Must not happen

- No per-surface conversation store or prompt builder.
- No silent participant attachment or scope widening.
- No action approval inferred from participant consent.
- No provider switch inferred from a multi-step task.
- No detached-Pet-only executor or safety path.
- No free-form Pet-to-Pet agent loop; one host-owned typed task graph coordinates all steps.
