# Safari in DoraX, as it actually is

Written 2026-09-22 by reading the code and driving the running app. Every claim here was checked;
where something is unverified it says so.

This is the "before" picture for the Safari plan. It exists because the question *"how does Safari
work in our app"* currently has no single answer — there are **four** independent ways DoraX
touches Safari, built at different times, and nothing states which is used when.

---

## The four routes

### 1. The Safari extension — what the user is looking at

`Context-DockExtension/` — a Safari Web Extension: `manifest.json` (permissions `nativeMessaging`,
`activeTab`, `tabs`, `scripting`; hosts `http://*/*`, `https://*/*`), a content script (234 lines)
and a background service worker (179 lines).

**How it reaches the app**: not a socket and not native messaging in the live sense — the handler
(`SafariWebExtensionHandler.swift`) writes the decoded payload into an **App Group file**, and the
app reads it. Commands going the other way are *queued* by the app and **pulled** by the extension
when it next asks, then deleted on read so a command never runs twice; stale commands are dropped
rather than run late.

- **Gives**: the current page's URL, its text, its links, a trigger label.
- **Costs**: nothing per turn — the page was already parsed in the browser.
- **Weakness**: it is a mailbox, not a phone call. The app cannot ask "read this page *now*" and
  wait; it reads whatever the extension last left, or falls back to route 2.

### 2. AppleScript — tabs, and JavaScript when necessary

`SafariTabManager` (tabs, switching, opening), `SafariBrowserBridge`, `SafariCommandBridge`,
`SafariLinkResolver`, `SafariRecentURLService`.

Tabs are read with `NSAppleScript`; JavaScript is evaluated by writing the JS to a temp file and
having AppleScript `cat` it in, which is how a long script survives quoting.

- **Gives**: every window and tab, titles and URLs, tab switching, page JS.
- **Costs**: an Apple Event per read, Automation permission, and it launches Safari if it is not
  running (which is why some readers refuse when Safari is closed).
- **Weakness**: slow, permission-gated, and JS through AppleScript is fragile.

### 3. Capabilities — the registry's browser tools

| id | what it does | where |
|---|---|---|
| `browser.tabs` | open tabs | `LocalDataCapabilities` |
| `browser.currentPage` | the page in front of you | `LocalDataCapabilities` |
| `browser.history` | history | `LocalDataCapabilities` |
| `browser.bookmarks` | bookmarks | `LocalDataCapabilities` |
| `browser.findInPage` | find | `BrowserCapabilities` |
| `browser.openURL` | open a URL | `BrowserCapabilities` |
| `safari.summarizePage` | summarise the page | `AICapabilityRegistry` |
| `safari.bridge.summarize`, `safari.exportPDF` | routed by `SafariCapabilityRouter` | |

These are what a chat's tools and the route resolver actually reach for. They sit on top of routes
1 and 2 — a capability is the front door; the extension or AppleScript is what is behind it.

### 4. Apple's MCP server — new, and live on this Mac

`safaridriver --mcp`, added this week as a `NativeMCPCatalog` entry.

**Verified on this machine**: macOS 27.0, Safari 27.0, and `safaridriver --help` lists
`--mcp   Run as an MCP (Model Context Protocol) server using stdio`. So this is not a
future-version feature here — it runs today.

`MCPRuntime` connects lazily per bundle id, lists the server's tools, and publishes them **both**
ways: as tool schemas for providers that take them, and as a prose `{"mcp_call": …}` block for
providers that do not. So Claude Code and Apple Intelligence reach the same 16 tools.

- **Gives**: `navigate_to_url`, `create_tab`, `close_tab`, `switch_tab`, `list_tabs`, `screenshot`,
  `get_page_content`, `page_info`, `page_interactions`, `evaluate_javascript`,
  `browser_console_messages`, `list_network_requests`, `get_network_request`, `set_viewport_size`,
  `set_emulated_media`, `browser_dialogs`, `wait_for_navigation`.
- **Needs**: Safari → Settings → Advanced → *Show features for web developers*, and
  Settings → Developer → *Allow remote automation and external agents*.
- **Weakness, and it is the important one**: it drives an **automation session**. It is the right
  tool for acting on a page and the wrong one for "what do I have open", which belongs to route 1.

---

## What grounds a Safari chat today

From `ScopedGroundingBlocks`:

- **Page text** — compacted toward the question, `limit: 5_000` characters.
- **Open tabs** — `formatTabs(limit: 40)`, the active tab marked.
- Whole-turn ceiling from `AIContextBudget`: **1 500** characters on-device, **4 000** local,
  **12 000** cloud.

**Nothing is cached between turns.** Three questions about one page extract, compact and send that
page three times.

---

## What I verified by driving the app

Through `dorax_ask` (which runs unattended — every approval refused, nothing written):

| Asked | Result |
|---|---|
| "what is the current page about?" | Correct: read the live page |
| "list all my open tabs with their URLs" | Correct: all 15 tabs, titles + URLs |
| "what does the page I am looking at say?" | Correct, **and no screenshot** after the profile's read-order was written |
| "save all my open tab links into a new note" | Correctly refused: offered to enable Notes, wrote nothing |
| "run the tabs-to-md.sh script" | Before the fix: searched the file system. After: reaches the declared-script path |

## Defects found on the way, now fixed

1. **A Safari chat asked the user to enable Safari** — the MCP server's app-name lookup fell
   through to `.app(bundleId: "Safari")`, a display name where the rest of the code expects an id,
   and the access gate then read Safari as a different app from Safari.
2. **`dorax_browser_tabs` answered "No Safari tabs cached. Safari may not be running"** while
   Safari was running with 15 tabs — the MCP tool reads a cache that nothing had warmed. *Still
   open* (see below).
3. **Steps came back empty** from the tool whose purpose is showing what DoraX did.
4. **"Claude Code worked with its own tools"** printed under an answer full of live Safari data.

## Still wrong today

- **`dorax_browser_tabs` reads a cold cache** and says Safari may not be running when it is. The
  chat path reads tabs correctly; the MCP tool does not share that path.
- **No page memory.** Cost and latency scale with how many questions you ask about one page.
- **Four routes, no stated order.** Which one answers a given question is currently decided by
  whichever layer happens to match first, not by a rule. (A per-app `AGENT.md` can now state it —
  Safari's does — but that is one user's file, not the app's behaviour.)
- **The MCP server is added but unproven in a real turn.** It connects lazily; no test has yet
  asked a Safari chat to evaluate JavaScript or read the console.
- **No sensitive-page rule.** Nothing stops a page read on a banking page or a URL carrying a
  token. Today that matters less because reading is passive; it matters a great deal the moment
  navigation and interaction are turned on.
- **The extension is a mailbox.** No request/response, so "read this page now" cannot be awaited.

---

## What "perfect" means for Safari

In the order a question should be answered, and with the boundary each route keeps:

```
   Is this about what I have open, or the page in front of me?
        → the EXTENSION (free, live, sees the user's real windows)
   Is it about this page's content, and the extension has nothing fresh?
        → AppleScript page read, compacted, cached by content hash
   Is it acting on a page — click, type, evaluate, navigate, console, network?
        → SAFARI MCP, gated per host, script shown every time
   Is it about history or bookmarks?
        → the capability, never the automation session
   Everything else
        → refuse specifically, and say which of the above would have answered it
```

Plus: a page is read **once per version**, follow-ups reuse a stored summary, sensitive pages are
refused by rule rather than by judgement, and page text is treated as data — never as
instructions — now that the model can act on what it reads.

The phases that get there, and the token arithmetic behind them, are in
`docs/superpowers/plans/2026-09-22-safari-power-and-page-tokens.md`.
