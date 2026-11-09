# The frontmost App Pet

One shared DoraX harness, focused through the app in front of you, that carries out what you asked
using the capabilities you granted—and never by clicking a menu to find something out. **App Pet**
is the product identity; it is not a permanent model process per app. Detailed target behavior:
[App Pets, Global Context and Combined Chat](../superpowers/specs/2026-10-27-app-pets-combined-chat-design.md).

This is Gate B. Gate A closed on 21 Aug: every capability has an owner, an authority class,
a canonical executor and a verification state. What follows is only possible because of
that, and stays honest only because of that.

---

## 1. What is already true

Do not rebuild these.

| Piece | Where | State |
|---|---|---|
| One executor for every route | `GeneralAIActionExecutor` | Gate A, done |
| Approval as a value, not an assumption | `ExecutionApproval` | done |
| Authority per route class | `AppAccessPolicy` / `AppAccessLevel` | done |
| Typed verification, incl. *contradicted* | `VerificationStatus` | done |
| What the app is, learned from the app | `AppKnowledgeSkill` | done |
| Granted capabilities outrank installed ones | `matchOutranks` | done |
| What is in scope, counted, one source | `ScopeInventory` | done |
| A read-back ends the question | `verifiedByReadBack` | done |

The agent's job is to *use* this inventory well. Nearly every failure so far has been the
model being handed the wrong thing before it could think, not the model thinking badly.

---

## 2. The defect that blocks everything else

Asked **"is this page related to our contextdock project in any ways you think?"** — a
question — a Safari thread answered:

> I found an enabled Safari tool for this task. Run it?
> **Run Open Social** · Safari · app capability · `globalcmd.open-social`

`offerScopedNativeAppAction` decides whether to offer an action, and its whole gate is:

```swift
guard !scopedRegistered.isEmpty
    || GeneralAIActionResolver.shared.looksExecutable(query)
else { return false }
```

A capability whose keywords overlap the sentence is enough. **Nothing asks whether the
sentence is a question.** The guard for exactly this exists — §9c built `asksOnly`, and
`requestsChange` with whole-word matching — and it is on the General AI path, not this one.

This is the same shape as the four dock gates that each answered "is there anything here"
differently, and as the approval gate copy-pasted into four callers. A rule that lives in
one caller is not a rule.

**Step 0, before any agent work: `offerScopedNativeAppAction` asks intent first.** A
question is answered, never offered as an action. Small, testable, and it removes the most
visible way the assistant looks stupid.

**Task 17 (2026-09-29): exact command or the model.** Asking intent first was not enough —
"find my passport pdf" is an instruction, and word overlap still turned it into
`Use Find My · Edit → Copy`. `offerScopedNativeAppAction` now offers a native action only
when the sentence IS the command (`ExactCommand`: normalized equality with a menu title, an
adapter action name or trigger, or a quoted / menu-path name; a trailing number is the
command's value). Everything else is declined to the model, with the scoped app's
partly-matching commands in the prompt as `run_menu_command` / `run_capability` candidates.
The decision is `ScopedRoutePolicy.decide`; `RoutingPhrasebookTests` holds the owner's
sentences and where each must land.

---

## 2a. The graph, end to end

```
user input
  → understand            question or instruction?        asksOnly / requestsChange
  → scope                 which app is this about?        named app > frontmost > none
  → candidates            that app's tools, ranked        CapabilityIndex(scopedTo:)
  → decide                act · ask · answer              CapabilityDecision
  → plan                  typed steps, chosen by id       ChatPlanRunner
  → execute               with authority and approval     GeneralAIActionExecutor
  → verify                typed read-back where one exists
  → report                what ran, what was observed
```

**The scope step is a preference, not a filter**, and this is the part worth being careful
about. "Choose the app, then use that app's tools" is how people think and is right most of
the time — but choosing the app first is exactly where `find my bookmarks note` went to Find
My. A hard filter on a wrong app leaves nothing to recover with: every later step is then
confidently wrong, and the user sees an assistant that has understood nothing.

So the app in scope is a weight. Scoped to Code, "new window" resolves to Code's; "empty the
trash" still finds Finder's, because the sentence names it plainly. Machine-wide commands
belong to no app and are never demoted for it.

The recovery matters more than the precision here. Being slightly worse at the common case
buys being able to survive the case where the first decision was wrong.

## 3. What "agentic" means here

Not a free-running loop. One turn is:

```
understand → plan over the inventory → act with authority → verify → report
```

- **understand** — is this a question, an instruction, or an instruction with a question
  inside it? `asksOnly` / `requestsChange` decide, and the answer is carried, not re-derived.
- **plan** — the model chooses from a *typed catalogue* by id. `ChatPlanRunner.plan` already
  works this way and states the safety property: "a plan can only contain capabilities that
  already resolved as real, so a hallucinated step becomes a rejected id rather than an
  attempted action." Extend it, do not replace it.
- **act** — `GeneralAIActionExecutor` with a stated `ExecutionApproval`. No new execution
  path, ever.
- **verify** — a typed read-back where one exists; `contradicted` is a result, not a doubt.
- **report** — what ran, what it observed, what it could not confirm.

The loop is bounded by steps, not by time, and every step is an executor call that already
has authority and approval. There is no state in which the agent is running and the user
cannot see what it did.

---

## 4. Steps

**Step 0 — intent before offers.** As above. Guards `offerScopedNativeAppAction` with
`asksOnly`. Tests: the exact sentence from the report, plus a genuine instruction that must
still be offered.

**Step 0.5 — uncertainty is a question, not a guess.**

An agent that cannot tell asks. DoraX has the machinery —
`GeneralAIActionResolution.clarify(question:options:)`, `PendingClarification` holding the
original query for two minutes, a renderer, and `shouldClarifyBetweenPeers`, which already
states the honest test: candidates of the same semantic type within 0.05 confidence of each
other are a tie, and a tie is a question.

It is invoked at six sites by hand, so a seventh path that is uncertain guesses instead.
Every failure reported today was a guess that could have been a question:

| Typed | Guessed | Should have asked |
|---|---|---|
| `find my bookmarks note` | browser bookmarks | the note called bookmarks, or your bookmarks? |
| `is this page related to our project?` | offered Run Open Social | nothing — it is a question |
| `turn on dark mode` | reported the value | act, or ask which — never report instead |

Make it the rule rather than a call: one place decides whether the top candidates are
separated enough to act on, and everything that resolves goes through it. The bar is not
"is DoraX confident" — it is **"would a wrong choice here cost the user something they
cannot undo in one step"**. A read that picks the wrong list wastes a sentence. A write that
picks the wrong target does not.

Two things this must not become: a prompt on every request, which is worse than guessing,
and a way to avoid doing the work — `find my bookmarks note` has a right answer and asking
would be a cop-out. Ask when the sentence is genuinely two-ways, not when reading it is
merely hard.

**Step 1 — one index, one ranker, one decision.** The big one, and the answer to "we have
adapters for every installed app, so why is it not intelligent?"

*What went wrong.* The capability layer was built as a set of small routers, each owning
both **matching** and **answering** for its own corner. There are at least six, and they do
not share a line of code:

| Matcher | Matches by |
|---|---|
| `AppAdapterCapabilityCatalog.registeredCandidates` | token-set intersection |
| `ReadOnlyDataRouter.domain(for:)` | keyword list, now phrase-then-position |
| `GlobalCommandCapabilities.matchingCommands` | its own score |
| `ChatRouteResolver.routes` | its own kind ranking |
| `GeneralAIActionResolver.resolveTargetApp` | app names by position and authority |
| `AppleLiveDataContext` | `if q.contains("note")` and friends |

Every failure reported today is one of these disagreeing with another, or none of them
firing:

- `find my bookmarks note` — the domain router said notes and `readOnlyCapabilityAnswer`
  had no notes case, so the request asked for permission and then did nothing.
- `is this page related to our project?` — the adapter catalogue's token overlap said Open
  Social; nothing asked whether the sentence was a question.
- `turn on dark mode` — the Global Command matched, and the executor read the value.

The adapters are not the problem. They hold real capability — actions, CLI tools, MCP
servers, skills, menu commands — for every app the user added. **Nothing indexes them.**
Each matcher looks at its own slice, with its own scoring, and there is no function
anywhere that answers "given this sentence, what are the best things I can do about it?"

*The shape that fixes it.*

```
request
  → CapabilityIndex.search(query, scope)   → [(capability, score)]   one index, one ranking
  → Decision.make(topK)                    → act | ask | answer
  → ChatPlanRunner.plan(from: topK)        → typed steps chosen by id
  → GeneralAIActionExecutor.execute        → the Gate A executor, unchanged
  → verify → record which capability answered
```

**The index.** One record per capability, from every source that has them: adapter actions,
linked CLI tools, MCP tools, skills, Global Commands, cached menu commands, and the Apple
app readers. Fields: id, app, kind, title, description, keywords, required inputs,
authority class, risk, and whether it reads or writes. `ScopeInventory` already gathers most
of this for *display*; the same gathering becomes the index.

**The ranking.** Lexical first — field-weighted scoring over title, description and
keywords, with idf so that a word appearing in forty capabilities counts for less than one
appearing in two. That alone would have stopped "Open Social" winning a sentence about a
project, because "open" and "social" are common and "contextdock" matched nothing. Local,
instant, debuggable, no model call. Embeddings are a later refinement, not the starting
point, and a ranking nobody can explain is worse than one that is merely adequate.

**The decision** is where Step 0.5 lives: a clear leader acts, a tie asks, nothing above the
floor answers conversationally instead of pretending.

**The model's job** is to choose among the top K by id, and to write the answer — never to
invent what is available. `ChatPlanRunner.plan` already works this way and states why: a
hallucinated step becomes a rejected id rather than an attempted action.

*Migrate, do not rewrite.* Build the index and the ranker beside the existing routers,
compare their answers on the eval set below, and retire each router only when the index
answers at least as well for its cases. Six matchers deleted in one commit is how a working
launcher becomes a broken one.

**Step 2 — a plan the user can read before it runs.** `ChatPlan` exists and runs steps. What
it lacks is a visible plan: the steps, in order, each naming its capability and its
authority, with one approval for the whole plan rather than one per step. The Unified Dock
Surface already has the strip to render it in.

**Step 3 — verification per step, refusal to continue on contradiction.** `ChatPlan` already
verifies after each step. It does not stop when a step is *contradicted*. A plan whose third
step demonstrably did not land must not run its fourth.

**Step 4 — the agent can read its own evidence.** DoraX writes `routerTrace`,
`ChatConsoleLog`, `ai-audit.json` and rich `os_log`, and can read none of it. Three
read-only capabilities — `dorax.lastTurnTrace`, `dorax.auditHistory`, `dorax.readOwnLogs` —
turn "that was wrong" into a structured account of which route was chosen and why. Every
bug in this session took a screenshot plus a human to locate; this is the piece that makes
the app able to say it itself.

**Step 5 — memory of what worked.** `ChatRoutePreferenceStore` already remembers a picked
route per app and intent shape. Extend to whole plans: a plan that verified is a plan worth
offering again.

Steps 0, 0.5 and 3 are correctness. 1, 2 and 4 are the product. 5 is the compounding one and
should come last, because remembering the wrong thing is worse than remembering nothing.

---

## 5. Rules this must not break

- **Menus are an execution surface, never a discovery surface.** Established in
  `APP_KNOWLEDGE_SKILLS.md`. A page read once drove Safari's menu bar and left it hanging
  open on every query.
- **The candidate set is what the user granted.** Not what is installed.
- **One executor.** A second execution path is how approval gets dropped silently.
- **A question is not a licence to write.** The whole of Step 0.
- **Nothing runs unattended that the user did not see offered.** Bounded steps, visible plan,
  stated approval.
- **No new product layer.** This is Context Dock Chat becoming competent, not a new surface.
- **One harness, many profiles.** Detaching or switching Pets must not duplicate the tool loop,
  provider state, capability index, approvals or executor.
- **Headless first.** If a route works headlessly, do not launch the app. Start hidden when only
  the process is required; ask before taking focus when visible UI is only DoraX's fallback.
- **Cross-app work promotes scope.** Preview and connect the required Pet, then run one typed
  Combined Chat graph. Pet connection is never treated as write permission.
- **Modes guide, never grant.** `/mods` may change instructions and tool emphasis, not scope,
  authority, risk or provider limits.

---

## 6. How we will know it worked

Not "it feels smarter". The eval suite already has the shape (`AgentRoutingEvalTests`,
`PromptAssemblyEvalTests`). Add, as cases, every failure this session actually produced:

- `is this page related to our contextdock project…` → an answer, no action offered
- `find my bookmarks note and summarise that` → Notes, not Find My, not browser bookmarks
- `turn on dark mode` → the switch moves; `is dark mode on?` → the value
- `hi hello` in a Safari scope → an answer, and no menu opens
- a two-step instruction → a visible plan, one approval, both steps verified

Each of those was a real report. A fix without one of these is a fix that will regress.

---

## 7. The Autonomous Provider Execution Model & Scoped Tooling (UTCP, Scripts, Computer Use)

### 7.1 DoraX as the Governor & Sandbox; The AI Provider as the Engine
Users configure their preferred model engine in **Settings → AI Providers** (Claude Code CLI, Anthropic API, OpenAI Codex, Google Gemini, Local Ollama). 

Inside DoraX:
- **The Provider is an autonomous reasoning engine, not a separate terminal or desktop app.** It does not run wild on macOS. DoraX hosts the turn lifecycle, supplies the context, intercepts every tool/action request, and executes it inside Swift.
- **Target App Pinning:** When the user interacts with an App Pet (e.g. Safari `com.apple.Safari`), DoraX explicitly pins the turn to that single target `bundleId`. The prompt context, system instructions, and execution boundaries are strictly scoped to that frontmost app. The AI cannot accidentally trigger actions on other apps (e.g. Mail, Notes, Terminal) unless the user explicitly expands scope into Combined Chat.

### 7.2 Why We Do NOT Need Pre-Written Scripts For Every App Feature
The legacy approach of writing hand-coded scripts, plugins, and CLI wrappers for every macOS app feature led to bloated catalogs and brittle "install brew tool" dead ends. 

Instead, modern frontier models possess sufficient reasoning to **find their own path** via the **3-Tier Escalation Ladder**:
1. **Tier 1: Built-in & Direct UTCP (Instant, Zero Latency):** If a fast local framework, SQLite reader, or direct UTCP API exists, DoraX executes it directly headlessly.
2. **Tier 2: Agentic Script Synthesis ("Code Mode"):** If no pre-built tool exists, DoraX provides the frontmost app's scripting dictionary (`sdef` / JXA / AppleScript). Claude/Codex/Gemini writes on-the-fly code to accomplish the task. DoraX validates and executes the script inside a sandboxed runner.
3. **Tier 3: Autonomous Computer Use (UI Fallback):** For proprietary, web, or non-scriptable canvas apps (e.g., Figma, WhatsApp), the AI operates the app's interface directly using live `NSMenu` hierarchies and Accessibility (`ax_snapshot`, `press_menu`, `ax_click`, `ax_type`).
4. **Skill Auto-Capture (Phase 5):** When a Tier 3 Computer Use run succeeds (menu presses included), `ComputerUseSkillRecorder` saves its steps as a "Learned: …" skill in `SkillStore`, which the next turn's model reads. Verified *reads* are also kept as solved skills (#205, `AI/SolvedSkill*.swift`) and replayed before the model. Tier 2 scripts are **not** captured yet; that, and the rest of learning, is specified in `docs/superpowers/specs/2026-11-09-agent-harness-model.md` §8 (corrected 2026-11-09).

### 7.3 Why UTCP Replaces Heavy MCP Background Daemons
- **The MCP Problem:** Model Context Protocol servers run as independent Node.js or Python background daemons. Running 5–10 MCP daemons consumes hundreds of megabytes of RAM, drains battery, and introduces IPC failure points.
- **The UTCP Solution:** The Universal Tool Calling Protocol (`utcp.io` / OpenAPI 3.x, Task #363) eliminates external wrapper daemons. DoraX's native `UTCPDirectExecutor` parses tool manifests and executes HTTP endpoints directly via `URLSession` and CLI binaries via native `Process`. Tools are lightweight, daemon-free, and execute with zero background overhead.

### 7.4 Safety & Control Boundaries
- **Approval Gating:** Read actions run automatically without user friction. Destructive write actions (sending emails, deleting files, purchasing, submitting forms) present a one-click approval card before running.
- **Outbound Privacy Gate:** Prevents sensitive local context (e.g., private notes, messages) from being transmitted over external networks without explicit consent.
- **Computer Use Esc Kill Switch:** Any autonomous UI execution displays a visible "DoraX is operating [App]" status pill with a Stop button and an immediate `Esc` key kill switch.

### 7.5 The Two-Sided Bus: App Envelope & Normalized Execution
To prevent a fragmented sprawl of disconnected scripts, MCP servers, shortcuts, and APIs, DoraX acts as a Two-Sided Normalized Adapter between the Frontmost App and the AI Provider:

```
┌─────────────────────────┐          ┌───────────────────────────┐          ┌──────────────────────────┐
│   FRONTMOST MAC APP     │          │       DORAX ENGINE        │          │       AI PROVIDER        │
│ (Safari, Pages, Xcode)  │◄────────►│ (Host, Governor & Sandbox)│◄────────►│ (Claude, Codex, Gemini)  │
└─────────────────────────┘          └───────────────────────────┘          └──────────────────────────┘
      macOS Layer                         Normalized Middleman                   Reasoning Brain
```

1. **Downwards to macOS (Sense & Act):**
   - **Sense:** DoraX inspects the frontmost app to read window titles, URLs, selections, and live `NSMenu` items.
   - **Act:** Dispatches actions via the cleanest channel available (native UTCP HTTP → AppleScript/JXA → Accessibility `AXUIElement`).
2. **Upwards to the AI Provider (The Context Envelope):**
   - DoraX bundles the app's identity, `AGENT.md` rules, learned `SKILL.md` workflows, live menu items, and available UTCP direct tools into a single normalized prompt context.
   - The AI never deals with macOS-specific IPC intricacies; it only sees clean tool definitions and markdown context.
3. **Execution Normalization:**
   - When the AI returns a decision, DoraX maps it into one of three execution lanes:
     - **Tool Call:** Dispatched headlessly via native `URLSession` (UTCP) or `Process`.
     - **Synthesized Script:** Executed via `osascript` in a governed sandbox.
     - **UI Command:** Dispatched via `AXUIElementPerformAction` on live menu items or buttons.

### 7.6 Fresh Chat Presentation over Frontmost App
When a user summons DoraX over a frontmost app (e.g., Safari) via hotkey (`⌘⌘` or `⌥⌥`), the shell opens in a focused, zero-clutter state:

```
┌─────────────────────────────────────────────────────────────┐
│ 🧭 Safari  ·  GitHub: PR #368 · [3 other tabs]              │
├─────────────────────────────────────────────────────────────┤
│ Ask anything about this page, or tell Safari what to do...  │
│ [ ⚡️ Bookmark ]  [ 📄 Markdown ]  [ 🔍 Summarize ]          │
└─────────────────────────────────────────────────────────────┘
```
- **Context Pill:** Shows the active app name, frontmost document/URL title, and open tab counts.
- **Action Strip:** Quick-action pills dynamically populated for that specific app (Bookmark, Summarize, Export).
- **Zero-Friction Prompt:** Scoped to the frontmost app immediately without requiring explicit app naming.

### 7.7 App Pet Modes (`/mods`)
Modes are bounded behavioral presets tailored to each application, similar to specialized roles in frontier AI tools:
- **Safari Modes:** `Browse` (default, quick reads), `Research` (multi-tab synthesis, citations), `Compare` (comparative tables), `Automate` (form assistance, UI clicks).
- **Finder Modes:** `Find`, `Organize`, `Batch`, `Inspect`.
- **Terminal Modes:** `Explain`, `Diagnose`, `Run`.

**How users interact with `/mods`:**
1. **Slash Command:** Typing `/mods` lists supported modes for the current Pet; typing `/mods research` switches the mode in the current thread without clearing conversation history.
2. **UI Mode Pill & Side Panel:** The App Pet header displays an interactive mode pill `[ 🧭 Safari · Research ▾ ]`. Clicking it opens a side-panel mode picker.
3. **Custom Modes in AGENT.md:** Users can define custom modes for any app in `Settings → Extensions → Apps → Agent (AGENT.md)` under YAML frontmatter (`modes: [...]`).
4. **Safety Rule:** *A mode narrows; it cannot widen.* A mode alters persona, prompt overlays, and tool ranking, but never bypasses user approval gates or security permissions.



