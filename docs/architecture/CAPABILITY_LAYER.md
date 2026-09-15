# The Capability Layer

Architecture truth for how a request becomes an action. Read with
[Product Layers](PRODUCT_LAYERS.md) and [Chat Scopes](CHAT_SCOPES.md).

## The two surfaces

```
                         macOS
                           │
              ┌────────────┴────────────┐
              │                         │
       WHAT I'M DOING              WHAT I WANT DONE
              ▼                         ▼
       Context Dock Chat          General AI Chat
     current app · window        whole Mac · several apps
     page · selection · files    CLI · MCP · skills · APIs
              │                         │
              └────────────┬────────────┘
                           ▼
                 DoraX Capability Layer
```

**Context Dock Chat** answers about *this*: the app in front of you, its window, its
document, what you selected. Its scope is anchored, never chosen.

**General AI Chat** coordinates *across*: several apps, tools and files at once. Its scope
is chosen — attached apps, threads, CLI tools.

They are not merged, and not two implementations. One capability layer serves both; only
scope resolution differs.

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
| 4 | Menu command | Works for any app, but takes the screen. |
| 5 | Model | Answers from context; runs nothing. |

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
