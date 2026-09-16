# Chat Scopes and the General Chat Window

This file is architecture truth for how conversations are stored, grounded and shown.
It does not change the [Product Layers](PRODUCT_LAYERS.md) rule: the dock, the result
sheet and the chat window remain separate surfaces with separate jobs.

## The one rule

**A conversation belongs to a scope, not to a surface.**

```
scope = .general | .app(bundleId) | .cli(command)
   │
   ├── storage   ONE per scope
   ├── grounding ONE builder per scope kind
   └── surfaces  dock sheet · result sheet · chat window
```

Two surfaces showing the same scope show the same messages. A surface never owns a
conversation, so handing one over is opening it somewhere else — never copying it.

## Scopes

| Scope | Created by | Storage |
|---|---|---|
| `.general` | Result sheet, chat window "New chat" | `GeneralAIChatConversationStore` (UserDefaults, key `dorax.generalAI.currentConversation.v1`) |
| `.app(bundleId)` | Frontmost/scoped dock chat, window glyph handoff, `/appname` in the window | `AppPanelChatStore` file, key `dock_app_<bundleId>` |
| `.cli(command)` | CLI Tool Scope, its window glyph | `AppPanelChatStore` file, key `dock_app_cli://<command>` |

`GeneralChatSessionStore` is the index and the router: it maps a scope to its store,
holds the sidebar list, and per-thread extra apps (`…apps.v1`) for combined chats.
App and CLI scopes deliberately write the file the dock already used, so the window is
a second view of that conversation rather than a copy that drifts.

Threads created before storage was shared are merged into the dock file on first open
(union, deduped on role + text + second-resolution timestamp, since the two surfaces
mint different UUIDs for the same message), then the legacy key is deleted.

## Grounding

One builder per scope kind, called by every surface:

- `ScopedAppPromptBuilder.appIdentityBlock` — what the scope is, plus adapter actions,
  verified menu commands, MCP servers, API connections, Shortcuts, skills, linked CLIs
  and the tool-choice order. Handles `cli://` scopes too.
- `AppScopedChatService.dateTimeBlock` — current date/time, so "today" resolves.
- `AppScopedChatService.liveWindowFacts` — the scoped app's own front window title,
  open document and window list, read from **its** AX element, not from whichever app
  the global AX snapshot happens to belong to.

`AppScopedChatService.send` assembles those, adds the capability hub block, and runs
`sendWithTools` with `TerminalCommandExecutor` as the executor. Approval gates are
identical on every surface — a different window is never a reason to lower one.

LauncherView keeps thin delegates (`scopedAppIdentityBlock`, `currentDateTimeContextBlock`,
`liveAppWindowFacts`) that supply the dock-only inputs: the live browser page, the AX
window title, the typed query.

## How the chat window behaves

The window is the full-size view of the same scopes. It is not a new chat surface.

- **Sidebar** — "New chat" (the `.general` scope; from a scoped thread it returns there
  rather than wiping the thread being read), then **Apps & tools**: one row per app or
  CLI thread, ordered by when they were opened and never reordered by clicking.
- **A single attached app** appears as a row in Apps & tools. **Two or more** become a
  **Combined chat** entry carrying both icons — one conversation across both apps.
- **`/` in the composer** filters apps and picks one with Return. On an empty General
  chat, picking an app opens that app's own thread; otherwise it attaches as an extra
  scope on the current thread.
- **Sends are per thread.** Each thread tracks its own in-flight request; switching away
  neither cancels it nor moves its answer. An answer is filed into the scope it was
  asked in, on screen or not.
- **Transcript** shows day separators (Today / Yesterday / date) and the app icons that
  were attached when each question was sent.

## What must not happen

- No second store for a scope that already has one.
- No per-surface prompt builder — a question about an app must ground identically in the
  dock and in the window.
- No surface-specific approval path for command execution.
- Closing a window row removes the row, not the conversation: the dock still shows it.
