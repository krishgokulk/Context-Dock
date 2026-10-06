# App agent and plugin manager: one flow for every frontmost app

**Status: proposal, 2026-10-06. Not adopted until the owner confirms.** Builds on
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
 ② UNDERSTAND  question / action / search; the objects (sender, message, file…).
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

### 6.3 Learning from use (E19 layer 2)

- **Level 1, recipes (safe, first):** the same chain of existing tools repeated 3 times →
  "Save as a Mail recipe?" No new code. It runs through the same gate.
- **Level 2, DoraX-made plugin:** `PluginAuthoringEngine` drafts a manifest plus script for a
  gap the traces show. Shown as a diff, owner approves, read-only first, marked "made by DoraX".
- **Never:** code written or enabled silently from usage. A self-written script with mailbox
  access is the highest-risk thing in this plan.

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
| P1 | Mail keyword shortcut obeys Task 17 (exact command only); fix the false "Answered without running anything"; the owner's sentence in `RoutingPhrasebookTests`; check the Corner for the same bug | S | re-run the sentence |
| P2 | Every pre-model shortcut reports a "Shortcut: …" step | S–M | yes |
| P3 | Progress panel shows Understood → Tools → Chose → Gate → Result from the trace | M | yes |
| P4 | Plugin manifest + Settings › Plugins as the front for the existing registries (read-only view first) | M | yes |
| P5 | Ranking + fallback per §5, with visible steps | M | yes |
| P6 | CLI learner (§6.1), `mail-app-cli` as the first case (= E17 widened) | M | yes |
| P7 | Curated catalog + "no route → options" card (§6.2) | S–M | yes |
| P8 | Retire the Dock's ~15 shortcuts into the ladder, one per PR (E12) | L | per PR |
| P9 | Recipes from repeated use (§6.3 level 1, E19 layer 2) | M | yes |
| P10 | DoraX-made plugins (§6.3 level 2) | L | yes |

Order: P1 now (it also blocks the #184 hand test). P2–P3 make every later step visible. P4–P7
are the plugin manager. P8 runs alongside. P9–P10 come after E19a.

## 9. Rules this must not break

- Exact command or the model (Task 17). No new keyword router.
- Email, web, message and file text is data, never instructions (E1b, E1c).
- Writes and outbound always ask; a plugin can't skip the gate.
- DoraX never installs software.
- Dock and Corner use the same code (`00-DOCK-AND-CORNER.md`).
