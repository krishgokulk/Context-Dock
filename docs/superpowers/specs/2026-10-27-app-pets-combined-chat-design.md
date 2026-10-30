# App Pets, General Chat, Global Context and Combined Chat

> **Status: owner-approved architecture (2026-10-27); ready for implementation planning.**
> Written 2026-10-27 for GitHub #327. This is the canonical detailed design behind
> [`DORAX-BLUEPRINT.md`](../../master/DORAX-BLUEPRINT.md). It changes product language and the
> target architecture; it does not claim the product code already implements every rule below.

## 1. Product in one sentence

**DoraX is one Mac-wide Dock where every app can become an intelligent Pet: ask the app in front
of you, pull in another app when a task crosses boundaries, and let one shared agent engine finish
the work headlessly when possible, with approval and proof when it acts.**

The user should learn one object, not a collection of overlapping launchers and chats:

```text
                              ONE DORAX DOCK
                                     │
             ┌───────────────────────┼────────────────────────┐
             │                       │                        │
      Frontmost App Pet        Global Context          General / Combined Chat
      app memory + work        find apps/tools         Dora across the Mac
             │                       │                        │
             └───────────────────────┴────────────────────────┘
                                     │
                       one shared DoraX agent harness
               context · capabilities · approvals · verification
```

“One Dock” is a user model and a shell rule. It does **not** collapse the internal jobs of search,
app-scoped conversation, cross-app orchestration, media, or selection-aware actions.

## 2. Product nouns

| Name | Meaning |
|---|---|
| **Dock** | The only floating DoraX shell. It can appear centred or at a chosen bottom corner; position is presentation, not a separate product. |
| **Global Context** | The Dock's home/launcher focus: search apps, files, commands, tools and running apps. |
| **App Pet** | An app-scoped assistant with an identity, capability profile, conversation, modes and memory. A Pet can be shown inside the Dock or detached onto the desktop. |
| **Pet strip** | Running and pinned app icons in Global Context. An icon is a dormant Pet entry point, not a separate agent process. |
| **General Chat** | Dora's Mac-wide conversation. It can invoke app abilities per turn without becoming app-scoped or loading that Pet's long memory. |
| **Combined Chat** | One explicitly connected conversation and task graph involving two or more persistent Pet participants. |
| **App Pet Profile** | The app-owned instruction and capability bundle: identity, knowledge, skills, connectors, routes, modes, memory policy and safety limits. This may map to current `AGENT.md`/adapter data, but product docs call it a profile to avoid confusing it with repository `AGENTS.md`. |
| **Mode (`/mods`)** | A Pet-specific behavior preset such as Browse, Research or Automate. A mode changes reasoning/tool emphasis and output shape, never authority. |

Compatibility names may remain in code during migration (`Context Dock`, `App Chat`, `Corner*`).
New user-facing work should use **General Chat**, **App Pet**, **Combined Chat**, **Global Context**,
and **Dock** with those identities kept distinct.

A provider conversation with no permanent app anchor is **General Chat**. It remains General Chat
when a turn temporarily invokes Mail, Finder or another app profile. **App Pet Chat** is created only
when the user deliberately opens/anchors the conversation to that Pet; **Combined Chat** appears
only when two or more Pets are persistently connected. A header such as “Mail General Chat” is
invalid because it mixes two different conversation identities.

The distinction is:

```text
conversation identity: General Chat | <App> Pet | Combined Chat
turn execution scope:  the minimum app/tool profiles used for this request
```

Execution scope is recorded in the plan and receipt, then expires. Conversation identity controls
default grounding, memory and the header/sidebar name.

## 3. One Dock, four conversational focus states

The shell, input, state and conversation identity remain stable while focus changes.

```text
open DoraX
   │
   ├─ normal launch ─────────────► frontmost App Pet
   │                                  │
   │                                  ├─ press ⌘ ──────────► Global Context
   │                                  └─ empty Backspace ──► Global Context
   │
   ├─ explicit Global hotkey ─────► Global Context
   │                                  │
   │                                  ├─ click app icon ───► that Pet in the Dock
   │                                  └─ drag app icon ────► detached persistent Pet
   │
   ├─ New chat / Ask Dora ─────────► General Chat
   │                                  ├─ one-turn app route ─► stays General Chat
   │                                  └─ Open in App Pet ────► anchored App Pet Chat
   │
   └─ persistent cross-app task ───► Combined Chat (after scope consent)
```

Rules:

1. A normal launch opens the frontmost app's Pet. If no eligible app exists, open Global Context.
2. A tap of Command zooms between the current Pet and Global Context. With an empty composer,
   Backspace walks out to Global Context. Backspace never destroys typed text.
3. Clicking a running-app icon changes the Dock's active Pet without creating another window.
4. Dragging a running-app icon out creates a persistent desktop Pet for that app. Multiple
   detached Pets may coexist, but they are views into shared app scope/state, not independent
   model processes.
5. Centre and corner use identical behavior, shell components, keyboard rules and data. They are
   placements of one Dock.
6. Search, General Chat, Pet conversation and Combined Chat render different content inside the shell. They do
   not become one ambiguous result list.

### General Chat flow

General Chat behaves like a capable Mac-wide assistant, not a hidden frontmost-app chat:

1. The header uses Dora/General Chat identity, never an app icon plus “General Chat.”
2. “Summarize my five newest emails” selects Mail as a turn-scoped ability because the user named
   the source. The plan shows a Mail chip and the receipt records the Mail route.
3. The conversation remains General Chat. Mail Pet memory is not loaded or updated merely because
   its ability ran.
4. The next request, “quit other apps except Claude and ChatGPT,” resolves Mac-wide app-control
   routes and is not blocked by the previous Mail turn.
5. Writes, sends, deletes, quits and UI control still receive their normal exact approval.
6. If the user wants ongoing Mail context, Dora offers **Open in Mail Pet**. That explicit action
   anchors the same conversation and enables Mail's default profile grounding and verified memory.

When General Chat needs an app the user did not name, especially for private data, it previews the
proposed source before reading. Explicitly naming the app supplies request scope but never grants a
new permission or approves a consequential action.

## 4. What an App Pet owns

Every installed/running app can expose a Pet. A Pet is assembled from one shared harness plus an
app-specific profile; DoraX does not start one permanent LLM per app.

```text
AppPet(appID)
  identity        name · icon · bundle/version · running/headless state
  profile         instructions · learned app knowledge · user edits
  capabilities    adapter · dictionary · MCP · CLI · Shortcut · menu · Computer Use
  skills          vendor/reference knowledge and reusable task procedures
  connectors      linked accounts/services allowed for this app
  modes           /mods presets supported by this Pet
  conversation    current thread + transcript + rolling summary
  memory          verified per-app facts, preferences and routines
  state           in-Dock | detached | dormant; active task and receipts
```

The profile narrows and guides. It cannot grant access, bypass approvals, change provider privacy
rules, or create a capability the host did not register.

**Eligibility:** every running app may appear as a generic Pet, and every installed app may be
found in Global Context. A generic Pet has identity, cached menus/metadata and only the capabilities
already granted to that app. Rich knowledge, data routes, modes and memory appear as profile sources
become available. “No route” is an honest Pet state, not a reason to hide the app or invent access.

**Profile merge precedence:** host safety/scope policy → explicit user edits/preferences → selected
`/mods` overlay → built-in/installed adapter knowledge → linked skills/connectors → learned hints.
Lower sources cannot override higher ones. Capabilities merge by stable typed id and retain origin,
risk and health; prose never grants a capability. Conflicts are shown in the profile inspector and
resolved in favor of the narrower/safer source.

A Pet works whether its app is open or closed:

- **Headless-capable route:** answer or act without foregrounding the app.
- **Route needs the process but not the UI:** start the app hidden and do not activate it.
- **Route needs visible UI:** launch/activate only according to the launch policy below.
- **No safe route:** explain the gap and offer the next valid rung; never pretend.

## 5. Headless-first launch and approval policy

The best behavior is task-dependent, not “always ask before launch” and not “always launch.”

| Situation | DoraX behavior |
|---|---|
| The task can complete headlessly | Run headlessly. Do not launch the app. |
| The app process is required but can stay hidden | Start hidden; keep the user's focus. |
| The user explicitly says open/show/bring me to | Launch or activate as requested; no redundant launch question. |
| Visible UI is only a fallback DoraX needs | Show a short plan card and ask before taking the screen. |
| The step writes, sends, deletes, publishes or is otherwise risky | Use the normal exact approval card regardless of whether the app is open. |

Connecting a Pet to a conversation grants **scope**, not permission to act. Approval remains per
route/action and is decided by the shared host layer.

## 6. Short memory, conversation memory and long memory

The product needs three distinct tiers so long conversations survive provider limits without
turning every prompt into the full history.

| Tier | Contains | Lifetime | Sent to provider |
|---|---|---|---|
| **Active context** | Recent turns, current attachments, current plan/tool results | Current turn window | Only the token-fitted relevant slice |
| **Conversation memory** | Full local transcript plus rolling factual summary, decisions and unresolved work | Thread lifetime | Summary + retrieved relevant turns |
| **Pet long memory** | Verified app-specific preferences, facts, routines and successful procedures | Across threads | Retrieved only when relevant to this Pet/task |

Rules:

1. The full transcript stays local and searchable; provider context is a bounded projection.
2. Summaries distinguish user statements, observed facts, assistant inferences and verified
   receipts. An assistant guess never becomes memory.
3. Long memory is per Pet by default. Combined Chat keeps its own participant/task summary and
   writes back only verified, relevant facts to participating Pets.
4. The user can inspect, edit, pin and delete Pet memory.
5. Near a provider limit, DoraX offers **Keep active** (condense and continue), **Archive and new
   chat**, or **New chat without saving**. The local transcript is not silently lost.
6. Changing providers re-projects the local conversation into that provider's available context;
   it does not create a second conversation.

Long-memory admission is provenance-based:

- explicit “remember this” user statements save immediately with `user` provenance;
- stable facts directly read and verified by a receipt may save automatically with source/time;
- inferred preferences and routines are suggestions until the user accepts them;
- raw message/file bodies, credentials, secrets and transient UI state never auto-enter long memory.

## 7. `/mods` per Pet

Typing `/mods` shows the modes supported by the current Pet. Example modes:

- Safari: Browse, Research, Compare, Automate.
- Finder: Find, Organize, Batch, Inspect.
- Messages: Read, Draft, Send.
- Terminal: Explain, Diagnose, Run.

A mode may change:

- the profile instructions used for the turn;
- which relevant capabilities are shortlisted first;
- plan detail, response style and verification emphasis;
- default attachment/context preferences inside the same scope.

A mode may **not** change:

- app scope or connected participants;
- route authority, risk or approval requirements;
- provider privacy ceiling;
- token, round, time or no-progress safety budgets.

Recommended interaction: a mode switch continues the same thread and is recorded on subsequent
messages. “Start a branch with this mode” can be an explicit secondary action; mode changes should
not silently fork conversation history.

In Combined Chat, `/mods` applies to the currently focused participant. `/mods Safari` targets a
named participant, and each participant chip exposes the same mode picker. A coordinator-wide mode
is a separate future feature; it is not inferred from one Pet's mode.

## 8. Cross-app work becomes Combined Chat

Combined Chat is not several agents talking to each other. It is one coordinator creating a typed
task graph and invoking the smallest set of Pet capability profiles required by the task.

### From inside one Pet

If a Finder Pet request says “get the Markdown files from Downloads, summarize them, and send the
short summary to Gokula Kannan J in Messages”:

1. Finder Pet understands the request and searches the shared capability index.
2. DoraX identifies Finder + Messages as the minimum participants.
3. Before Messages data/capabilities enter scope, the UI previews `+ Messages Pet` and asks once
   to connect it to this thread.
4. On approval, the existing thread is promoted to Combined Chat; it is not copied.
5. Finder reads the selected files headlessly and returns typed evidence.
6. The selected provider summarizes only the budgeted relevant content.
7. Messages prepares the exact recipient and message preview.
8. Sending asks for outbound approval naming the recipient and final text.
9. DoraX sends, verifies where the route supports read-back, and presents one combined receipt.

If the user refuses the scope connection, the original Pet thread remains intact and DoraX offers
the best single-Pet result it can produce.

### From Global Context / Combined Chat

The coordinator discovers participants from the request, then shows them as Pet chips. The user
can add/remove Pets explicitly. Each Pet receives only the data required for its step; connecting
Messages does not expose the full Finder transcript to Messages tools.

### From General Chat

General Chat may use several app abilities in a bounded one-off plan without changing its identity;
the visible plan and receipts make each route clear. Dora proposes Combined Chat only when the
request needs persistent participants, shared cross-app context, ongoing Pet memory, or follow-up
work that would otherwise repeatedly reconstruct scope. The user sees the participant preview and
chooses; there is no silent promotion.

Participant connection and action approval are separate gates:

```text
May this thread use Messages?       scope consent, once per participant/thread
Send this exact text to this person? action approval, for the outbound step
```

## 9. Provider and token orchestration

The user's selected provider remains the conversation's default. Multi-step work must not silently
change providers.

The host owns:

- capability discovery and typed task graph construction;
- provider context budgets and compaction;
- tool, round, time and no-progress budgets;
- scope and privacy enforcement;
- approvals, execution and verification;
- receipts and local conversation/memory persistence.

The provider owns language reasoning inside the envelope the host supplies. If a provider lacks
native tool calling, DoraX uses the same typed capabilities through its supported directive bridge;
it never lowers authority or verification. Optional per-step provider changes must be visible and
user-approved, and are not required for the first App Pets implementation.

## 10. Shared native capability layer

Selection, clipboard, windows, files, native sharing and notifications are host services available
to every Pet through the same permission/risk layer. They are not copied into every Pet profile.

```text
Pets / Combined Chat
         │ request typed capabilities
         ▼
Shared native layer
  selection · clipboard · windows · files · share · notifications
         │
         ▼
scope guard · approval · executor · verifier · receipt
```

Selection remains a distinct input/action mode. A normal Dock launch must not silently send the
current selection to a Pet or provider. The explicit Selection Scope hotkey opens the selection
card; the user may then attach the selection to the current Pet or Combined Chat. This preserves
selection privacy and the rule that the Selection Shortcut Sheet is not a launcher.

## 11. Persistence and state identities

One logical thread can appear in the Dock, a detached Pet and the full chat window. Those are views,
not copies.

Minimum durable identities:

```text
PetProfileID      = app bundle id (or stable cli/tool scope id)
ConversationID    = one transcript/summary/provider state
ConversationKind  = general | pet(PetProfileID) | combined
ParticipantSet    = ordered PetProfileIDs connected to a conversation
TurnScope          = temporary app/tool profiles used by one request
ModeSelection     = mode active for a Pet in a conversation
PetMemoryID       = PetProfileID + memory record id
TaskRunID         = plan, approvals, steps, verification and receipts
PetPresentation   = inDock | detached(position) | dormant
```

A General Chat thread can use zero, one or several temporary routes without changing kind. An
explicitly anchored single-participant thread is an App Pet conversation. Adding a second persistent
participant promotes the same `ConversationID` to Combined Chat. Removing participants does not
delete their history or memory.

Opening an App Pet resumes that app's latest active, non-archived conversation. **New chat** is an
explicit action; archived threads never reopen automatically. In v1 there is one detached
presentation per app, bound to that active conversation. Dragging the same app again focuses its
existing detached Pet. Multiple detached windows for different threads of one app are deferred;
the full chat window remains the thread switcher.

## 12. Safety and honesty invariants

- The model proposes; the host decides.
- A Pet profile can guide but cannot widen authority.
- Scope consent is not write approval.
- Reads use the minimum relevant context; private and untrusted data keep their taint.
- Writes/outbound/destructive work names the exact target and payload before approval.
- UI-driving routes are last and cannot be used merely to discover what an app can do.
- Every plan is bounded; contradiction stops dependent steps.
- Success requires a real receipt/read-back where available. Otherwise the result says
  **unconfirmed**, not completed.
- Detached Pets share the same gates and stores as the Dock; a cute surface is never a safety
  exception.

## 13. Migration without product-layer collapse

1. Keep the current Corner as the only shell and treat centre/corner as placements.
2. Rename the user model first: Context Dock/App Chat → App Pet; preserve General Chat as Dora's
   unanchored Mac-wide chat; use Combined Chat only for explicitly persistent multi-Pet scope. Keep
   compatibility type names while migrating.
3. Add Pet presentation state (dormant, in-Dock, detached) over existing app-scoped stores.
4. Normalize App Pet Profiles from existing adapters, `AGENT.md`, skills, connectors and routes;
   do not build a seventh registry.
5. Add explicit scope-promotion and participant chips to the existing combined-chat storage.
6. Implement conversation summaries and per-Pet memory before adding proactive Pets.
7. Add `/mods` as bounded profile overlays.
8. Only then add detached desktop Pets and proactive briefings, after the same behavior is proven
   inside the Dock.

This order preserves the working engine. The visual Pet is the last representation layer over
existing capability, conversation and safety contracts—not a second orchestration system.

## 14. Acceptance examples

The architecture is implemented correctly when all of these are true:

- Open DoraX over Safari: Safari Pet appears in the one Dock; Command or empty Backspace returns
  to Global Context without recreating the shell.
- Click Finder in the running-app strip: the same Dock becomes Finder Pet. Drag Finder out: a
  persistent Finder Pet appears while the Dock remains usable.
- Ask a closed-app Pet a data question with a headless route: the answer arrives without the app
  appearing. Ask to “show me”: the app opens. Require UI only as fallback: DoraX asks first.
- Switch `/mods` from Research to Browse: the same thread continues, with the new mode visible;
  approvals and scope are unchanged.
- Continue a long conversation beyond one provider window: local history remains searchable,
  the rolling summary preserves decisions, and relevant older facts are retrieved.
- Ask Finder Pet to summarize Markdown files and message a contact: Messages scope is previewed,
  the thread becomes Combined Chat once connected, send approval shows the final payload, and one
  verified combined receipt closes the task.
- In General Chat, summarize five recent Mail messages and then quit unrelated apps: the first turn
  shows a Mail route chip, the header remains General Chat, Mail Pet memory is not implicitly loaded,
  and the second turn is not restricted to Mail.
- Trigger Selection Scope: selection stays local until attached or an action is chosen; normal Pet
  launch never silently uploads it.

## 15. Deliberately not introduced

- No second floating shell.
- No permanent LLM process per app.
- No Pet-to-Pet free-form conversation loop.
- No separate Pet capability registry.
- No mode-specific permission system.
- No automatic app launch when a headless route exists.
- No silent cross-app scope widening or provider switching.
- No hybrid “Mail General Chat” identity and no app restriction leaking from one General Chat turn
  into the next.
