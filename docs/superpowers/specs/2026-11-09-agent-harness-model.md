# Agent Harness Model: the provider thinks, Context-Dock does

> **Date:** 2026-11-09 · **Revision 3** (Goldfish review 1: 7 blocking; review 2: 5 blocking; all
> addressed below)
> **Status:** Direction confirmed by the owner on 2026-11-09 ("work like Claude / Codex, based on
> the frontmost app and context, with the AI provider's power; learn skills and reuse them;
> offline too"). §13 records the owner's answers: two are revised for safety and need the owner's
> re-confirmation, and one is open. Work items H0–H6 (§12) are filed only after **both** a Goldfish
> approval **and** the owner's re-confirmation of §13.1–13.2 (as the 2026-11-09 row in
> `00-NOW.md` requires); none is `ready` until the owner labels it.
> **Extends:** #205 solved-task library (`docs/master/00-APP-AGENT-PLUGIN-PLAN.md` §6.3,
> `docs/engineering/205-solved-task-library.md`), whose rules stay in force.
> **Builds on:** `docs/superpowers/specs/2026-11-03-unified-frontmost-app-agent-and-computer-use.md`
> (the 3-tier ladder), `docs/superpowers/specs/2026-11-05-streamline-settings-and-extensions.md`
> (packs), `docs/architecture/FRONTMOST_AGENT.md`, `docs/architecture/APP_KNOWLEDGE_SKILLS.md`,
> `docs/architecture/SAFETY.md`.
> **Replaces:** see §14.

---

## 1. Why this exists

The app has many words for its parts (app menus, actions, skills, packs, connectors, MCP, CLI
tools), and it is not obvious how they fit together around an AI provider. The owner's question:

> "Claude and Codex have connectors, skills, plugins and MCP, and the AI works perfectly there.
> We have the frontmost app with its skills, connectors, MCP and packs. When the AI is inside our
> app, how does it work? And menu clicks have real power: do we still need them?"

This spec answers that with **one model** that every future routing, tool and learning decision
is checked against. Most of the machinery already exists. The spec mainly names it, orders it,
and closes the gaps in learning.

---

## 2. The one model: brain and hands

An AI provider (Claude, OpenAI, Gemini, Ollama, the on-device Foundation Model) is **only a
brain**. Over an API it receives text and a list of tools, and it answers with text or with
"call tool X with these inputs". It never touches the Mac.

The Claude app and Codex feel powerful because they are **brain + harness**: the app around the
model gives it context, offers it tools, runs them, asks for permission and remembers. Their
connectors, skills, plugins and MCP live **in the app, not in the model**, so none of them come
along when Context-Dock calls the same model with an API key.

**Inside Context-Dock, Context-Dock is the harness.** The code already says so
(`AI/FrontmostAppTaskPlan.swift`: "The model is the brain; Context-Dock is the safe native body").

```
┌─ AI PROVIDER (brain) ─ Claude · OpenAI · Gemini · Ollama · on-device ──┐
│  Thinks only. Never touches the Mac. The same brain in every app.      │
└────────────────────────────────────────────────────────────────────────┘
        ▲  tool result                          │  "call tool X(inputs)"
        │                                       ▼
┌─ CONTEXT-DOCK (harness) ─ our version of "the Claude app" ─────────────┐
│ 1 CONTEXT       frontmost app · selected text · selected files · page  │
│ 2 INSTRUCTIONS  Dora's rules + that app's AGENT.md                     │
│ 3 SKILLS        global + that app's + learned (names only; read later) │
│ 4 TOOLS         narrowed per turn + that app's connectors and MCP      │
│ 5 RUN           execute · classify · approve · verify · learn          │
└────────────────────────────────────────────────────────────────────────┘
        │                                       ▲
        ▼                                       │
   The Mac: apps, files, scripts, CLIs, MCP servers, web APIs
```

**The frontmost app is not a different AI or a different system.** It only decides *which
pieces are loaded into 1 to 4*. The loop, the approvals and the learning are the same
everywhere, which is the `AGENTS.md` rule ("App Pets are profiles over one engine") seen from the
model's side.

```
In Finder      →  global pieces  +  Finder's AGENT.md, skills, connectors, MCP
In Mail        →  global pieces  +  Mail's   AGENT.md, skills, connectors, MCP
General Chat   →  global pieces only (may borrow one app ability for one turn)
```

---

## 3. The words, once

| Word | What it is | Claude / Codex equivalent | Does the user need to think about it? |
|---|---|---|---|
| **Skill** | A saved way to do one job ("convert PDF to Word", "fix grammar") | Skill | **Yes: the one concept users should see** |
| **Tool** | Something the brain can call: run a script, read a file, call an MCP tool, press a menu item | Tool | No |
| **Connector** | A signed-in web service (API connection, UTCP) | Connector | Only to sign in |
| **MCP server** | A tool provider speaking MCP; the same protocol as Claude Code | MCP | Only to add one |
| **Pack** | A box that installs skills + connectors + MCP + AGENT.md for one app, or globally | Plugin | Only when installing or sharing |
| **Menu command** | One app feature reached through its menu bar | (none) | No: a route, not a feature list |
| **Context** | Frontmost app, selection, files, page | (folder, git status) | No: it is just "where you are" |

Under the word *skill*, the code has three kinds. Users see one list.

| Kind | What it holds | Runs by itself? | Code |
|---|---|---|---|
| **Instruction skill** | Know-how text (installed, from a pack, or app knowledge) | No: the model reads it | `AdapterSkill`, `SkillStore` |
| **Learned recipe** | Know-how written from a route that worked | No: the model reads it | `ComputerUseSkillRecorder` → `AdapterSkill` "Learned: …" |
| **Solved skill** | Typed tool calls with `{slots}`, from a verified turn | **Yes**, before the model, through the normal gates | `AI/SolvedSkill*.swift` (#205) |

---

## 4. One turn, end to end

```
 User, in Finder with report.pdf selected: "convert this to Word"
   │
   ▼
 A. UNDERSTAND   app=Finder · selection=report.pdf (PDF) · lane=data
   │
   ▼
 B. SOLVED SKILL? a solved skill of the same shape → replay its typed calls through the gates
   │             (no model call). Mismatch or failure → continue to C; the model repairs it.
   ▼
 C. BUILD        the context packet (§5)
   │
   ▼
 D. LOOP         brain picks a route (§6) → harness classifies, approves, runs → result →
   │             brain checks → … until done
   ▼
 E. VERIFY       read back the effect (file exists, draft saved …)
   │
   ▼
 F. LEARN        verified, nothing untrusted in the turn → a read is saved as a solved skill or
                 learned recipe, with "Saved as a skill · Undo"; a write is offered with
                 "Save as a skill?" (§8)
```

Step B exists today for app-scoped reads (`AI/AppScopedChatService.swift:1574`); step F exists
for reads (`AppScopedChatService.swift:1430`) and for Computer Use runs.

---

## 5. What the request contains

Example for the turn above. The harness assembles all of it; the brain has no other source of
truth. Tool names are the real ones.

```
INSTRUCTIONS   Dora's rules · Finder AGENT.md
CONTEXT        Frontmost: Finder
               Selected files: ~/Desktop/report.pdf (PDF, 2.1 MB)
               Lane: data
SKILLS         (names + one line; full text via skills.read)
               - Convert PDF → DOCX          [learned]
               - Compress files to ZIP       [learned]
               - Finder: tags and metadata   [Finder pack]
TOOLS          (narrowed for this turn by FrontmostAppTaskPlan)
               look   read_selection · read_attachment · read_file · find_files · read_app_dictionary
               do     run_command · run_synthesized_script · run_mcp_tool · run_capability
               know   skills.read · find_capability · find_menu_command
               click  run_menu_command · operate_app · ax_act   (Computer Use last)
               + this app's connectors and MCP tools
```

Selected Finder files already reach the turn's context (`AI/AIContextBuilder.swift:139`;
detection in `Services/ContextDetector.swift`). Per-turn tool narrowing already exists
(`AI/FrontmostAppTaskPlan.swift:199-239`).

---

## 6. The route ladder (refines the 2026-11-03 ladder)

The 2026-11-03 ladder has three tiers: headless, AI-written script, and Computer Use. This spec
adds a rung at the top and splits the last tier in two, because a **menu press** and **Computer
Use** behave very differently.

```
 0  SKILLS          solved skill replays before the model (§4 B);
        │           learned recipes and instruction skills tell the model which route worked
        │ none fits
 1  DIRECT DATA     built-in capability · connector · MCP tool · CLI · native frameworks
        │           headless, no focus change
        │ none exists
 2  AI SCRIPT       brain reads the sdef and writes AppleScript / JXA (run_synthesized_script),
        │           or a shell command for files (run_command): classified + approved per run
        │ app not scriptable, or the job is the app's own feature on the open document
 3  MENU PRESS      one exact, cached, live-verified item (run_menu_command)
        │           needs AppAccessPolicy .verifiedMenu for that app; approval card every press
        │ not in a menu
 4  COMPUTER USE    Accessibility clicks, typing, screen reading
                    needs Computer Use switched on for that app (SAFETY.md)
```

The brain chooses. The ladder is the order its instructions say to prefer, not a hard-coded
router, which matches #204 retiring pre-model shortcuts into the ladder.

**One exception: the UI lane.** When the request is *about the interface* ("show the sidebar",
"split view"; `RequestLane.decide`, `Services/DataLane.swift:20`), the menu is the right first
route, because the interface is the job.

---

## 7. Menu commands: kept, with two jobs

**Yes, we still need menus.** They are the one interface every Mac app has, including apps with
no AppleScript, no CLI and no MCP (most Electron apps, many pro apps). Some features exist only
there. Without menus those apps are unreachable.

They are not the first route:

| Menus… | So |
|---|---|
| need the app frontmost, so they take focus (`DataLane.swift:38`) | not for data jobs |
| return no data (a press is not a read) | the result is verified separately |
| change with app version and system language | saved menu routes record the app version (§8 rule 6) |
| do one press at a time | slower than a script for multi-step jobs |

They rank **above Computer Use**: one exact item, checked against the cache and live-verified
before pressing (`AI/AgentToolRegistry.swift:2092`), gated by `AppAccessPolicy .verifiedMenu`
(`:2186`), and approved on every press (`approval: .ask`, `:2198`).

**Job 1: knowledge (read, never press).** A menu bar lists what an app can do. Its titles feed
`AppKnowledgeSkill` and `AIPackSynthesizer`. Reading titles opens nothing.

**Job 2: action.** One tool, `run_menu_command(app, path)`. The model finds items with
`find_menu_command` when it needs them. Menu items are **not** offered as one tool per item, and
the menu snapshot is **not** pasted into every prompt (this changes the 2026-11-03 spec; see §14).

**UI:** the menu browser stays as a power-user view (§13.3, open), but it is no longer the
main way to get things done. The user asks; the brain may choose a menu.

---

## 8. Learning: save what worked

### Today

| Mechanism | Saves | Limits |
|---|---|---|
| Solved skill (#205) | Verified **read** turns as typed tool calls with `{slots}`, replayed before the model | Reads only; app scope; Mail first |
| Learned recipe (`ComputerUseSkillRecorder`) | Computer Use steps, **including menu presses** (`ComputerUseTool.swift:361`, `describeMenu`) | Name taken from the model's free `reason` text; de-duplicated by name only; no verify-discard |
| AI scripts (`run_synthesized_script`, `run_command`) | **Nothing** | `FRONTMOST_AGENT.md` §7 item 4 claims Tier 2 auto-capture; it does not exist (corrected, §14) |

### Target

| Route that worked | Saved as | Why that kind |
|---|---|---|
| 1 direct (capability, connector, MCP) | **Solved skill**: typed calls with `{slots}` | Already typed; #205 rule 5 holds |
| 3 menu press | **Solved skill**: a typed `run_menu_command` call, path fixed | Typed, verified at replay |
| 2 AI script | **Learned recipe**: the script's *shape* as know-how, e.g. "Finder: zip `{file}` with `ditto -c -k --keepParent`" | #205 rule 5 forbids replaying free-form shell. A **cloud** model re-emits the script, which is classified and approved like a fresh one (#205 rule 8: on-device never authors code) |
| 4 Computer Use | **Learned recipe** (as today) | UI steps need the model |

A learned recipe never runs by itself. It only makes the next turn's cloud model fast and
correct. A solved skill runs by itself, but only through the same executor, gates and approvals
as a model-chosen call. A script that proves worth keeping can later become a typed,
owner-approved DoraX-made plugin (#206 P12), and then it replays like any solved skill.

### Rules

#205's rules 1–8 (`00-APP-AGENT-PLUGIN-PLAN.md` §6.3, owner plan of 2026-10-06) apply to every
learned skill: recipes as well as solved skills. In particular:

- **Rule 4: reads auto-save; writes do not.** A skill that writes, sends, deletes or reaches the
  network is never saved silently. The turn offers "Save as a skill?" and saves only on the user's
  yes, and the skill still shows the gate card on every run.
- **Rule 8: on-device never authors code.** It may match a skill and fill its slots, nothing more.

This spec adds or tightens:

1. **Verified success only.** A Stop, a failure or a failed read-back discards the run. *(New for
   the recorder: it tracks only `lastSucceeded` today.)*
2. **Nothing from an untrusted turn.** If the turn read untrusted content (email, web page;
   `UntrustedContent.containsFence` over the answer or any receipt), nothing is saved. This is
   #205 rule 3, extended to the recorder.
3. **No user content, deterministic blanks.** Specifics become `{slots}` through deterministic
   code, never through the model. Today `SolvedSkillCapture.derive`
   (`AI/SolvedSkillCapture.swift:112-151`) only knows `{sender}` and `{day}`, and it treats any
   capitalised word as a sender ("convert this to Word" → `{sender}=Word`). **H0** generalises it:
   - **Context slots first, taken from the turn's context, not from words:** `{selection}`
     (selected text), `{file}` / `{files}` (selected or attached paths, from `ContextDetector`),
     `{app}`. A request word that refers to them ("this", "it", "these", the file's own name) is
     replaced by the slot.
   - **Word slots second:** `{day}` everywhere. `{sender}` only in Mail and Messages scopes, so a
     product name in another app is never taken for a person.
   - A value that would remain in a recipe and is neither a slot nor an app/route word (a file
     name, an address, a recipient) blocks the save under #205 rule 2. "App/route word" means a
     word that appears in the route itself (tool name, capability id, menu path, script keyword)
     or in the request's command words (`ExactCommand.commandWords`); anything else that looks
     like a name, path, address or number is a value. H0's tests pin the list down.
   - Matching must see the same context: `SolvedSkillMatch.match` takes only `query`,
     `bundleId` and `skills` today (`AI/SolvedSkillMatch.swift:25`), so H0 adds the turn's
     context (selection, files) to it.

   Names and summaries come from a template (app + route + slot-lifted request shape), **not**
   from the model's `reason` text, which can carry file names or recipients. *(Fixes the
   recorder's naming at `ComputerUseSkillRecorder.swift:44,102,120`.)*
4. **One job, one key.** A job's key is *(scope, slot-lifted request shape)*, built by the H0
   deriver. Example: "zip this" with `report.pdf` selected becomes key *(Finder, `zip {file}`)*.
   For the same key the order is: user-installed or pack skill › solved skill › learned
   recipe. Within learned skills, a lower rung number replaces a higher one, and a newer success
   on the same rung replaces an older one.
5. **Replay is gated like a fresh run. There is no new grant.** Reads run. Anything that changes
   something shows the normal approval card on every run, unless the user already gave that exact
   action an existing "always allow" (`AdapterActionConsentStore`). **Delete and send never get a
   standing grant** (SAFETY.md). Every script replay goes through `TerminalAIBridge`
   classification; every menu press asks; outbound calls pass `OutboundGate`.
6. **Staleness.** A solved skill re-binds live on every run and falls back to the model on any
   mismatch, which repairs it (#205 rule 7). A learned recipe records the app version it was
   learned on. After an app version change, or two failures in a row, it is disabled and
   relearned on the next success.
7. **Visible and undoable.** Each automatic (read) save shows "Saved as a skill: … · Undo" in
   the turn (Undo deletes it). A write skill is offered with "Save as a skill?" instead (rule 4
   above). #205 rule 6 said "Settings › Plugins, made by DoraX", but that page is now **Store /
   Packs** (Extensions section, `UI/Settings/SettingsModels.swift:32,173-180`, 2026-11-05
   consolidation), which is for community packs. So learned skills are listed with **their app**:
   *Settings › Extensions › Apps › the app › Resources*, in a **"Made by DoraX"** group with run
   count, success rate and delete, where the recorder's skills already appear. Global and
   selection-scoped learned skills get the same group on the Global page. This departs from the
   letter of #205 rule 6 (one place, named for a page that no longer exists) but keeps its intent.
8. **Shared skills arrive inert** (post-1.0): an imported learned skill cannot run until the user
   turns it on, and each run is approved (SAFETY.md, "Scripts an app carries are inert").

### Scope by selection type

"Convert PDF → DOCX" belongs to *a selected PDF anywhere*, not only to Finder. `SkillScope`
(`Services/SkillScope.swift:90`: `app` / `surface` / `global`) is derived from `AdapterSkill`
fields and never stored twice (`:87-88`), so a selection-type scope needs a **new stored field and
a persistence migration**, for both `AdapterSkill` and `SolvedSkill`.

---

## 9. Offline: learn online, replay offline

The on-device model is small, and #205 rule 8 says it never authors code: it matches a skill
and fills its slots. So what works offline is exactly what can run **without anyone writing a
script**:

```
 First time (online)   cloud brain works out the route → verified → saved (§8)
 Next time (offline)   SOLVED SKILL (typed calls: direct, connector*, MCP, menu press)
                         → on-device matches it, fills {slots} → harness runs it, gated  ✅
                       LEARNED RECIPE for a script (rung 2) or Computer Use (rung 4)
                         → needs a cloud model to re-emit the steps                      ⛔ offline
                       * a connector needs the network anyway; local routes are the offline set
```

A script that users rely on offline gets there by becoming a typed, owner-approved DoraX-made
plugin (#206 P12). After that it is a solved-skill route like any other.

Constraints the H5 work must meet:

- **Budget:** the on-device context budget is 1,500 characters (SAFETY.md, `AIContextBudget`).
  Only the names of the few skills relevant to this turn fit, never the full list.
- **One tool set:** `OnDeviceToolBridge` keeps its own tool copies (`ShellCommandTool`,
  `ExecuteAppMenuPathTool` …). H5 must reuse the shared `AgentToolRegistry` definitions instead of
  adding more copies (`AGENTS.md`: never a second copy).
- **Gate:** on-device tools are not covered by the outbound gate today (SAFETY.md). That must be
  closed before learned skills replay on-device.
- **Order:** H5 waits for E5 (#152 / #153) and the owner's open E5 answer.

Solved skills need no model at all, so they work offline as soon as they exist.

---

## 10. A small tool core

Claude Code gives its model about five general tools. Context-Dock has about 42 named tools (22 in
`AgentToolRegistry.swift`, the rest in its extensions). `FrontmostAppTaskPlan` already narrows
the set per turn (`:199-239`).

Target: specific tools stay where a dedicated tool is genuinely safer or clearer (for example
`send_mail` with its own approval wording). Otherwise a specific job becomes a **skill** that uses
the core (look · do · know · click, §5). The trim is gradual: one tool per PR, proven by
`RoutingPhrasebookTests`.

---

## 11. What exists, what is new

| Piece | Status | Where |
|---|---|---|
| Brain/harness loop, per-turn tool narrowing | ✅ | `AgentToolRegistry`, `FrontmostAppTaskPlan.swift:199-239` |
| Per-app instructions | ✅ | `AppAgentProfileStore` (AGENT.md) |
| Selection and Finder files in context | ✅ | `AIContextBuilder.swift:139`, `ContextDetector` |
| Data lane first | ✅ | `DataLane.swift` |
| Skills by name, read on demand | ✅ | `SkillStore`, `skills.read` |
| Solved skills: capture + replay before the model (reads) | ✅ | `SolvedSkill*.swift`, `AppScopedChatService.swift:1430,1574` |
| Learned recipes from Computer Use (incl. menu presses) | ✅ | `ComputerUseSkillRecorder` |
| AI-written scripts | ✅ | `SynthesizedScriptTool.swift` |
| Verified menu press, menu search | ✅ | `run_menu_command`, `find_menu_command` |
| **General slot deriver (context slots)** | 🆕 | H0 |
| **Recipes from AI scripts** | 🆕 | H1a |
| **Recorder safety: verify-discard, untrusted guard, templated names** | 🆕 | H1a |
| **Solved skills for menu presses and connector/MCP calls** | 🆕 | H1b |
| **"Saved as a skill · Undo" line** | 🆕 | H1c |
| **Job key, conflict order, staleness** | 🆕 | H2 |
| **Selection-type scope (stored field + migration)** | 🆕 | H3 |
| **Menus: no per-item tools, no snapshot in every prompt** | 🔧 | H4 |
| **Solved skills matched and filled on-device** | 🆕 | H5 |
| **Tool core trim** | 🔧 | H6 |

---

## 12. Work, in order

One issue and one PR each, following the #204 pattern.

| # | Item | Depends on | Check |
|---|---|---|---|
| **H0** | General slot deriver: context slots (`{selection}`, `{file}`, `{files}`, `{app}`), `{sender}` only in Mail/Messages, leftover-value block; `SolvedSkillMatch.match` takes turn context (§8 rule 3) | — | tests (incl. "convert this to Word" ≠ `{sender}`) |
| **H1a** | Learned recipes from AI scripts (rung 2) + recorder safety (verify-discard, untrusted guard, templated names, reads auto-save / writes offered) | H0 | tests |
| **H1b** | Solved skills for typed menu presses and connector/MCP calls (reads first; writes per #205's deferred slice, gated every run) | H1a | tests |
| **H1c** | "Saved as a skill · Undo" / "Save as a skill?" in the turn; "Made by DoraX" group in the app's Resources (and Global) | H1a | screenshot vs. reference (`AGENTS.md`) |
| **H2** | Job key + conflict order + staleness / auto-disable | H1a, H1b | tests |
| **H3** | Selection-type scope: stored field + migration | H2 | tests incl. migration |
| **H4** | Menus: no per-item tools, no prompt snapshot, UI lane first | #204 (PR #402) | phrasebook tests |
| **H5** | Solved skills matched and filled on-device (no code authoring): shared tool definitions, budget, outbound gate | E5 #152/#153 + owner E5 answer | tests + hand check offline |
| **H6** | Tool core trim, one tool per PR | H4 | phrasebook tests |

---

## 13. Owner decisions (2026-11-09)

The owner answered "Yes. Go on" to the recommendations on 2026-11-09.

1. ⚠️ **Narrowed, needs the owner's re-confirmation.** The owner accepted "learned skills are
   saved automatically, with a 'Saved as a skill · Undo' line". #205 rule 4 (owner plan,
   2026-10-06) allows automatic saving for **reads only**. The spec now auto-saves reads and
   *offers* writes ("Save as a skill?"). The owner may explicitly override this; until then, the
   earlier rule wins.
2. ⚠️ **Revised, needs the owner's re-confirmation.** The recommendation the owner accepted was
   "approval on the first replay only, then standing consent". The Goldfish review showed that
   this conflicts with SAFETY.md (destructive actions never get standing grants; every script run
   is approved) and with #205 rule 4 (owner plan, 2026-10-06: writes gate every run). The spec now
   follows those rules (§8 rule 5): **replay is gated exactly like a fresh run, and there is no new
   grant type.** Friction stays low because reads run freely, solved skills skip the model, and
   the existing per-action "always allow" still applies where it applies today. The owner may
   explicitly override this; until then, the safety rule wins.
3. ❓ **Open:** keep the menu browser as a power-user view, or remove it after H4? No
   recommendation yet. Until decided, it stays.
4. ✅ **Sharing learned skills as a Store pack is post-1.0**, and shared skills arrive inert.

---

## 14. Changes to earlier documents

| Document | Changed | Now |
|---|---|---|
| 2026-11-03 spec §5.2, third bullet | "Surface live menu commands to the AI provider as accessible tools" | One `run_menu_command` tool; items found with `find_menu_command` (§7) |
| 2026-11-03 spec §6 Phase 1 | "live menu snapshot into the turn prompt" | No snapshot in every prompt; titles on demand |
| 2026-11-03 spec §3 Tier 3 | Menus and Computer Use as one tier | Split into rung 3 (menu press) and rung 4 (Computer Use) |
| `FRONTMOST_AGENT.md` §7 item 4 | Claimed Tier 2 scripts are auto-captured | Corrected: only Computer Use is captured today; scripts are H1a |
| `00-APP-AGENT-PLUGIN-PLAN.md` §6.3 rule 6 | Learned skills listed in "Settings › Plugins" | Listed in the app's Resources, "Made by DoraX" group (§8 rule 7); the named page no longer exists |

#205's rules are **not** changed. This spec extends where they apply.

---

## 15. Not in scope

- A new shell, surface or per-mode container (the one-shell rule stands).
- Per-Pet model loops, registries or approval paths (`AGENTS.md`: one engine).
- A second skill store or replay engine: everything extends `SkillStore` and `SolvedSkill*`.
- Building a window manager. Window jobs are skills over scripts, the menu, or an installed
  tool's MCP / CLI (for example KiwiDesk's `kiwidesk-mcp`).
- Carrying a user's claude.ai connectors into the app. They belong to the Claude app, not to the
  API.
