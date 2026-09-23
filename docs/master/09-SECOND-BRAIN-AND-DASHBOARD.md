# 09 — Second Brain (memory) + Dashboard / Knowledge Graph

> **Status: DRAFT / under review — written against current code + `docs/architecture/SECOND_BRAIN.md`.** Not merged yet.
> Tags: `[code]` verified in source · `[owner]` owner's stated knowledge · `[?]` needs confirmation.

---

## 1. What it is

DoraX is a **live** brain (it perceives the frontmost app, selection, menus, Finder), and the
memory layer is its **durable half** — so the perceiving half stops starting cold each time a
thread closes. It is deliberately **not** the Obsidian/retrospective-notes pattern. `[code — SECOND_BRAIN.md]`

---

## 2. The vault (what's written, where) `[code — MarkdownMemoryStore.swift]`

Plain markdown on disk, editable outside the app; location defaults to Application Support and
is user-movable.

```
<vault>/
  MEMORY.md       index the model reads to know what memory holds
  profile.md      who the user is — injected every turn, ungated
  preferences.md people.md projects.md tasks.md   facts written on purpose
  observed.md     the user's own sentences, copied verbatim, never summarised
  notes/          Quick Notes, mirrored, linked to apps/folders they name
  daily/          what actually ran each day, from task-run receipts
  apps/           per-app memory, keyed by bundle id
  cache/          mirrors of external data; never a source of truth
```

## 3. How it behaves `[code]`

- **Profile ≠ evidence.** `profile.md` (identity) is injected on every path, ungated. The rule
  that withholds remembered facts from questions needing a fresh read applies to *evidence*,
  not identity.
- **Retrieval** matches whole words with counted repeats + diminishing returns, ranks whole
  sections, breaks ties on recency (substring matching was what returned a code note for "who
  am I").
- **Distillation runs no model** — `ConversationDistiller` copies the user's own first-person
  sentences verbatim into `observed.md`, kept apart from deliberately-typed facts, so automatic
  captures can be discarded without losing intentional ones. (Generated summaries about a
  person are where an invented fact does the most damage.)
- **Daily pass** (`BrainMaintenance`, `DailyBrief`) rebuilds today's brief from **receipts**
  (commands that ran + exit status), finishes yesterday's, re-syncs the note mirror. It's a
  date check, not a 07:00 timer (a Mac is asleep then).

## 4. Rules this layer keeps `[code — SECOND_BRAIN.md]`

- **Receipts over claims** — the brief is built from what ran, not the model's account.
- **Say what's known** — an undialled MCP server is "Configured", not "Connected".
- **Keys, not prompts** — scope is enforced in code (consent stores, bearer token, a vault path
  the writer can't escape), never asked for in a system prompt.
- **One job per surface** — memory is a layer existing surfaces write into (Quick Note captures,
  chat distills, dashboard views). It never becomes a seventh surface.

---

## 5. Dashboard + Knowledge Graph (the view onto it)

`[code — Services/DashboardMetrics.swift, UI/Dashboard/]`
- **`DashboardMetrics`** reads numbers **back out of stores that already hold them** — every
  tile/node/edge traces to a session index, a task-run file, or a route record. An empty store
  says so rather than showing a plausible shape. (No invented numbers.)
- **`KnowledgeGraphView`** draws conversations against the apps/folders/tools they touched;
  **edges are real scope links, not similarity/inference.** Layout is a seeded force simulation,
  cached per size, so the same graph draws the same way each open.
- **`WorkflowFlowView`**, `DashboardPane`, `DashboardPalette` — the rest of the dashboard.

> Honest naming: this is the only place the word "graph" is literal, and it is a
> **visualization**, not a reasoning engine (see `08` §"no capability graph").

---

## 6. Engineering map `[code — SECOND_BRAIN.md]`

| Area | File |
|---|---|
| Vault, retrieval, facts | `Services/MarkdownMemoryStore.swift` |
| Profile model | `Services/BrainProfile.swift` |
| Quick Note → markdown | `Services/QuickNoteMemoryMirror.swift` |
| Receipts → daily brief | `Services/DailyBrief.swift` |
| Conversations → observed facts | `Services/ConversationDistiller.swift` |
| Daily pass | `Services/BrainMaintenance.swift` |
| Dashboard / graph | `Services/DashboardMetrics.swift`, `UI/Dashboard/*` |
| Profile + vault UI | `UI/Settings/BrainProfileCard.swift`, `UI/Settings/DataStorageSettingsPage.swift` |

---

## 7. Known gaps / open questions (from `SECOND_BRAIN.md` "what is left", verified)

1. **Nothing reviews memory** — no decay, no cross-file dedupe, correction = edit the file.
   Deferred deliberately (measured: 14 bullets, 0 dupes); revisit when `observed.md` grows. `[code]`
2. **Distillation is narrow on purpose** — once daily, 2-day lookback, short first-person
   pattern list; widen from evidence it's too quiet, not a hunch. `[code]`
3. **Mirror is one-directional** — editing a note in Obsidian is overwritten on next sync
   (JSON stays the record). External edits are silently lost. `[code] [risk]`
4. **The graph is only as connected as scoping** — most conversations are never scoped, so they
   never join the graph. Lever: make scoping easier, not the graph busier. `[code]`
5. **No memory retrieval eval** — ranking was verified by hand against the real vault; no
   harness would catch a regression. (Same eval gap as the rest of the app — `08` §14 #1.) `[gap]`

---

*End of draft. Redline directly; merges after owner confirmation.*
