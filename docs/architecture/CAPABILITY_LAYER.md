# The Capability Layer

Architecture truth for how a request becomes an action. Read with
[Product Layers](PRODUCT_LAYERS.md) and [Chat Scopes](CHAT_SCOPES.md).

## Conversation scopes and one capability layer

```
                         macOS
                           │
       ┌───────────────────┼───────────────────┐
       │                   │                   │
       ▼                   ▼                   ▼
  General Chat          App Pet           Combined Chat
  Mac-wide Dora       one anchored app   connected Pets
  temporary routes    profile + memory   shared context
       │                   │                   │
       └───────────────────┼───────────────────┘
                           ▼
                 DoraX Capability Layer
```

**General Chat** is Dora's Mac-wide conversation. It may route one request through an app ability,
but that temporary turn scope does not rename the conversation, anchor it, or load Pet memory.

**App Pet** answers about *this*: one app profile, its relevant window/document and explicitly
attached input. Its scope is anchored to that Pet.

**Combined Chat** coordinates *across*: several explicitly connected Pets, tools and files. Its
scope is the participant set; adding a Pet requires scope consent.

They share one Dock and one implementation without merging their jobs. One capability layer serves
all three; conversation identity, scope lifetime and participant set differ.

## The pipeline

Every request, on either surface, runs the same sequence:

```
request → intent → context → capability discovery → ranking
       → plan → approval → execution → verification → result
```

A stage that cannot be shown is a stage that cannot be trusted. Each one is observable:
the Console records what ran, the log records where a turn stalled.

## Route ranking

A capability is not just a thing that can run — it carries where it came from and what it
costs. Ranking is fixed, and deliberately boring:

| Rank | Kind | Why it wins |
|---|---|---|
| 1 | Native app action (adapter) | The app's own API. Deterministic, no UI theft. |
| 2 | MCP tool | Structured, typed, no window opens. |
| 3 | CLI | Deterministic and inspectable; output is a receipt. |
| 4 | Shortcut / automation | Typed when declared; may require the app process. |
| 5 | Menu / keyboard / AX | Works broadly, but takes the screen; last resort. |
| 6 | Model | Answers from context; runs nothing. |

Read-only routes never require a decision from the user. When several routes differ in
consequence — one opens a window, another does not — the user picks, and the choice is
remembered per app and per kind of request.

## What must stay true

- **The model is replaceable; the capability graph is the product.** Nothing in the layer
  may depend on a specific provider's behaviour.
- **Deterministic before probabilistic.** A registered action beats a generated command,
  every time, without the model being asked.
- **Verification, not narration.** After an action that changes something, read the state
  back. An answer that claims a result it did not confirm is a bug.
- **Approval belongs to the layer, not the surface.** The same gate applies whether the
  request came from the dock, the window or a hotkey.
- **One capability representation.** App actions, menu commands, CLI, MCP, API and skills
  reach the model through a single normalized shape, or the ranking above is fiction.
- **Shared native services.** Selection, clipboard, windows, files, share and notifications are
  host capabilities. Pet profiles reference them; they do not copy or privately reimplement them.
- **Headless first.** A route that can run without visible UI wins. Starting/activating an app is
  a route requirement to disclose, not the definition of an App Pet.

---

## The Two-Sided Normalized Adapter

DoraX sits directly between the Frontmost Application and the AI Provider. It normalizes all external complexities so neither side needs custom, messy code:

```
┌──────────────────┐          ┌───────────────────────────┐          ┌──────────────────┐
│  Frontmost App   │◄────────►│       DORAX ENGINE        │◄────────►│   AI Provider    │
│ (macOS Process)  │          │ (Sense, Act, Filter, Gate)│          │ (Claude / Gemini)│
└──────────────────┘          └───────────────────────────┘          └──────────────────┘
```

1. **Downwards (macOS):** DoraX abstracts whether an app uses AppleScript, UTCP HTTP APIs, or Accessibility menus into a unified Sense & Act interface.
2. **Upwards (AI):** DoraX provides a single **App Envelope** (app identity, `AGENT.md` rules, live menus, and JSON tools) to the model.
3. **Control:** DoraX enforces target app pinning, read-vs-write approval gating, and outbound data protection.

