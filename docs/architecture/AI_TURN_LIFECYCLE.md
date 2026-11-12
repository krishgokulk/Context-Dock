# How one answer happens, start to finish

Written 2026-09-22 from the code; updated 2026-11-09 for #327 and 1.0 engine architecture. If you read one file
to understand DoraX's AI, read this one together with the
[App Pets design](../superpowers/specs/2026-10-27-app-pets-combined-chat-design.md) and
[Agent Harness Model](../superpowers/specs/2026-11-09-agent-harness-model.md).

The question this answers: **a person types something and an answer appears — what happened in
between, what could have stopped it, and how do I tell which of those actually did?**

Every stage below is a real branch in `AppScopedChatService.send`, in the order it runs. Most
stages can *end the turn on their own* — that is the thing the graph view cannot show you and the
reason the pipeline is hard to see: it is not a line, it is a ladder with an exit at every rung.

---

## The shape

```
  the user types
        │
        ▼
 ┌─────────────────┐
 │ 0. WHICH SCOPE  │  Global · one App Pet · Combined Chat · selection attachment · MCP caller
 └─────────────────┘  every presentation builds one scope, then calls the SAME send()
        │
        ▼
 ┌────────────────────────────────────────────────────────────────┐
 │ 1.  CHEAP LOCAL ANSWERS        "is X installed?"               │──► ends here
 │ 2.  SCOPE GATE                 needs a Pet this chat lacks     │──► pause (preview + connect)
 │ 3.  SCOPE SUGGESTION           names no app but needs one      │──► ends here (ask which)
 │ 4.  WORKBENCH INTENT           a saved multi-step recipe       │──► ends here
 │ 4b. SOLVED SKILL MATCH         previously verified read skill  │──► ends here (0ms, no model)
 │ 5.  CLAUDE CODE BRIDGE         delegation to the CLI agent     │──► ends here
 │ 6.  TASK GRAPH                 2+ Pets, or "several steps"     │──► runs one combined plan
 │ 7.  ROUTE RESOLUTION           one app, several ways to do it  │──► ends here (ask / run)
 │ 8.  OBSERVED MENU ANSWER       the answer is a menu we read    │──► ends here
 └────────────────────────────────────────────────────────────────┘
        │  nothing above claimed it
        ▼
 ┌────────────────────────────────────────────────────────────────┐
 │ 9.  GROUNDING       page · tabs · selection · workspace · refs  │
 │ 10. LIVE APPLE DATA notes/reminders/calendar when in scope      │
 │ 11. CAPABILITY HUB  the catalogue, for cross-app questions      │
 │ 12. PROMPT READY    one assembled system prompt, budgeted       │
 └────────────────────────────────────────────────────────────────┘
        │
        ▼
 ┌────────────────────────────────────────────────────────────────┐
 │ 13. PROVIDER TURN                                              │
 │     unified runToolLoop<A: ToolLoopAdapter> (budget, TurnFocus, │
 │     2-round no-progress stop); tools or directive bridge       │
 └────────────────────────────────────────────────────────────────┘
        │
        ▼
 ┌────────────────────────────────────────────────────────────────┐
 │ 14. AFTER THE ANSWER                                           │
 │     recover a directive written as prose · verify claims ·      │
 │     offer a route / a worker / Computer Use · collect rows ·    │
 │     auto-capture SolvedSkill for verified reads (#205)          │
 └────────────────────────────────────────────────────────────────┘
        │
        ▼
    the answer, its steps, its receipts, its cards
```

---

## Stage by stage

### 0. Which conversation, Pets and mode

Conversation identity and turn scope answer different questions. `ConversationKind` says whether
the transcript is General Chat, one anchored App Pet, or Combined Chat. `GeneralChatScope` plus the
participant set says what this turn may use. General Chat can borrow one or several app abilities
for a request without changing identity or loading Pet memory; an App Pet stays anchored; Combined
Chat has explicitly connected persistent participants. The active Pet mode is a bounded profile
overlay, not authority. The Dock, detached Pet, full chat window and external MCP caller all build
one scope and call the same `AppScopedChatService.send`. **There is one pipeline.** Presentation
never creates a second executor, provider session or permission path.

### 1. Cheap local answers

`LocalInstallationCheck` — "is Claude Code installed?" is answered by looking, not by asking a
model. Ends the turn.

### 2. The scope gate

`appNeedingAccess` — the question needs an App Pet this conversation does not include. DoraX does
not reach silently: it previews the minimum required Pet and why, then asks once to connect it.
Acceptance promotes the same conversation to Combined Chat. **This is a scope boundary, not action
approval**: a Safari Pet may not read Messages, and connecting Messages does not approve sending.

### 3. Scope suggestion

The question needs *some* app and named none ("who do I talk to most") — DoraX asks which, rather
than answering from nothing.

### 4–5. Recipes, solved skills and delegation

A saved multi-step workflow (`WorkbenchIntent`) runs. Before prompt assembly, `SolvedSkillMatch.match`
checks whether the scoped app has a matching verified read skill (#205); if so, `SolvedSkillMatch.run`
executes the tool call via `GeneralAIActionExecutor.shared.execute` and returns the verified answer in
0ms without invoking the model. A coding-shaped request goes to the Claude Code CLI, which has its
own tools and reports every one of them back as steps.

### 6. The Combined Chat task graph

Two or more Pets in scope, or a request the classifier calls multi-step: the host discovers the
minimum participant set, resolves typed routes, and lets the selected provider order only those
resolved ids. A hallucinated step is rejected, not attempted. `ChatPlanRunner` executes one graph,
passing each Pet only step-required evidence, narrating progress and reading results back. The host
keeps token/round/time/no-progress budgets and never silently changes provider.

### 7. Route resolution

One app, several ways. If the ways differ in consequence the user is asked; if one is obviously
right and read-only it just runs. Preference order is fixed and deterministic:

```
adapter action → MCP tool → API → CLI → Shortcut → automation → verified menu → keyboard → AX
```

Menus and keystrokes are last because they take the screen and fail when the app is in the wrong
state. `ActionReadiness` refuses to offer anything whose required inputs are missing, and refuses
a destructive command for a constructive request.

### 8. The observed menu answer

Sometimes the question *is* the menu ("what can this app export?"), and reading it is the answer.

### 9–12. Grounding, then one prompt

What the participating Pets know before the model is asked: relevant live page/window facts,
explicit attachments, conversation summary/retrieved turns, app reference knowledge, capability
inventories, skills, App Pet profiles, and verified per-Pet memory. Selection remains local unless
explicitly attached. All of it is budgeted per provider
(`AIContextBudget`: 1 500 characters on-device, 4 000 for local endpoints, 12 000 for cloud) and
compacted toward the question (`MarkItDownService.compact`).

### 13. The provider turn

Executed through the unified tool loop harness `runToolLoop<A: ToolLoopAdapter>` (E6a #154 / E6b #155),
with strict `ToolLoopBudget` enforcement (max 8 rounds, 60s wall clock, and a 2-round no-progress
circuit breaker), plus per-round `TurnFocus` guidance (`inspect` → `act` → `verify` → `answer`, E7a #156):

- **Tools** (OpenAI, Anthropic, Gemini, and the bridges): the model calls a tool, DoraX runs it
  through the approval gates, feeds the real result back, repeats to a round cap.
- **No tools** (Claude Code, Apple Intelligence): the model writes one line of JSON —
  `{"menu_call": …}`, `{"operate_app": …}`, `{"app_script": …}` — and the hub executes it through
  the *same* gates. This is not a lesser path; it is the same authority reached by a different
  wire format.

### 14. After the answer

A directive the model printed instead of calling gets recovered and run. Claims are checked
against what actually ran. Rows are collected into cards. When nothing linked could do the job,
DoraX offers — a route, a specialist worker, or Computer Use with the exact item named.
Verified single-tool read turns are captured by `SolvedSkillCapture` (#205) for instant replay on
future turns.

---

## Where it can stop, and what you see

| It stopped because | You see |
|---|---|
| The chat lacks a Pet | “Connect Messages Pet to finish this task” with the reason — one tap |
| Several routes differ in consequence | Pick-one buttons, never a paragraph to retype |
| A capability needs approval | A card naming the app, the action and its inputs |
| A plan step failed | "Failed step 2 · …", and the steps after it named as skipped |
| Nothing could do it | The honest refusal, plus the offer one rung down |
| The provider carries no DoraX tools | One line saying so — only when the turn produced nothing |

**Every one of those is visible in the step rows**, which now say what is running *while* it runs:
`Searching Messages "invoice"…`, `Step 1/2 · Read open tab titles — Safari · App data`,
`Running \`brew upgrade\`…`, then what came back.

---

## How to tell what actually happened

1. **The step rows** in the chat — the live account.
2. **Evidence receipts** on the message — what ran, with its real output.
3. **The Console panel** — every command and its output for this conversation.
4. **The turn log and trace**, when you need the provider, exact tool list, or OpenTelemetry-compatible turn span:
   ```bash
   defaults write com.krishgokul.ContextDock doraxTurnLogEnabled -bool YES
   tail -f ~/Library/Application\ Support/Context-Dock/turns.log
   ```
   Or inspect structured JSON turn traces written by `TurnRecorder.swift`:
   ```bash
   tail -f ~/Library/Logs/Context-Dock/turn.trace
   ```
   It records provider, prompt size, tool counts, `dorax.stop_reason`, `dorax.cancelled`, `dorax.focus`, and `dorax.round.focus`.
5. **`dorax_ask` over MCP** — ask DoraX a question from outside and get back the answer, the
   steps, the receipts, and which approvals it decided to ask for. It runs unattended: every
   approval is refused, so nothing is written, and what you assert on is *which approval was
   requested* rather than whether the side effect happened.

---

## Why it is a ladder and not a line

Because the alternative is worse. A single path would mean sending every question to a model with
a catalogue and hoping; the ladder means a question the app can answer itself never reaches a
model, a request that needs consent stops at consent, and a request nothing can do is refused
where the refusal is still specific. The cost is that "what happened" has more than one answer —
which is exactly why the step rows exist, and why this document does.
