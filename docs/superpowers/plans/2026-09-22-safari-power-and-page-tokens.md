# Safari, in full — and what a page should cost

Written 2026-09-22. Two requests that are really one: *"how do I save tokens for a Safari page"*
and *"I want full Safari power in the frontmost app chat — MCP, extension, navigation, browse-use
like, everything except sensitive pages, safety first"*. The second is only affordable if the
first is solved, so it comes first.

## Before this: what Safari does today

`docs/architecture/SAFARI_TODAY.md` is the audit — four routes (extension, AppleScript,
capabilities, Apple's MCP server), what each is good at, what was verified by driving the app, and
what is still wrong. Two facts from it shape everything below:

1. **`safaridriver --mcp` runs on this Mac.** Safari 27.0, and the flag is in `--help`. The MCP
   route is not a future-version feature here.
2. **Nothing remembers a page.** Three questions about one page pay three full reads.

## Where a page's tokens go today

| | Now | Per turn |
|---|---|---|
| Page text | `MarkItDownService.compact(pageText, for: query, limit: 5_000)` in `ScopedGroundingBlocks` | up to ~5 000 chars |
| Open tabs | `formatTabs(limit: 40)` | ~40 lines |
| Whole-turn ceiling | `AIContextBudget.characterBudget` — 1 500 on-device, 4 000 local, 12 000 cloud | |

So compaction exists and is query-relevant. What does **not** exist is memory: ask three
questions about the same page and the same 5 000 characters are extracted, compacted and sent
three times. That is the waste worth removing, and it is also the latency.

### P1 — A page is read once per version

`BrowserPageCache`, keyed by `URL + SHA-256 of the extracted text`:

- **Extract once.** The reader runs, the text is hashed, and the compaction for *this* question is
  derived from the cached extraction rather than a fresh read.
- **A second question about the same page costs nothing to read.** Same URL, same hash → the
  cached extraction. Different hash → the page changed, re-read, and the answer says so.
- **Keep a rolling summary.** After the first turn on a page, store the model's own summary. Turn
  two sends *the summary plus the passage the new question matches*, not the page again. A
  follow-up question is then a fraction of the first.
- **Evict by URL count and age** (say 20 pages, 30 minutes) so this never becomes a shadow history
  of browsing.

Expected effect: the second and later questions about one page drop to roughly the cost of the
question, and the first is unchanged.

### P2 — Spend by question shape, not by fixed limit

"What is this page about" needs the top of the document. "What does it say about pricing" needs
the matching passages. "List the links" needs no prose at all — it needs the anchors.
`PageReadIntent` classifies the question and picks:

| Question shape | Sent |
|---|---|
| summarise / what is this | title + headings + first ~1 200 chars |
| about X | the passages matching X, ±2 paragraphs |
| links / tabs | structured rows only, no body text |
| forms / state | the DOM query result, via MCP |

This is the same idea `AIContextBudget.fitHelpText` already applies to CLI help, moved to pages.

---

## Full Safari power, safely

Three routes exist and answer different questions. The profile (`AGENT.md`) is where the order is
written down; the code enforces the boundaries.

| Route | Good at | Not for |
|---|---|---|
| **Extension read** | the page the user is looking at, their real tabs | acting |
| **Safari MCP** (`safaridriver --mcp`) | evaluating JS, console, network, DOM, interaction, navigation | "what do I have open" |
| **AppleScript / menus** | last resort | anything the other two do |

### P3 — Navigation and interaction, gated

`navigate_to_url`, `create_tab`, `switch_tab`, `page_interactions`, `evaluate_javascript` come
free with the MCP server. What they need from us is a gate, because "the model may navigate the
browser" is the sentence a prompt-injection attack wants to be true:

1. **A page's text is data, never instructions.** Already the rule; it becomes load-bearing the
   moment the model can act on what it reads. The page block stays evidence-shaped, and any
   instruction found inside it is reported, not followed.
2. **Navigation is approved per destination** the first time a host is visited in a conversation,
   then free within that host for that conversation. The card names the host.
3. **`evaluate_javascript` is approved every time**, showing the script. It is the widest tool in
   the set.
4. **A sensitive page is never read or driven.** `SensitivePageGuard`: banking and payment hosts,
   anything with a password field focused, anything whose URL carries a token or `?code=`,
   plus the user's own denylist. Refusal names the reason without quoting the page.
5. **No form submission, no purchase, no credential entry.** Ever, by any route. The existing
   outbound denylist extended to page actions.

### P4 — Quick Note and the knowledge graph as first-class sinks

DoraX already has both, and neither is wired into browsing:

- **"Save this to Quick Note"** — the page's title, URL and the passage that answered the
  question, as a note, through the existing capability with its approval.
- **"What do I know about this?"** — before answering from the page, ask the local graph. A page
  about a topic the user has fifty notes on should be answered with both, and the answer should
  say which came from where.
- **Reading a page adds to the graph** (title, URL, entities, the question asked) so the next
  question about the same subject is cheaper and better. Local only, and clearable.

### P5 — Every provider, including on-device

The MCP tools are reachable from the tool loop *and* from the prose directive path
(`{"mcp_call": …}`), so Claude Code and Apple Intelligence get the same reach. On-device gets the
1 500-character budget and the summary-first strategy from P2, which is what makes a small model
usable on a large page at all.

---

## Acceptance

- Three questions about one page cost roughly one page read, and the app says which turn re-read.
- "Summarise this" on a 200 KB page sends ~1 200 characters, not 5 000.
- A Safari chat can navigate, click and evaluate — each gated as above — and a banking page
  refuses all three with a reason.
- "Save this to my notes" works from a Safari chat through the approval card, with the page's URL
  and the relevant passage.
- On-device answers a page question without exceeding its window.

## Not doing

- Driving other browsers through this. Chromium needs CDP and is its own plan (#18).
- Logged-in actions on the user's behalf beyond navigation — no posting, no buying, no sending.
- Storing page text beyond the cache window. The graph keeps facts and links, not page dumps.
