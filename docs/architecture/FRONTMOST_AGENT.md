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

**Step 1 — the frontmost inventory becomes the plan's catalogue.** Today the scoped chat
resolves routes, and the agent tools resolve capabilities, and the two lists are built
differently. `ScopeInventory` already unifies them for *display*. Make it the single
catalogue the planner chooses from, so what the user is shown and what the model may pick
are the same list. This is where "use our in-built capabilities" actually becomes true.

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
