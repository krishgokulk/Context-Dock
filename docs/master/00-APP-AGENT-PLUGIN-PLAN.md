# App agent and plugin manager: one flow for every frontmost app

**Status: adopted by the owner 2026-10-06 ("confirm plan"). Tasks P1–P12 are GitHub issues.** Builds on
`docs/architecture/FRONTMOST_AGENT.md` (the agent) and `docs/architecture/AI_TURN_LIFECYCLE.md`
(the ladder). It does not replace them, and it creates no new registry: the plugin manager *is*
the finish of E12 (retire the old routers onto `CapabilityIndex`).

Mail is the pilot. Nothing below is Mail-specific except the plugin list: fix the flow once for
Mail and every app scope in the Dock and the Corner gets it.

---

## 1. What went wrong (2026-10-06 hand test)

Typed in Mail App Chat: *"check my recent mail from Gokula kannan J and do what it says"*.

1. `LauncherView+AIChat.swift` (~4512) runs a Mail keyword shortcut **before any model**.
2. `shouldExecuteMailMailboxSearch` sees the word **"from"** and treats the request as a sender search.
3. It strips "mail" and "from", leaving "check my recent gokula kannan j and do what it says".
4. `executeMailMailboxSearch` clicks Edit › Find › Mailbox Search, types that leftover text and presses Return.
5. The panel says **"Answered without running anything."** That's false. Pre-model shortcuts do not report steps (`CornerLivePanel.swift:170`).

The rule that should have stopped this already exists. Task 17's **"exact command or the
model"** (`ScopedRoutePolicy`) covers `offerScopedNativeAppAction`, but the Dock runs about 15
keyword shortcuts ahead of it, and the Mail one skips the rule. The right tools were registered:
`mail.search(sender:)` then `mail.read`. The model never got the turn.

---

## 2. The flow: from what you type to the answer

```
 you type in an app scope
   │
   ▼
 ① PERCEIVE   frontmost app + window, selection, attached context.
   │          Screen reading order: Accessibility tree (text, local, cheap)
   │          → the app's own data route (adapter / dictionary)
   │          → on-device OCR of a screenshot ONLY if both are empty and allowed.
   │          Never a screenshot when a data route exists.
   ▼
 ② UNDERSTAND  question / action / search; the objects (sender, message, file…);
   │          LANE: data (default, no window) or UI (about the window) — §2a.
   │          Keyword shortcuts may claim the turn ONLY on an exact command
   │          (Task 17 rule). Everything else goes to the model.
   ▼
 ③ FIND TOOLS  Plugin manager returns this app's candidates, ranked (§4).
   ▼
 ④ PLAN        1..n steps, each naming the tool it uses.
   ▼
 ⑤ GATE        write, outbound or private-data step → card, you approve (E1/E1b/E1c).
   │          Text read from mail/web/messages is DATA, never instructions:
   │          "do what it says" → DoraX quotes the instruction and asks.
   ▼
 ⑥ ACT + VERIFY  run, read back, mark verified / contradicted.
   ▼
 ⑦ ANSWER      with the steps that really ran (§3).
   ▼
 ⑧ LEARN       trace (E2) → tool reliability, your preferences, recipe offers (§6).
```

---

## 2a. Scope is not the window: menus are crowding the reasoning

**Rule: an app scope means that app's data and actions, through any channel. The window is one
channel, and the most expensive.** If a request can be done without the window (adapter,
scripting dictionary, MCP, CLI, Shortcut or saved skill), it's done that way, inside the same
app chat, without activating the app, stealing focus or opening a window.

### What the code does today (checked 2026-10-06)

- `ScopedAppPromptBuilder.swift` (~272–315) puts **up to 50 menu commands** into every scoped
  prompt, with the instruction *"When a request maps to a menu command, CALL it immediately"*.
- Its tool order is **adapter → menu → MCP/API → Shortcut → CLI**, and it says *"never generate
  shell or AppleScript for an operation exposed by … the live menu"*. That ranks menus above
  every headless route.
- This contradicts the rest of the code. `CapabilityIndex.Surface` says headless < opens app <
  takes screen. The `run_menu_command` tool's own description says it's for apps *"which have no
  adapter"*.
- `MailAutomation.activateOrLaunchMail()` activates Mail even for reads, the Mail search
  shortcut clicks Edit › Find, and `AXMenuReader.clickMenuItem` (~562) activates the app before
  every menu click.
- Result: the largest block in the prompt is a menu list, so the model reasons in menu terms
  even for data questions. That's the "messy reasoning" the owner sees.

### Words: lanes, rungs, Computer Use

- **Lane** = what the request is about. **Data lane:** the app's content (mail, files, notes,
  events). **UI lane:** the app's interface (windows, tabs, panels, views). Decided once, at
  ② UNDERSTAND, before any tool is picked.
- **Rung** = one way to carry out a lane's job, cheapest first.
- **Computer Use is not the UI lane. It is the UI lane's last rung.** In DoraX it is
  `ComputerUseTool`: DoraX looks at the window and drives it (accessibility press first, a pixel
  click last), gated per app by `ComputerUseConsentStore` (off / ask each step / auto in task)
  and a denylist. A menu command or a key shortcut is UI-lane but is **not** Computer Use.

### The two lanes and their rungs

| Lane | For | Rungs, cheapest first |
|---|---|---|
| **Data** (default) | find, filter, read, count, summarize, create, change content | D1 saved skill · D2 adapter · D3 scripting dictionary · D4 MCP · D5 CLI · D6 Shortcut |
| **UI** | "minimize", "new tab", "show sidebar", "zoom in", "open settings" | U1 menu command · U2 key shortcut · U3 Computer Use |

The data lane falls to the UI lane **only** when no data rung can do the job (example: Mail has
no archive in its adapter or dictionary route). That fall is a visible step and follows the UI
lane's rules below. Menus are never read to find an answer.

### How each rung behaves in each app state

Three states: **not running**; **running in the background** (other app in front, hidden or
minimized); **in front** (the user is looking at it, maybe typing in it).

| Rung | Not running | Running in background | In front |
|---|---|---|---|
| D1–D3 skill / adapter / dictionary (Apple Events) | start the app **hidden, not activated** (`NSWorkspace.OpenConfiguration: activates = false, hides = true`), then send events | events go straight to it; **no activate, no focus change** | same; the only visible change is the data itself (e.g. a message turns read) |
| D4–D5 MCP / CLI | if the tool needs the app (mail-app-cli drives Mail's scripting), start it hidden first, as above; a pure data tool needs no app | runs; app untouched | runs; app untouched |
| D6 Shortcut | runs via `shortcuts run`; any of its actions that open the app are listed in the plan card first | same | same |
| U1 menu command | the app must start; the plan card says "opens Mail" | today `AXMenuReader.clickMenuItem` **activates the app**; it comes forward, shown in the plan card | press it; no focus change needed |
| U2 key shortcut | must start and come forward | must come forward (keys go only to the front app) | sent only if the user is **not typing** in it; otherwise wait and ask |
| U3 Computer Use | must start, come forward, window visible | must come forward | takes the pointer and screen; consent per app, step by step, Esc stops |

### Rules that keep the user undisturbed

1. **The data lane never calls `activate()`, never moves focus and never opens a window.** The
   `activate()` calls in `MailAutomation` and the Mail search shortcut are removed from data paths.
2. **If DoraX started the app, it says so** ("Mail wasn't running; started it in the background")
   and leaves it hidden. It does not quit it unless the user's setting says to.
3. **Exceptions are explicit.** A data result whose point is to be seen (a draft composer from
   `mailto:`, "open this email") opens a window **because the user asked to see it**, and the plan
   card says so.
4. **The UI lane changes only the scoped app.** If it had to bring the app forward and the user
   was elsewhere, focus goes back to where the user was when the step ends (unless the request was
   "show me…").
5. **Never type into an app the user is typing in.** U2 and U3 wait until the user stops, then ask.
6. **App busy or slow:** every Apple Event has a timeout (`AXMessagingTimeout`), no bulk body
   fetch from unattended runs (mail-app-cli warns this can freeze Mail's scripting), and a timeout
   is a visible step, not a silent retry.
7. **Computer Use is never the first choice for data.** It is reachable only through the UI lane,
   after U1–U2 can't do it, with its existing consent, and the step list says "DoraX drives the
   screen".
8. **Same in Dock and Corner.** One lane decision, one executor.

### What the user sees, per state

```
Not running, data:   ✓ Lane: data · ✓ Mail wasn't running — started it in the background
                     ✓ mail.search(sender: "SBI", day: today) · 3 messages
Background, data:    ✓ Lane: data · ✓ mail.search … (Mail stays where it is)
In front, UI:        ✓ Lane: UI · ✓ Menu: Window › Minimize
Data → UI fallback:  ✓ Lane: data · ✗ No data route for "archive" in Mail
                     ⏸ Plan: bring Mail forward, Message › Archive, then return — Allow / Deny
```

### Prompt changes

- **No menu dump by default.** The scoped prompt lists the top headless candidates for *this
  request* from `CapabilityIndex` (a handful, not 50).
- **Menus on demand:** a `find_menu_command(query)` tool returns the few matching menu paths when
  the model is in the UI lane or has no headless route. The UI-lane prompt may keep a short menu
  list.
- **One tool order everywhere, equal to `Surface`:** saved skill → adapter → dictionary → MCP →
  CLI → Shortcut → menu → screen. Delete the "CALL it immediately" and "never AppleScript if
  a menu exists" lines.
- **Smaller prompt:** fewer tokens, and the model reasons about the data first. Measured with E2
  (prompt characters per section, share of turns in the UI lane).

### Tests (`RoutingPhrasebookTests`, Dock and Corner)

- "find mail from SBI today" → data lane, `mail.search`, Mail not activated.
- "check my recent mail from Gokula kannan J and do what it says" → data lane, read, untrusted card.
- "minimize this window" / "new tab" → UI lane, menu.
- "archive the newest bank email" with no archive route → menu fallback shown as a step.
- Each data sentence in all three states: Mail not running → started hidden, never frontmost;
  Mail in background → stays in background; Mail in front → focus unchanged.
- UI sentence while Mail is in the background → plan card, then focus returns to the user's app.

---

## 2b. Worked examples: Mail, Terminal, Messages

Same flow for each: understand → lane → tool → get the app ready → do it → check → show steps.
"Card" means a gate or plan card the user approves.

### Mail

Today's tools: `mail.recent`, `mail.read`, `mail.search`, `mail.currentMessage` (AppleScript)
and `mail.createDraft` (`mailto:`; **no send verb by design**). Optional: `mail-app-cli` (§7).

| You type | Lane | Tool | App state handling | Card? |
|---|---|---|---|---|
| "find mail from SBI today" | data | `mail.search(sender: SBI, day: today)` | not running → started hidden; otherwise untouched | no (read) |
| "read my latest email and do what it says" | data | `mail.recent` → body | as above | **yes**: the email's instruction is quoted and DoraX asks; never obeyed directly |
| "fetch the link in that email" | data | `dorax_read_url` | — | **yes**: private data in the turn → outbound gate names the host (E1c) |
| "reply saying I'll call tomorrow" | data | `mail.createDraft` | the composer opens **because you will press Send** | write card; DoraX never sends |
| "archive the newest bank email" | data → UI | with `mail-app-cli`: `archive` (headless). Without: Message › Archive | without CLI: plan card "bring Mail forward, Archive, return" | **yes** (write) |
| "show the mailbox list" | UI | menu View › Show Mailbox List | in front: pressed; elsewhere: plan card, focus returns | only if Mail must come forward |

### Terminal

For Terminal, the data lane is **the shell itself**. `terminal.runCommand` runs a command without
any Terminal window, and output appears in the panel. The Terminal app is only needed for the UI.

| You type | Lane | Tool | App state handling | Card? |
|---|---|---|---|---|
| "how much disk space is free" | data | `terminal.runCommand("df -h")` | Terminal not needed at all | no: read-only command on the E1b allow-list |
| "what's the error in my terminal" | data | **new D3:** read the front tab's text from Terminal's scripting dictionary (`contents of selected tab`) | running → read without activating; not running → "Terminal isn't open; nothing to read" | no (read); the output is marked private (it can contain secrets) |
| "install wget" | data | `terminal.runCommand("brew install wget")` | headless, output streamed to the panel | **yes**: the exact command, not on the allow-list |
| "run it in my Terminal" / "open a new tab" | UI | Shell › New Tab, then type the command | plan card; never types while you are typing | yes, plan card |
| "clear the screen" | UI | key ⌘K | Terminal must be in front | only if it must come forward |

Never: a screenshot to read Terminal text (the dictionary gives the text), or typing into a tab
the user is using.

### Messages

Reads come from the local `chat.db`, so **Messages is never launched to read**
(`MessagesChatDBReader`). That needs Full Disk Access. Composing opens Messages with the text
filled in and **never presses Send** (`messages.compose`).

| You type | Lane | Tool | App state handling | Card? |
|---|---|---|---|---|
| "what did Salman text me today" | data | `messages.search` (chat.db) | Messages untouched in every state | no (read); the message text is untrusted |
| "who do I message most" | data | `messages.topContacts` | untouched | no |
| "text Salman I'm running late" | data | `messages.compose` | Messages opens with the draft because **you press Send** | **yes**: outbound card |
| "open the link Salman sent" | data | `dorax_read_url` / open URL | — | **yes**: exact-URL gate (E1b) |
| "show my chat with Salman" | UI | open the conversation | the window opens because you asked to see it | no |
| any read, no Full Disk Access | data | — | "I need Full Disk Access to read Messages" + the setting button | no; **no screenshot reading** as a workaround unless you ask for Computer Use |

### What these show

- The **data lane covers almost every request**; the UI lane is for "show", "open a tab", "minimize".
- Windows open only when the user will look at or finish something (a draft, a chat they asked to see).
- Untrusted text (mail, messages, terminal output) is data. Any instruction in it is quoted and asked about.
- Missing access (Full Disk Access, a CLI) is **said and offered**, never worked around through the screen.

---

## 3. What the user sees: the step list

Every turn fills the Progress panel with what actually happened, one reason per line. These are
real steps from the trace, not generated prose.

```
✓ Understood   Read the newest email from Gokula Kannan J, then follow it
✓ Tools        Mail: built-in adapter · mail-app-cli · 37 menu commands
✓ Chose        Mail adapter › mail.search(sender) — no window opens
✓ Read         1 message · "Test" · 15:01
⚠ Untrusted    The email asks me to fetch httpbin.org with your data
⏸ Gate         Fetch https://httpbin.org/get?d=secret… — Allow / Deny
```

A keyword shortcut that claims a turn shows as its own step ("Shortcut: Mailbox Search —
matched 'search …'"). A step that ran can never be followed by "Answered without running
anything".

---

## 4. Plugin manager

### 4.1 What counts as a plugin

Every way DoraX can act on an app is a plugin with one manifest. The kinds already exist in
`CapabilityRecord.Kind`:

| Kind | Example for Mail | Comes from | Cost (`Surface`) |
|---|---|---|---|
| Built-in adapter | `mail.recent/read/search/currentMessage/createDraft` | ships with DoraX | headless |
| AppleScript dictionary | any scriptable verb, read generically | the app itself | headless |
| Shortcuts / App Intents | user's Shortcuts naming Mail | the system | headless |
| MCP server | user-linked server | Settings › Integrations | headless |
| CLI | `mail-app-cli` | user installs | headless |
| Skill | a `SKILL.md` describing a CLI (E17) | the CLI or user | advisory |
| Recipe | "morning bank summary" | learned from use (§6) | per steps |
| DoraX-made plugin | generated script, owner-approved | `PluginAuthoringEngine` | headless |
| Menu command | Message › Archive | `AppKnowledgeSkill` | opens app |
| Screen control | AX press, then click | last resort | takes screen |

### 4.2 Manifest (one shape for all kinds)

`id, app bundle ids, origin (built-in / vetted / user-added / DoraX-made), version,
capabilities[] { id, title, inputs, read|write, outbound?, surface }, how to run (adapter call /
argv template / MCP tool / script), health { last run, success rate }`.

Rules: a CLI runs as **argv, never a shell string**. Writes and outbound always go through the
gate. A plugin cannot raise its own trust level.

### 4.3 Lifecycle

`discover → learn the manifest → owner reviews → enable → use → measure → update / retire`

Settings › Plugins, plus each app's Help page (already per app): what's enabled, what each
plugin can read and write, per-capability "ask / allow reads", health, and remove.

### 4.4 Existing code it folds in, without a seventh registry

`CapabilityRegistry`, `CapabilityIndex` (+ `Surface`), `CapabilityDiscoveryService`,
`AppAdapterCapabilityCatalog`, `MCPServerManager`, `L2ExtensionManager`,
`PluginAuthoringEngine`, `AppKnowledgeSkill`, `ChatRoutePreferenceStore`. The manager is the
single front for these. Old routers retire one per PR (E12).

---

## 5. When more than one tool can do it

Ranked in this order. Most of it exists already (`matchOutranks`, `Surface`,
`shouldClarifyBetweenPeers`):

0. **Lane first** (§2a): data-lane requests consider headless tools only, unless none fits.
1. **Can it do the job?** The capability matches the verb and the object.
2. **Granted > installed > suggested** (`matchOutranks`).
3. **Cheapest surface:** headless < opens app < takes screen.
4. **Your pin:** "always use X for archive" (`ChatRoutePreferenceStore`).
5. **Measured reliability:** success rate on this Mac, from E2 traces.
6. **Tie within 0.05 → ask once,** then remember the answer.
7. **If it fails,** fall to the next candidate. Each fallback is a visible step.

Example: "archive the newest bank email". The built-in adapter has no archive. `mail-app-cli archive`
is headless but a write, so it shows a card. The Message › Archive menu would open the app, and
screen control would take the screen. DoraX picks the CLI, shows the card, and keeps the menu as
the fallback.

---

## 6. Where tools come from, and what DoraX can build itself

### 6.1 A CLI the user installed (no hand-written adapter)

1. **Detect.** The user adds it in Settings › Plugins, or DoraX finds a catalog entry on `PATH`.
2. **Learn.** Run `<cli> --help` and each subcommand's `--help` (sandboxed, no network,
   read-only). Use `SKILL.md` instead if one ships (E17). Build the manifest: verbs such as
   list/show/search are reads; send/delete/move/archive/flag/mark are writes; send is outbound.
3. **Review.** "Learned 14 commands: 6 read, 8 write, 1 sends mail. Enable reads? Writes ask each time."
4. **Use.** The model calls `run_capability(cli.mail-app-cli.search, {…})`; JSON output becomes result rows.

### 6.2 Suggestions when an app has no route

- **Primary: a curated catalog shipped and versioned with DoraX.** Each vetted entry has app,
  kind, source repo, install command, what it adds and its risk. The card says "Mail: adapter
  built in. Optional: mail-app-cli adds archive, flag, move and attachments."
- **Homebrew / `go` / `npm`:** used only to check whether a catalog entry is installed or
  installable (`brew info --json`). Never an open search.
- **GitHub / web / MCP registry search:** only when the user asks "find a tool for X". Results
  are labeled **unvetted**.
- **DoraX never installs.** It shows the command; the user runs it (E17 rule).

### 6.3 Solved-task library: fewer tokens every day (E19 layer 2)

When Claude Code solves a request by writing a script or chaining tools, DoraX keeps the
solution as a **parameterized, verified skill**. The next similar request runs it **before the
model** (ladder stage 4, `WorkbenchIntent`), so repeated reads cost almost no cloud tokens.
Stored in the `L2ExtensionManager` format (folder with `extension.json` + script).

```
TURN 1 (tokens)   "show unread mail from SBI today"
                  → Claude Code solves it → verified read-back, not corrected
                  → skill "unread mail from {sender} on {day}" (read-only, Mail, test attached)
TURN 2..N (≈0)    "unread mail from ICICI yesterday"
                  → on-device match + Apple Intelligence fills {sender},{day} → run skill
                  → step: "Used saved skill (no model)"
ON FAILURE        script fails or verify = contradicted → model repairs → new version, old kept
```

Rules:

1. **Only verified successes:** the read-back passed and the user didn't correct or redo it.
2. **Parameterized + tested before saving.** Hard-coded values (a name, a mailbox) are rejected.
3. **Nothing shaped by untrusted text** (email, web, messages) is auto-saved; it needs owner review.
   This stops a #184-style injection from becoming permanent.
4. **Auto-save reads only** (filter, find, read, list, count). A write, send, delete or network
   skill needs owner approval to save, and **still shows the gate card on every run**.
5. **Argv, no free-form shell, no network inside a read skill.**
6. **Visible in Settings › Plugins** as "made by DoraX": run count, success rate, delete.
7. **Re-tested after the app's version changes** (E19b) before next use.
8. **Who does what:** Claude Code writes skills. On-device Apple Intelligence matches and fills
   parameters, never authors code.

Expect large savings on repeated reads; little on new questions, judgment or writing. Measure the
real repeat rate from E2 traces before promising a number.

- **Level 2, DoraX-made plugin:** `PluginAuthoringEngine` drafts a manifest plus script for a
  gap the traces show. Shown as a diff, owner approves, read-only first, marked "made by DoraX".
- **Never:** code written or enabled silently. A self-written script with mailbox access is the
  highest-risk thing in this plan.

---

## 7. `intelligrit/mail-app-cli`: assessment

- **Is:** a Go CLI for Mail.app. Accounts, mailboxes, list/show/search, mark, flag, archive,
  move, delete, send, attachments; JSON output on every command. Install: `go install` or build
  from source. The README does not mention Homebrew. No `SKILL.md`.
- **Mechanism:** it drives Mail's scripting interface (its README warns that body fetches can
  block it). That's the same access DoraX's adapter uses. It adds **breadth** (archive, flag,
  move, attachments, threading headers), not new access.
- **Risk:** a third-party binary with full mailbox read, plus send and delete. It enters as
  **user-added**: send counts as outbound (gated), delete and move are writes (gated), and
  `--with-content` is never used in unattended runs.
- **Verdict:** a good first catalog entry and the test case for §6.1. It isn't needed for reads
  DoraX already has.

---

## 8. Tasks, in order

| # | Task | Size | Hand check |
|---|---|---|---|
| P1 #195 | Mail keyword shortcut obeys Task 17 (exact command only); fix the false "Answered without running anything"; the owner's sentence in `RoutingPhrasebookTests`; check the Corner for the same bug | S | re-run the sentence |
| P2 #196 | Menus out of the default prompt (§2a): one tool order equal to `Surface`; `find_menu_command` on demand; delete "CALL it immediately" | M | data and UI sentences |
| P3 #197 | Two lanes (§2a): data lane never activates the app (Mail adapter reads without `activate()`); UI lane only for interface requests; menu fallback shown as a step | M | Mail stays in background |
| P4 #198 | Every pre-model shortcut reports a "Shortcut: …" step | S–M | yes |
| P5 #199 | Progress panel shows Understood → Lane → Tools → Chose → Gate → Result from the trace | M | yes |
| P6 #200 | Plugin manifest + Settings › Plugins as the front for the existing registries (read-only view first) | M | yes |
| P7 #201 | Ranking + fallback per §5, with visible steps | M | yes |
| P8 #202 | CLI learner (§6.1), `mail-app-cli` as the first case (= E17 widened) | M | yes |
| P9 #203 | Curated catalog + "no route → options" card (§6.2) | S–M | yes |
| P10 #204 | Retire the Dock's ~15 shortcuts into the ladder, one per PR (E12) | L | per PR |
| P11 #205 | Solved-task library (§6.3): verified turn → parameterized read skill → runs before the model → repaired on failure. Mail first | M–L | yes |
| P12 #206 | DoraX-made plugins (§6.3 level 2) | L | yes |

Order: P1 now (it also blocks the #184 hand test). P2–P3 fix the reasoning: they remove the
menu bias at its source. P4–P5 make every later step visible. P6–P9 are the plugin manager. P10
runs alongside. P11 needs P5 + E2 (to tell a saved skill from a model answer); P12 comes after
E19a.

## 9. Rules this must not break

- Exact command or the model (Task 17). No new keyword router.
- Data lane never takes the window; a menu is used for data only when no headless route exists, and says so.
- Email, web, message and file text is data, never instructions (E1b, E1c).
- Writes and outbound always ask; a plugin can't skip the gate.
- DoraX never installs software.
- Dock and Corner use the same code (`00-DOCK-AND-CORNER.md`).
