# App Pets staged implementation rollout

> **Status:** owner-approved architecture; implementation has not started.
> **Required skill for each stage:** `superpowers:test-driven-development`, then
> `superpowers:verification-before-completion` before hand-off.

**Goal:** Deliver the App Pets product model in six independently testable changes without
creating another shell, conversation store, capability registry or execution engine.

**Architecture:** The existing Corner remains the only Dock shell. `DockEngine`,
`AppScopedChatService`, the capability index, `GeneralChatScope`, `GeneralChatSessionStore` and
`AppPanelChatStore` remain the implementation foundations. Each stage adds one missing product
concept and proves that centre and corner are two placements of the same surface.

**Tech stack:** Swift 5, SwiftUI, AppKit, swift-testing, existing Xcode project.

**Spec:**
[`2026-10-27-app-pets-combined-chat-design.md`](../specs/2026-10-27-app-pets-combined-chat-design.md)
and GitHub #327 / PR #337.

**Global constraints:**

- Base every implementation PR on `general-chat-agent`; one issue, branch and worktree per stage.
- Do not begin a stage until its predecessor is merged and owner-checked.
- Reuse the existing Corner, stores, capability index and shared executor.
- A Pet is a profile and scope, never a permanent model process.
- General Chat identity is separate from temporary per-turn app scope; using an app ability does
  not silently convert the thread into an App Pet conversation.
- Connecting a Pet grants conversation scope, never action authority.
- Headless means adapter/API/MCP/CLI/Shortcut execution. Computer Use is visible-UI fallback.
- Run `graphify update .`, `./scripts/check.sh`, and the relevant focused tests after Swift edits.
- Every visible stage is checked in both the bottom corner and centred launcher with comparison
  screenshots in its PR.
- Cloud builders edit; the Mac session builds, launches and performs the owner hand-check.

**Review focus:** Product-layer separation, stable conversation identity, no duplicated engine or
store, consequence-based approval, provider-token fitting, centre/corner parity and migration of
existing data without transcript loss.

## Delivery graph

```text
#338 Pet identity + Dock scope switching
  └─ #339 participant consent + same-thread promotion
       └─ #340 three-tier memory
            └─ #341 per-Pet /mods
                 └─ #342 detached Pet presentation
                      └─ #343 bounded proactive behavior
```

Each issue is a release gate, not merely a code-order hint. Later stages may be designed while an
earlier one is under review, but they must not be implemented against an unmerged state model.

## Stage 1 — #338 Pet identity and single-Dock scope switching

Establish one stable Pet identifier over current app/CLI scope identifiers, and make clicking a
running-app icon select that Pet inside the existing Dock. Clicking does not foreground the app;
explicit Open/Show does. Preserve per-app conversation history and Global Context navigation.

Detailed task plan:
[`2026-10-27-app-pets-stage-1-scope-switching.md`](2026-10-27-app-pets-stage-1-scope-switching.md).

**Exit gate:** owner verifies Finder → Safari → Finder switching, preserved conversations, no app
activation, Command/empty-Backspace to Global, and identical centre/corner behavior.

## Stage 2 — #339 participant consent and conversation promotion

Make the participant set first-class. A one-Pet thread previews the minimum new Pet, asks once to
connect it, and promotes the same conversation to Combined Chat without copying the transcript.
Wire the existing scope resolver rather than duplicating #57. Connection consent remains separate
from send/write/delete approval.

Stage 2 must model `ConversationKind` separately from `TurnScope`: General Chat can use bounded app
routes and stay General Chat; explicit anchoring creates App Pet Chat; persistent 2+ Pet scope creates
Combined Chat. Add a regression test forbidding hybrid identity such as “Mail General Chat” and
proving one Mail turn cannot restrict the next Mac-wide General Chat request.

**Exit gate:** the Finder-read → summarize → Messages-send example produces one thread, one task
graph, one receipt stream, and two distinct consent points: connect Messages, then approve Send.

## Stage 3 — #340 three-tier memory

Add a provider-fitted active projection, full local conversation memory with rolling summary, and
verified per-Pet long memory with provenance and user controls. This is the concrete E9 slice.

**Exit gate:** a thread can cross a small provider context limit without losing its local
transcript, changing providers preserves identity, and unverified inference never becomes long
memory.

## Stage 4 — #341 per-Pet `/mods`

Add typed Pet mode overlays that adjust instructions, capability ordering and output shape while
leaving scope, authority, privacy and budgets untouched. In Combined Chat the focused participant
owns `/mods`; `/mods AppName` targets one participant explicitly.

**Exit gate:** switching modes continues one thread, records the mode on later turns and cannot
bypass any approval or add a capability.

## Stage 5 — #342 detached Pet presentation

Dragging a running-app icon out of the strip creates an app-icon Pet token that shares the in-Dock
Pet's conversation, memory, mode, task and approval state. It is another presentation, not another
agent or safety route.

**Exit gate:** click switches in-Dock, drag detaches, reattach/close keeps history, multiple detached
Pets stay synchronized, and screenshots prove shared visual rules.

## Stage 6 — #343 bounded proactive behavior

Add opt-in Pet suggestions with verified triggers, interruption budgets, quiet periods,
deduplication and clear provenance. Suggestions cannot act, widen scope or launch UI silently.

**Exit gate:** deterministic tests prove opt-in defaults, deduplication, no-progress and token/time
budgets, and normal approval for every consequential follow-up.

## Relationship to the existing queue

This rollout does not silently replace the current queue. #205 remains the next `ready` task in
`00-NOW.md`; #338 starts only when the owner explicitly moves the App Pets implementation lane
ahead after #327 / PR #337 merges. #334 Conversations Board and #333 Side Thread consume the same
conversation model later; they must not invent competing identity or storage rules meanwhile.
