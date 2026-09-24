# How one answer happens, start to finish

Written 2026-09-22, from the code rather than from memory. If you read one file to understand
DoraX's AI, read this one.

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
 │ 0. WHICH CHAT   │  dock app chat · General Chat · chat window · corner · MCP (an agent asking)
 └─────────────────┘  each builds a scope, then calls the SAME send()
        │
        ▼
 ┌────────────────────────────────────────────────────────────────┐
 │ 1. CHEAP LOCAL ANSWERS         "is X installed?"               │──► ends here
 │ 2. ACCESS GATE                 needs an app this chat lacks    │──► ends here (offer to enable)
 │ 3. SCOPE SUGGESTION            names no app but needs one      │──► ends here (ask which)
 │ 4. WORKBENCH INTENT            a saved multi-step recipe       │──► ends here
 │ 5. CLAUDE CODE BRIDGE          delegation to the CLI agent     │──► ends here
 │ 6. CROSS-APP PLAN              2+ apps, or "several steps"     │──► ends here (plan runs)
 │ 7. ROUTE RESOLUTION            one app, several ways to do it  │──► ends here (ask / run)
 │ 8. OBSERVED MENU ANSWER        the answer is a menu we read    │──► ends here
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
 │     tools?  ─ yes ─► tool loop: call → run → feed back → repeat │
 │              ─ no ─► prose directive loop: {"menu_call": …}     │
 └────────────────────────────────────────────────────────────────┘
        │
        ▼
 ┌────────────────────────────────────────────────────────────────┐
 │ 14. AFTER THE ANSWER                                           │
 │     recover a directive written as prose · verify claims ·      │
 │     offer a route / a worker / Computer Use · collect rows      │
 └────────────────────────────────────────────────────────────────┘
        │
        ▼
    the answer, its steps, its receipts, its cards
```

---

## Stage by stage

### 0. Which chat, and what it is scoped to

`GeneralChatScope` is the answer to "what is this conversation about": `.app(bundleId:)`,
`.folder`, `.cli`, `.thread`, or `.general`. Every surface — the dock's app chat, General Chat,
the chat window, the corner, and an external agent through the MCP server — builds one and calls
the same `AppScopedChatService.send`. **There is one pipeline.** When two surfaces behave
differently, the cause is the scope they built, not a second code path.

### 1. Cheap local answers

`LocalInstallationCheck` — "is Claude Code installed?" is answered by looking, not by asking a
model. Ends the turn.

### 2. The access gate

`appNeedingAccess` — the question needs an app this conversation is not about. DoraX does not
reach; it offers, naming every app the sentence names *or implies*, and enabling them is one tap.
**This is a boundary, not a nag**: a Safari chat may not read Notes, and a chat cannot widen its
own scope.

### 3. Scope suggestion

The question needs *some* app and named none ("who do I talk to most") — DoraX asks which, rather
than answering from nothing.

### 4–5. Recipes and delegation

A saved multi-step workflow (`WorkbenchIntent`) runs. A coding-shaped request goes to the Claude
Code CLI, which has its own tools and reports every one of them back as steps.

### 6. The cross-app plan

Two or more apps in scope, or a request the classifier calls multi-step: routes are resolved
across every app the chat may touch, a model **orders those routes** (it can only choose from
what already resolved — a hallucinated step is a rejected id, not an attempted action), and
`ChatPlanRunner` runs them, narrating each step and reading the result back.

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

What the app knows before the model is asked: the page in front of you, your open tabs, the
Finder selection, the workspace, the app's own reference docs, its adapter inventory, its skills,
its **AGENT.md profile**, and live Apple data when in scope. All of it is budgeted per provider
(`AIContextBudget`: 1 500 characters on-device, 4 000 for local endpoints, 12 000 for cloud) and
compacted toward the question (`MarkItDownService.compact`).

### 13. The provider turn

Two shapes, chosen by whether the provider takes tool schemas:

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

---

## Where it can stop, and what you see

| It stopped because | You see |
|---|---|
| The chat lacks the app | "Enable Notes and Safari for this chat" — one tap |
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
4. **The turn log**, when you need the provider and the exact tool list:
   ```bash
   defaults write com.krishgokul.ContextDock doraxTurnLogEnabled -bool YES
   tail -f ~/Library/Application\ Support/Context-Dock/turns.log
   ```
   It records the two facts that settle most "why did it not do that" questions: which provider
   ran the turn and whether it carries tools, and the exact tool names sent.
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
