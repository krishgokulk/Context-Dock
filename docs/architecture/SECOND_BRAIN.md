# Second Brain

The memory layer: what DoraX writes down, where it lives, and what still has to be
built. Written after building steps 1–6 below, so the "done" half describes code that
is in the app rather than a plan for it.

## The shape of it

DoraX is not the Obsidian pattern and should not become it.

That pattern builds a **retrospective** brain: the user writes notes, a model reads
them. Storage first. Its own weakness is that static notes are half a brain.

DoraX is a **live** brain: it already sees the frontmost app, the selection, the menu
tree, the Finder selection, and it can act on them. Perception first. Its weakness was
the mirror image — it forgot everything the moment a thread closed.

So the memory layer is not a notes app bolted on. It is the durable half of a thing
that already perceives, and its job is to stop the perceiving half starting cold.

## What exists

All of this is plain markdown, on disk, readable and editable outside the app.

```
<vault>/
  MEMORY.md      index; the model reads this to know what memory contains
  profile.md     who the user is — injected into every turn, ungated
  preferences.md  people.md  projects.md  tasks.md   facts, written on purpose
  observed.md    sentences the user wrote, copied verbatim, never summarised
  notes/         Quick Notes, mirrored, linked to the apps and folders they name
  daily/         what actually ran each day, from task-run receipts
  apps/          per-app memory, keyed by bundle id
  cache/         mirrors of external data; never a source of truth
```

**Location is the user's.** Defaults to Application Support and moves anywhere from
Settings. Plain text nobody can find is not plain text they own — and a vault in a real
folder is one Obsidian can open, which is the whole point of not rebuilding Obsidian.

**The profile is not memory evidence.** It goes in on every path and is gated on
nothing. The rule that withholds remembered facts from questions needing a fresh read
is about evidence; identity is not evidence about the world. It has its own prompt slot
because `.memory` is replaced wholesale and is droppable under budget, and identity is
neither.

**Retrieval** matches whole words with counted repeats and diminishing returns, ranks
whole sections rather than matching lines, and breaks ties on recency. Substring
matching is what made "who am I" return a note about code.

**Distillation runs no model.** A summary is generated text, and generated text about a
person is where an invented detail does the most damage: a wrong fact is not one bad
answer, it is a bad premise under every future answer, in a file nobody re-reads. So it
copies the user's own sentences verbatim when they match first-person openings, and
writes them to `observed.md` — kept apart from facts typed on purpose, so the automatic
ones can be discarded without losing the deliberate ones.

**The daily pass** rebuilds today's brief and finishes yesterday's, and re-syncs the
note mirror. It is a date check, not a 07:00 timer: a Mac is usually asleep at 7am and a
timer that missed its slot never fires at all.

## Rules this layer keeps

- **Receipts over claims.** The daily brief is built from commands that ran and their
  exit status, never from a model's account of the session.
- **Say what is actually known.** An MCP server DoraX has never dialled is "Configured",
  not "Connected". A count of what ran is not a count of what is remembered.
- **Keys, not prompts.** Scope is enforced in code — consent stores, a bearer token on
  the MCP server, a vault path the writer cannot escape. Never asked for in a system
  prompt.
- **One job per surface.** Memory is a layer the existing surfaces write into. Quick
  Note captures, chat distills, the dashboard views. It never becomes a seventh surface.

## What is left

1. **Nothing reviews memory.** No decay, no dedupe across files, no way to correct a
   fact except editing the file. Measured at the time of writing: 14 bullets, zero
   duplicates — so this is not yet a real problem, and building the hygiene pass now
   would be solving a number rather than a symptom. Revisit when the count climbs;
   `observed.md` is what will push it.
2. **Distillation is narrow on purpose.** It fires once a day, looks back two days, and
   only matches a short list of first-person openings. It will miss things rather than
   guess. Widening the patterns is a one-line change; do it from evidence that it is too
   quiet, not from a hunch.
3. **The mirror is one-directional.** Editing a note's markdown in Obsidian does not come
   back into Quick Note. The JSON stays the record the editor writes, because two writers
   over one document is how notes get lost — but this means external edits are silently
   overwritten on the next sync.
4. **The graph is only as connected as the linking.** Notes link apps and folders they
   name; conversations link the scope they were given. Most conversations are never
   scoped, so they never join the graph. The lever is making scoping easier, not making
   the graph look busier.
5. **No retrieval evaluation for memory.** The Settings panel of that name measures a
   different subsystem. The ranking changes here were verified by hand against the real
   vault; there is no harness that would catch a regression.

## Files

| Area | File |
|---|---|
| Vault, retrieval, facts | `Services/MarkdownMemoryStore.swift` |
| Profile model | `Services/BrainProfile.swift` |
| Quick Note → markdown | `Services/QuickNoteMemoryMirror.swift` |
| Receipts → daily brief | `Services/DailyBrief.swift` |
| Conversations → observed facts | `Services/ConversationDistiller.swift` |
| Daily pass | `Services/BrainMaintenance.swift` |
| Dashboard view onto it | `Services/DashboardMetrics.swift`, `UI/Dashboard/` |
| Profile + vault UI | `UI/Settings/BrainProfileCard.swift` |
