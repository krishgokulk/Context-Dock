# Agentic capability parity — every surface, every provider

**Date:** 2026-09-10
**Branch:** general-chat-agent
**Question that started it:** "Claude and Codex have skills, plugins and MCP for tools. What
does our app have? Why don't the providers answer intelligently?"

---

## 1. What DoraX already has

This matters before any plan: the parity is closer than it looks, and four of the pieces
people usually mean by "skills and plugins" are already built.

| Claude / Codex concept | DoraX equivalent | Where |
|---|---|---|
| Tools | 15 agent tools | `AI/AgentToolRegistry.swift` |
| Skill discovery (name + description first, body on demand) | `find_capability` / `run_capability` over a registry | `AI/AICapabilityRegistry.swift` |
| MCP servers | MCP runtime, per-app linked servers, 9 built-in Apple/GitHub families | `Services/MCPRuntime.swift`, `AI/Apple*MCPCapabilities.swift` |
| `SKILL.md` (YAML frontmatter + markdown) | `AdapterSkill` + `fromSkillMarkdown` importer | `Services/SkillStore.swift` |
| Plugins | App adapters: actions, CLI tools, API connections, Shortcuts, context readers | `Services/AppAdapterManager.swift` |
| Sub-agents | `spawn_worker` | `AI/AgentToolRegistry.swift` |

The registry design is already the right one, and its own comment says why:

> Registering them here makes them findable through `find_capability` and runnable through
> `run_capability`, so they cost nothing in the prompt until the model actually looks for
> them.

That *is* Claude's progressive disclosure. The gaps below are about what never got
registered, which surfaces never got asked, and one prompt path that bypasses the whole
mechanism.

---

## 2. The gaps, with evidence

### A. The browser could be read but never acted on — corrected 2026-09-10

**This entry originally said there was no browser capability family at all. That was wrong,
and the test suite proved it within minutes of the first commit attempt.** `browser.history`,
`browser.bookmarks`, `browser.tabs` and `browser.currentPage` have existed all along in
`AI/LocalDataCapabilities.swift`, and `SafariAdapterEvalTests` holds a deliberate line around
them: *every browser capability is a read*, because operating the browser goes through the
menu route where `AppMenuConsentStore` gates it. A draft of the new family added a page-script
capability at `.medium` risk and `noBrowserCapabilityWrites` failed it, exactly as designed.

The real gap was narrower and worth stating precisely:

- **No way to search the page.** `browser.currentPage` returned title, domain and the
  extension's text — no links, no fallback when the extension payload was stale, and
  compaction hardcoded to "summarize current page" rather than what was asked.
- **No way to open a link the page contains.** Reachable only through
  `isSafariPageLinkOpenQuery`, which knew three verbs.
- **`browser.tabs` could not be asked a question** — it listed up to sixty rows with no
  filter, so "which tab has the invoice" was answered by truncating first and matching
  after.

What remains true is the shape of the routing: which browser behaviour runs is still decided
by a Swift `if` on keywords *before the model speaks* — `isSafariPageLinkOpenQuery`,
`BrowserPageUnderstandingIntent.matches`, `BrowserActionAuthor.looksLikePageAction`. All three
of 2026-09-10's user-visible bugs were that shape:

| Symptom | Cause |
|---|---|
| "Couldn't run Page Summary Panel: JS error" | `execute JavaScript` — not Safari's verb; nothing ever ran |
| "doesn't contain links matching that request" | the page's one off-site link was anchor #76, cut by a 60 head-slice |
| "opening it requires navigation, which a page script may not do" | "launch" missing from a 3-verb list |

An agent with tools degrades gracefully — it looks again, tries another route. A classifier
fails absolutely, and every miss reads as the model being stupid.

### B. Open tabs never reach our own prompt

`dorax_browser_tabs` is exposed over MCP **to other agents**. DoraX's own turn gets page
title, URL, ≤5,000 compacted characters and 30 links (`AI/ScopedGroundingBlocks.swift:106`)
and no tab list at all. "Which tab has the invoice?" is unanswerable by any provider.

### C. Skills are app-scoped only

`AdapterSkill.adapterBundleId` is required. There is no skill for a *surface* — clipboard,
selection, Global Context, a CLI scope, General Chat — and no global skill. The surfaces the
user spends most time in are the ones no skill can describe.

### D. Two rival skill mechanisms, and the wrong one wins by default

`skills.list` / `skills.read` exist as capabilities (on demand, cheap). But
`SkillStore.instructionsBlock(for:)` pastes **every enabled skill body** into the scoped
prompt (`Search/LauncherView+AIChat.swift:5250`, `AI/AppScopedChatService.swift:1225`). So
the prompt-bloat path is the live one and the progressive one is decoration.

### E. No `SKILL.md` on disk

`fromSkillMarkdown` can parse a Claude-style skill, but there is no folder to drop one in, no
export, no file watcher, and no bundled skills. A user cannot hand DoraX a skill the way they
hand one to Claude Code, and DoraX ships with no written description of *itself*.

### F. Surfaces on the plain path get nothing

`PanelAssistant`, the extension panel composer and the sticky note call
`sendMessage` directly — no tools, no capabilities, no skills. The panel assistant added on
2026-09-10 inherits that.

### G. Tool-less providers are cut off entirely

`AIProvider.claudeCode.supportsNativeTools == false`, deliberately
(`App/AppSettings.swift:747`): "It answers; the app acts." Correct as a safety stance, but
there is no protocol for it to *ask* for what it needs, so for that provider the pre-pasted
block is the entire world.

---

## 3. The plan

Ordered by user-visible value. Each item ships on its own, with tests, and leaves the app
working.

### Todo 1 — Complete the browser family ✅ done 2026-09-10
Add the two that were missing — `browser.findInPage` and `browser.openURL` — and finish the
two that existed: a `matching` filter on `browser.tabs`, and links, an AX fallback and
query-aware compaction on `browser.currentPage`. Page scripts stay with `BrowserActionAuthor`,
which shows the script and keeps it; the read-only contract is not touched.
**Done when:** a provider can answer "which tab has X", "does this page link to GitHub" and
"open the docs link" through capabilities, with the classifiers still answering the common
phrasings on the fast path. *(Shipped; `browser.page_action` deliberately not built.)*

### Todo 2 — Tabs and page state in the grounding block
Add the open-tab list (title + URL + which is active) to the browser block, capped and
labelled. Add a receipt for every browser read, the way command runs get receipts.
**Done when:** `BrowserPageReadEvidence` covers tabs, and a question about another tab is
answerable by a provider with no tools at all.

### Todo 3 — Skill scope: app, surface, or global
Extend `AdapterSkill` with a scope (`app(bundleId)` / `surface(id)` / `global`), defaulting
existing skills to `.app` so nothing breaks. Teach each surface to read its own.
**Done when:** a skill written for "clipboard" steers the clipboard scope and nothing else,
and the Integrations UI can show it.

### Todo 4 — `SKILL.md` on disk, and DoraX's own skills
`~/Library/Application Support/Context-Dock/skills/<name>/SKILL.md`, watched for changes,
importable and exportable, using the existing parser. Ship starter skills — one per surface —
that describe what that surface is, what it can do and what it must not do: Global Context,
CLI tool scope, clipboard scope, corner Context Dock chat, General Chat, selection scope, app
adapters.
**Done when:** dropping a `SKILL.md` in the folder makes it available with no relaunch, and
`skills.list` shows DoraX's own seven.

### Todo 5 — Progressive disclosure by default
The prompt carries skill **names and summaries**; bodies arrive through `skills.read`. Keep
whole-body injection only for a skill the user has pinned, and only within its scope.
**Done when:** the scoped prompt is measurably smaller with several skills enabled, and a
turn that needs a body fetches it.

### Todo 6 — Plain-path surfaces adopt capabilities
`PanelAssistant`, the extension composer and the sticky note run through the tool path with a
narrow allow-list (their own panel's readers plus `skills.read`).
**Done when:** asking Currency Converter's assistant something it needs a reader for gets an
answer rather than a refusal.

### Todo 7 — A protocol for tool-less providers
Let a tool-less provider answer with a structured "I need X" (a capability id and input) that
the app fulfils and re-asks with. Keeps "it answers, the app acts" while ending the one-shot
blindness.
**Done when:** Claude Subscription can answer a two-hop question that today fails.

### Todo 8 — Surface capability contract tests
One test per surface asserting which capability families it exposes, so a surface cannot
quietly lose its tools again.
**Done when:** the suite fails if Global Context, CLI scope, clipboard, corner chat, General
Chat, selection or an app adapter stops offering its expected families.

---

## 4. Sequencing note

`CLAUDE.md` has the worker layer next in its own sequence, with pinning deferred. This plan
is a second track and does not replace it. Todos 1 and 2 are the ones the user has actually
been hitting all week; the rest are the parity work.
