# Every capability has a surface, and every surface has a cost

**The one-sentence change:** DoraX ranks what it *can* do, but not what doing it *costs* the
user. Add the cost, and most of the confusion in this area answers itself — including when
Computer Use is the right answer and when reaching for it is a bug.

**Builds on:** `docs/architecture/FRONTMOST_AGENT.md` (the index, the ranking, the decision,
the plan). That document is not superseded. This one adds the axis it does not have, and its
Step 1 index is where this work lands.

---

## 1. The report this came from

Asked **"new chat"** in the Claude scope, DoraX opened `https://docs.anthropic.com/en/docs/mcp`
and then said the page had nothing about a new chat in it.

The immediate cause was a scoring bug — both seeded Claude actions carried `claude` as a
trigger, and the query contained the word, so a URL action scored 78 on the one word in the
sentence that could not discriminate. Fixed in `6553bb1`.

**But the interesting failure is what did not happen.** Claude Desktop, in this install, has:

- a linked CLI (`claude`, seeded by `AdapterIntegrationSeeder`)
- a cached menu map, which contains `File ▸ New Chat`
- 3 actions and 5 resources
- and Computer Use, available but off

Three of those could plausibly start a new chat. DoraX offered none of them, and never said
there was a choice. Even with the scoring bug fixed it still would not have, because the
ladder takes the first rung that matches rather than presenting rungs whose costs differ.

---

## 2. What is already true

Do not rebuild these. Named so this document cannot be read as a rewrite.

| Piece | Where |
|---|---|
| Routes as a typed, ranked list with a user-facing label | `ChatRoute.Kind` — `cli`, `adapterAction`, `menuCommand`, `mcpTool`, `skill`, `model` |
| "Does this take the screen" already exists as a concept | `ChatRoute.Kind.takesTheScreen` |
| One index over everything DoraX can do | `CapabilityIndex` — built, deliberately unwired |
| Computer Use, AX-first, pixel last, denylist-gated | `ComputerUseTool`, `ComputerUseTargetResolver`, `ComputerUseEvidence` |
| Per-app consent, tri-state over a master switch | `ComputerUseConsentStore` — off / askEachStep / autoInTask |
| A specialist worker rung with a checkable ordering | `AIWorkerOffer.shouldOffer` |
| Asking instead of guessing on a tie | `shouldClarifyBetweenPeers`, `PendingClarification` |
| One executor, authority per route class | `GeneralAIActionExecutor`, `AppAccessPolicy` |
| DoraX's own surfaces described to the model | `DoraXSurfaceSkills` |
| A remembered route preference per app and intent | `ChatRoutePreferenceStore` |

---

## 3. The missing concept

`ChatRoute.Kind.rank` is a **fixed preference order**: adapter action, then MCP tool, then
CLI, then menu, then skill, then model. It answers "which mechanism do we prefer in general".

It does not answer the question the user is actually asking, which is two questions:

1. **Can this path do the thing?**
2. **What does this path cost me?**

Those are different axes and today they are one number. A menu route and a CLI route may be
equally able to start a new chat; they differ in that one opens the app and takes the screen
and the other does not. That difference is the user's to spend, not DoraX's to assume.

**Computer Use is not in the enum at all.** It is a terminal fallback in
`AppScopedChatService`, gated on `!ranAnything`, resolving one live menu item. So it can only
ever be reached by *failing* first — which is exactly backwards for the cases where it is the
only honest answer, and unreachable for the cases where the user would happily have chosen it.

### The cost model

Every capability record gains a **surface** and, from it, a cost:

| Surface | Cost | Examples |
|---|---|---|
| `headless` | nothing visible happens | MCP tool, adapter action, read-only CLI, Apple app reader |
| `opensApp` | the app comes forward | menu command, URL scheme, a CLI that launches something |
| `takesScreen` | DoraX drives the UI | Computer Use: AX press, then pixel click |
| `advisory` | nothing runs | skill, model answer |

And a second, orthogonal field already half-present in the capability layer: **`writes`** —
whether the path changes anything. `headless` + `writes` is not free; `takesScreen` + read is
not expensive in the same way.

### The rule this buys

> Rank by capability. Choose by cost. **Ask when the cheapest paths are tied in ability but
> differ in cost**, and never reach for a more expensive surface while a cheaper one can do
> the same job.

That single rule covers every case in the user's report:

- Claude "new chat": CLI and menu both able, costs differ → **ask**, do not pick.
- Anything with one able path → run it, no question.
- No able path, but the app's UI plainly has it → **Computer Use is the answer, offered as
  such**, not reached by failure.
- No able path and no UI for it → say so, and offer the specialist worker rung or a Global
  Command the user could add.

---

## 4. DoraX's own surfaces are capabilities too

The user's point, and it is a real gap: DoraX has a Global Commands layer with CLI-tool
capability, its own preview window, its own CLI tool scope, its own clipboard. Those are
capabilities of the *app the user is talking to*, and the assistant does not offer them as
answers.

`GlobalCommandCapabilities` matches them and `DoraXSurfaceSkills` describes them, but nothing
proposes them. When Claude Desktop has a CLI that could do far more than one command, the
honest answer includes:

> `claude` is linked here as a CLI. Add it to Global Commands and you can drive a Claude
> workspace from any scope, not just this chat.

That is a capability record like any other, with surface `advisory` — it runs nothing, it
tells the user what they could turn on. It belongs in the index so the ranker can surface it,
not in a special case.

---

## 5. What Computer Use should learn from `agent-desktop`

<https://github.com/lahfir/agent-desktop>. DoraX is already AX-first and pixel-last, which is
the main thing that project gets right. Three things it has that DoraX does not:

1. **Stable element refs across snapshots** (`@s8f3k2p9:e1`). DoraX resolves a phrase to an
   item per attempt; a ref that survives lets a multi-step UI task retry safely.
2. **Progressive skeleton traversal** — a shallow tree first, drill down on demand, reported
   at 78–96% fewer tokens on dense apps. DoraX reads menus, not windows; for real UI work the
   window tree is the expensive thing.
3. **Typed failures instead of guesses** — `STALE_REF`, `AMBIGUOUS_TARGET`. DoraX already
   refuses ties in `ComputerUseTargetResolver`; making the refusal typed lets a plan step say
   *why* it stopped rather than just stopping.

Take 3 first — it is small and it is safety. Then 1. Then 2 only if window-level UI work is
actually built, because a traversal optimisation for a thing that does not exist is waste.

---

## 6. The plan

> **Status (2026-09-23):** Steps 1, 3, 4, 5, 6 and 7 are built. Step 2 has the route kind and
> the surface projection; wiring the offer into `AppScopedChatService` and retiring
> `ComputerUseFallback` is what remains. Nothing is wired to `CapabilityIndex` yet — it still
> runs in shadow beside the live routers, by its own design note.


Ordered so that each step is worth shipping alone, and so that the first two are correctness
rather than product.

### Step 1 — Surface and cost on the capability record

`CapabilityRecord` gains `surface: Surface` and keeps its existing read/write knowledge.
Every source that feeds the index sets it: adapter actions by type (`urlScheme` opens the app,
AppleScript may not), CLI tools by whether they launch anything, MCP tools headless, menu
commands `opensApp`, skills advisory.

Pure, testable, and wired to nothing. **`ChatRoute.Kind.takesTheScreen` is the seed of this
and should become a projection of it rather than a second source of truth.**

### Step 2 — Computer Use becomes a route, not a fallback

Add `computerUse` to the candidate space with surface `takesScreen`, available when the app is
granted it and the live UI plausibly has the thing. Keep `ComputerUseFallback` working until
the route path answers its cases; delete it after, not before.

The `!ranAnything` gate disappears: Computer Use stops being what happens when everything else
failed, and becomes a path with a stated cost like the rest.

### Step 3 — The choice, when costs differ

One function, in the shape this codebase already uses for orderings that matter:

```
CapabilityDecision.choose(candidates) -> .run(id) | .ask(options) | .answer | .none
```

- one able candidate → `.run`
- several able, same surface → `.run` the best (existing ranking decides)
- several able, **different surfaces** → `.ask`, with the cost in the label, because that is
  the axis the user is choosing on
- none able, UI has it → `.ask` with Computer Use named and its consent state shown
- none able, no UI → `.answer` honestly, and name what the user could add

The labels are already written: `ChatRoute.Kind.routeLabel` says "no window opens" and "opens
the app" because that is what people care about. Reuse them verbatim.

### Step 4 — Consent in the same breath as the choice

`ComputerUseConsentStore` already has off / askEachStep / autoInTask. What is missing is
granting it *at the moment of the offer*: choosing "Use the UI" when the app is not granted
should be able to grant `askEachStep` for that app as part of the same press, the way the
Computer Use card already does. Add **once** as a real option distinct from **always**, since
the user asked for it and the store's tri-state does not express it.

### Step 5 — DoraX's own capabilities in the index

Global Commands, the CLI tool scope, the preview window, the clipboard — as records with
surface `advisory` where they are suggestions and `headless` where they run. This is what lets
the assistant answer "add the Claude CLI to Global Commands and you can drive it from
anywhere" instead of stopping at what is already linked.

### Step 6 — Typed refusals in Computer Use

`ComputerUseTargetResolver` returns one item or nil. Make nil typed: `ambiguous(candidates)`,
`notVisible`, `disabled`, `notFound`. A plan step that stops can then say which, and an
ambiguous result is a `.ask` rather than a dead end.

### Step 7 — Per-app evaluation

The section below, as `AgentRoutingEvalTests` cases. Offline, deterministic, no model. Each is
a real sentence with a stated expected decision, so "it feels smarter" is never the measure.

---

## 7. What this must not become

- **A prompt on every request.** Ask only when the ability is tied and the *cost* differs.
  Two headless paths are not a question; pick one.
- **Computer Use as the general answer.** It is the most expensive surface and the least
  verifiable. It is right when the app's own UI is genuinely the only way, and wrong whenever
  a linked CLI, tool or action can do the same job.
- **A new product layer.** Everything here lands in the existing index, decision and executor.
- **A model deciding the ordering.** The cost of a surface is a fact about the surface, not a
  judgement. The model chooses among offered ids; it does not rank them.

---

## 8. Worked examples, per app

The format is the whole point: **what was asked → what the index found → what each path costs
→ the decision → what verifies it.** Each becomes an eval case. Where today's behaviour is
wrong, it says so.

### Claude Desktop — "new chat"

| Candidate | Source | Surface | Able? |
|---|---|---|---|
| `claude` CLI | linked CLI tool | `headless` | yes — the CLI starts a session |
| `File ▸ New Chat` | cached menu map | `opensApp` | yes |
| Computer Use press | live AX tree | `takesScreen` | yes, but consent is off |
| `Claude MCP Setup` (URL) | seeded action | `opensApp` | **no** — matched only on the app's name |

**Decision: `.ask`.** Two able paths, different costs.

> Two ways to do this. **Run `claude` — no window opens** · **Open Claude ▸ File ▸ New Chat —
> brings the app forward**

**Today:** the URL action wins on a name match and opens a docs page. The name-match half is
fixed (`6553bb1`); the offer half is Step 3.

**Verification:** CLI → exit status plus session id in output. Menu → `MenuOutcomeVerifier`
counts windows before and after, and a new chat window is a window that appeared.

### Claude Desktop — "summarise my last conversation"

| Candidate | Surface | Able? |
|---|---|---|
| `claude` CLI | `headless` | yes, if the CLI can read history |
| menu map | `opensApp` | no — no menu item does this |
| Computer Use | `takesScreen` | yes, by reading the window |

**Decision: `.run` the CLI.** One able cheap path; never offer the screen when a headless path
exists. If the CLI turns out not to expose history, the *typed failure* is what promotes
Computer Use to the next offer — not a guess made up front.

### App Store — "update all my apps"

From the screenshot: 1 action, 2 resources, 0 CLI, 0 MCP, 0 shortcuts, Automation permission
**not granted**, Computer Use **off**.

| Candidate | Surface | Able? |
|---|---|---|
| `softwareupdate` CLI | Global Command, machine-wide | `headless` | partially — system updates, not App Store apps |
| App Store menu | cached map | `opensApp` | no item does "update all" |
| Computer Use press on **Update All** | `takesScreen` | yes — the button exists in the UI |

**Decision: `.ask`, naming Computer Use and its consent state.** This is the case the user was
reaching for: the app genuinely has no headless path, the UI plainly has the button, so driving
the UI is the honest answer rather than a failure.

> Nothing linked can update App Store apps. The **Update All** button is on screen — DoraX can
> press it, but Computer Use is off for App Store. **Allow once** · **Allow always** ·
> **Cancel**

**Verification:** screenshot before and after plus the app's own updated-count. `takesScreen`
is the surface with the weakest verification, which is another reason it must be last.

### Finder — "empty the trash"

| Candidate | Surface | Able? |
|---|---|---|
| `finder.emptyTrash` adapter action | `headless` | yes |
| `Finder ▸ Empty Trash` | `opensApp` | yes |
| Computer Use | `takesScreen` | yes |

**Decision: `.run` the adapter action** — it is the only `headless` one and it writes, so it
goes through approval as it does today. Three able paths but only one cheapest; that is not a
tie and must not become a question. **This is the case that proves the rule does not turn into
a prompt on every request.**

### VS Code — "what extensions do I have"

| Candidate | Surface | Able? |
|---|---|---|
| `code --list-extensions` | `headless` | yes |
| `vscode.extensions.list` capability | `headless` | yes |
| menu | `opensApp` | no |

**Decision: `.run`.** Two able paths, **same surface** — rank decides, no question. The
existing `ChatRoute.Kind.rank` already prefers the registered capability over the raw CLI, and
that stays exactly as it is.

### ChatGPT — "start a new chat" (adapter shows a setup warning)

| Candidate | Surface | Able? |
|---|---|---|
| menu map | `opensApp` | yes, if the map is fresh |
| Computer Use | `takesScreen` | yes |
| CLI | — | none linked |

**Decision: `.ask` between menu and Computer Use**, *and* surface the setup problem, because a
stale menu map is exactly the case where the cached route fails and the live UI succeeds. The
warning triangle in Integrations is information the decision should use, not decoration.

### Calendar — "what's on tomorrow"

| Candidate | Surface | Able? |
|---|---|---|
| `calendar.list` / EventKit reader | `headless`, read | yes |
| menu | `opensApp` | no |
| Computer Use | `takesScreen` | yes, by reading the window |

**Decision: `.run` the reader.** A question with a headless read is never an offer and never
opens anything — this is `FRONTMOST_AGENT.md` Step 0, and it stays first.

### Any app — "is this page related to my project?"

**Decision: `.answer`.** A question. No candidate is offered regardless of what matched, per
Step 0. Listed here because it is the regression that matters most: every capability-ranking
change risks reintroducing it.

---

## 9. How to check it per app, by hand

For any app in Integrations, the same four questions in order:

1. **What does the index hold for it?** Actions, CLI, MCP, skills, menu map, Apple reader.
2. **For a given sentence, which are *able*?** Not which score highest — which could actually
   do it.
3. **Do the able ones differ in surface?** If no, it runs. If yes, it asks.
4. **Is the cheapest able path the one that ran?** If a screen-taking path ran while a headless
   one existed, that is a bug regardless of the outcome being right.

Question 4 is the one to hold the implementation to. It is also the one that is cheapest to
test, because it does not depend on the request succeeding.
