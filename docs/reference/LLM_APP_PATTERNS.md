# LLM app patterns — reference notes for DoraX

Distilled from three sources the user supplied (July 2026):

1. *LangChain — Complete Notes* (study notes, Python, Part 1)
2. *Attention Is All You Need* — Vaswani et al., NIPS 2017
3. *RAG — Retrieval-Augmented Generation* (hand-written notes, pages 1–10)

The original PDFs/images were attached in chat, not committed — these notes carry the
parts that bear on DoraX's own AI stack, with the "so what for us" spelled out.

---

## 1. The composition model (LangChain, adapted)

LangChain's value is not its Python classes, it is the shape it forces:

| LangChain concept | DoraX equivalent today |
|---|---|
| `Runnable` — one interface every step implements | none; each surface hand-rolls its own call flow |
| LCEL `\|` composition | ad-hoc `await` chains inside `LauncherView+AIChat`, `+RemPanelChat` |
| Model-agnostic `init_chat_model("provider:model")` | `AIProviderRouter` / `AIProviderService` — we already have this |
| Prompt templates as first-class, versioned objects | `AITerminalPrompts`, inline string building at call sites |
| Output parsers (`StrOutputParser`, `PydanticOutputParser`) | manual string scraping + `parseL2AIResponse` |
| Structured output (`.with_structured_output(Schema)`) | tag-scraping (`[TERMINAL_COMMAND: …]`) — no provider-native schema use |
| `bind_tools()` | `sendWithTools(commandExecutor:)` |
| Retrievers | `GlobalSearchService`, `AppMenuCapabilityCache` (keyword/prefix, not embedding) |
| LangSmith tracing | `SearchPerformanceLog`, OSLog — no per-request LLM trace |

**We do not use LangChain and should not.** It is a Python framework; DoraX is a Swift
app that calls provider HTTP APIs directly. The parts worth borrowing are structural:

- **One typed request builder per surface, not per call site.** Prompt text assembled in
  a dozen places is why the same scope can get different instructions from two entry
  points (the `hom` / ghost-vs-icon class of bug, but for prompts).
- **Provider-native structured output** instead of tag scraping. Anthropic tool schemas
  and OpenAI JSON schema both validate server-side; `[TERMINAL_COMMAND: …]` parsing
  fails silently when the model reformats.
- **Prompt templates as data**, so a scope's system prompt can be diffed and A/B tested.

## 2. What the Transformer paper actually constrains

Practical consequences, not history:

- **Attention is O(n²·d) per layer** (Table 1). Every extra token of context costs
  quadratically at attention time — long, static preambles are not free even when they
  are cached, and they are *especially* not free on-device.
- **Context is a hard window, not a soft preference.** Foundation Models (on-device)
  has a small window; `LauncherView+AIChat.swift:4424` already trims history to 4 turns
  and uses minimal context to dodge "Exceeded model context window size". That trimming
  should be a budget, not a magic number.
- **Position matters.** Instructions the model must obey belong near the top (system) or
  the very end (immediately before the answer). Burying a rule in the middle of a 4 000
  character help dump is the weakest position available.

## 3. RAG — the parts we are missing

The notes' pipeline: **documents → clean → chunk → embed → vector store → retrieve
top-k → augment prompt → generate**, with "good ingestion = good retrieval = good
answers".

What DoraX has: a keyword/prefix index over apps, menu items, commands, and CLI help
(`GlobalSearchService`), plus MarkItDown for document ingestion. That is retrieval, but
lexical — it cannot match "free up disk space" to `mole clean` unless the words overlap.

What the notes prescribe that we do not have:

- **Chunking with overlap** (10–20% recommended) — our CLI help text is truncated with
  `String(prefix(4000))`, which is a hard cut mid-sentence, not chunking.
- **Embeddings + similarity search** for semantic matching over help text, menu items,
  and Quick Notes. Local, free option: `sentence-transformers/all-MiniLM-L6-v2` class
  models (384 dims) — on Apple silicon this is a Core ML / MLX job, no server.
- **Top-k, not top-everything.** "We don't send everything to the LLM (too much context
  = costly and slow)." Our scoped prompts send the whole help tree.
- **"Say I don't know."** Grounded-answer prompts should permit refusal; ours push the
  model to always produce a command.

Limitations the notes flag, which apply directly to us: quality depends on ingestion
quality (see the ANSI-escape help-scan bug — garbage in, garbage out, literally), and
retrieval failure produces confidently incomplete answers.

## 4. Prompt caching (not from these sources — DoraX gap, recorded here)

As of this note, `cache_control` appears nowhere in the codebase: every turn of a scoped
chat re-sends the full system prompt (capability inventory + CLI help tree + adapter
docs). For Anthropic that is the single highest-leverage cost/latency change available,
because the expensive part of our prompt is *static across turns of one scope*.

Preconditions to get right before implementing:
- cache breakpoints belong at the **end of the static prefix**, so the dynamic tail
  (user turn, tool results) sits after them;
- the prefix must be **byte-identical** between turns — today the prompt includes
  `currentDateTimeContextBlock()`, which changes every call and would defeat any cache;
- verify the current request/response shape against `docs/AI_PROVIDER_QA.md` and the
  live API docs before wiring it — do not implement from memory.

## 5. On-device (Apple Intelligence) rules of thumb

The on-device path is not "the same prompt, smaller model". From these sources plus what
the code already learned the hard way:

- Small window → **retrieve less, not truncate more**. Top-k semantic hits beat a
  4 000-character prefix cut.
- No server-side schema validation → structured output must be **parsed defensively**;
  prefer one value per turn over a JSON blob.
- Tool-calling loops need explicit, short tool lists. Long tool inventories crowd out
  the actual request.
- Silent stalls are real: the code already guards with a 30 s timeout and a fallback
  message (`LauncherView+AIChat.swift`, `ResumeOnceGuard`). Keep that pattern for every
  new on-device entry point.

---

## Applying this to DoraX — ordered by leverage

1. **Prompt caching for Anthropic** — static scope prefix cached, dynamic tail after it.
   Requires removing per-call date stamps from the cached region.
2. **Token budget instead of `prefix(4000)`** — one budgeter that ranks help sections by
   relevance to the query and fills a budget, per provider (tiny for on-device).
3. **Semantic retrieval over CLI help + menu items** — local embeddings, top-k, so
   "free up space" finds `mole clean` without lexical overlap.
4. **Provider-native structured output** for command generation, replacing
   `[TERMINAL_COMMAND: …]` scraping.
5. **One prompt builder per surface** — kill duplicate prompt assembly so General Chat,
   Context Dock chat, and CLI scope cannot drift apart.
