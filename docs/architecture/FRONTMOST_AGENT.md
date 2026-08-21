# The frontmost-app agent

One assistant, scoped to the app in front of you, that carries out what you asked using the
capabilities you granted — and never by clicking a menu to find something out.

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
