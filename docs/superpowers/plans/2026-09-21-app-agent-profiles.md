# Every app is an agent: profiles, native MCP, and one organised adapter

Written 2026-09-21. Owner's request: *"make a perfect plan and implement … our organised adapter,
based on app, and act as agent per app, using skills, .md file, agent, scripts, etc., a native
Apple MCP"*, with https://webkit.org/blog/18136/introducing-the-safari-mcp-server-for-web-developers/
as the reference for the last part.

## Where we actually are

DoraX already has every ingredient, each with its own store, its own settings surface and its own
way of reaching the prompt:

| Piece | Type | Stored | Reaches a turn via |
|---|---|---|---|
| Adapter actions | `AdapterAction` in `AppAdapter` JSON | `DoraX/AppAdapters/*.json` | `run_adapter_action`, route resolver |
| Skills | `AdapterSkill` (prompt bodies) | `SkillStore` | prompt block, `SkillScope` |
| CLI tools | `TerminalPackage` + `CLILinkTrustStore` | package store | `run_command`, route resolver |
| MCP servers | `MCPServerConfig` (stdio command + `bundleIds`) | `mcp_servers.json` | `run_mcp_tool` |
| Shortcuts | `shortcutName` on actions | adapter JSON | `ShortcutRunner` |
| API connections | `APIConnectionStore` | Keychain + store | context only — **not callable** |
| Context readers | adapter `contextReaders` | adapter JSON | grounding blocks |
| Capabilities | `AICapability` | code | `run_capability` |

The Integrations page already *counts* all eight per app (the owner's screenshot: Safari — 2 app
actions, 3 browser actions, 2 skills, 2 CLI tools, 1 shortcut, 0 MCP, 0 API, 0 readers). What is
missing is not inventory. It is that **nothing declares how this app behaves as an agent**: which
of those tools it may use for what, in which order, what it must never do, and how it checks its
own work. That knowledge is spread across `ScopedAppPromptBuilder`, `FrontmostAppTaskPlan`,
`AppAdapterCapabilityCatalog` and a pile of per-app `if bundleId ==` branches — which is why
adding an app means editing DoraX rather than writing a file.

## The shape

One file per app, authored in Markdown, in the app's own folder:

```
~/Library/Application Support/Context-Dock/apps/com.apple.Safari/
  AGENT.md              ← the profile: identity, policy, tool allowlist, verification
  scripts/tabs-to-md.sh ← runnable, declared in AGENT.md, approval-gated
  skills/*.md           ← existing AdapterSkill bodies, on disk instead of in a store
```

`AGENT.md` front matter is data, its body is prompt:

```markdown
---
app: Safari
bundle_id: com.apple.Safari
summary: Browsing, tabs, page content, and the open page's links.
tools:
  capabilities: [browser.tabs, browser.currentPage, browser.history, browser.bookmarks]
  mcp: [safari-mcp]
  cli: []
  actions: [open-url, new-private-window]
  scripts: [tabs-to-md.sh]
never:
  - Close or quit the browser without being asked to
  - Read history when the question is about the page in front of the user
verify:
  tabs: browser.tabs
---

Prefer the extension's live page read over AppleScript: it sees the page the user is looking at…
```

Three properties make this worth doing, and each is a thing DoraX does badly today:

1. **Adding an app is writing a file**, not editing Swift. The per-app branches become data.
2. **The allowlist is declared, not inferred.** `FrontmostAppTaskPlan` currently guesses a tool
   set from verbs in the sentence; a profile states it, and the guess becomes the fallback for
   apps with no profile.
3. **Skills, scripts and MCP servers sit in one place per app**, so "what can DoraX do with
   Safari" has one answer a person can read and edit.

## Native Apple MCP — Safari

From the WebKit post, verified 2026-09-21:

- Ships with **Safari 27 beta / Safari Technology Preview 247+**.
- Started as a local process: `/usr/bin/safaridriver --mcp` — the same shape as
  `MCPServerConfig` already stores (command + args + stdio).
- Needs **Show features for web developers** *and* **Allow remote automation and external
  agents** in Safari's settings. Both are the user's to turn on; DoraX detects and links.
- 16 tools: `navigate_to_url`, `create_tab`, `close_tab`, `switch_tab`, `list_tabs`,
  `screenshot`, `get_page_content`, `page_info`, `page_interactions`, `evaluate_javascript`,
  `browser_console_messages`, `list_network_requests`, `get_network_request`,
  `set_viewport_size`, `set_emulated_media`, `browser_dialogs`, `wait_for_navigation`.
- Explicitly **no access to personal browsing data** (AutoFill and similar).

**The caveat that decides how we use it**: `safaridriver` drives automation sessions. Our existing
tab reading (Safari extension, AppleScript) sees the windows the user actually has open. So the
MCP server is a *second* Safari route, better at page interaction, evaluation, console and network
— and not a replacement for "what do I have open". The profile encodes exactly that, which is the
point of profiles.

## Phases

Each ships on its own commit, tests first.

**P1 — the profile format.** `AppAgentProfile`: parse, serialise, validate, defaults for an app
with no file. Pure, tested, reachable from nothing yet.

**P2 — native MCP catalogue.** `NativeMCPCatalog` with the Safari entry: how to detect the binary,
how to detect the two Safari settings, one-tap add into `MCPServerManager` linked to
`com.apple.Safari`, and an honest "needs Safari 27 / STP 247" when unavailable.

**P3 — the profile reaches the prompt.** `ScopedAppPromptBuilder` reads the profile's body and
allowlist; `FrontmostAppTaskPlan` prefers declared tools over inferred ones. Apps with no profile
behave exactly as today.

**P4 — scripts as declared tools.** `scripts/*.sh` run through the existing approval + `CD_*`
environment, listed as routes, never invented.

**P5 — authoring.** Settings → Integrations → app → **Agent** tab: read the profile, generate a
first draft from what is installed, edit, validate, revert. The Creator already does this shape
for plugins.

**P6 — packs.** Export/import a profile with its scripts and skills, so an app's setup is one
file to share. Folds into the existing adapter-pack import.

## Acceptance

- A Safari chat with `safari-mcp` added can evaluate JavaScript on a page and read its console,
  while "what do I have open" still answers from the live extension read.
- Writing `AGENT.md` for an app with no adapter at all changes how that app's chat behaves, with
  no Swift edited.
- An app with no profile answers exactly as it does today (the fallback is the current behaviour).
- The Integrations Overview counts profile-declared scripts and MCP servers alongside the rest.

## Not doing

- Replacing the AppleScript/extension Safari reads with MCP. They answer different questions.
- Auto-enabling Safari's remote-automation setting. It is a permission, so it is the user's tap.
- A profile that can grant itself capabilities the access policy denies. The profile narrows what
  is already permitted; it never widens it.
