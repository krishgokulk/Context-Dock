# Agent Harness Model: the provider thinks, Context-Dock does

> **Date:** 2026-11-09
> **Status:** Draft. Direction given by the owner in chat on 2026-11-09 ("work like Claude / Codex,
> based on the frontmost app and context, with the AI provider's power; learn skills and reuse
> them; offline too"). The details below await owner approval and a Goldfish review (EGM)
> before any issue is marked `ready`.
> **Builds on (does not replace):**
> `docs/superpowers/specs/2026-11-03-unified-frontmost-app-agent-and-computer-use.md` (the 3-tier
> escalation ladder), `docs/superpowers/specs/2026-11-05-streamline-settings-and-extensions.md`
> (packs and Store), `docs/architecture/FRONTMOST_AGENT.md`, `docs/architecture/APP_KNOWLEDGE_SKILLS.md`.

---

## 1. Why this exists

The app has many words for its parts (app menus, actions, skills, packs, connectors, MCP, CLI
tools), and it is not obvious how they fit together around an AI provider. The owner's question:

> "Claude and Codex have connectors, skills, plugins and MCP, and the AI works perfectly there.
> We have the frontmost app with its skills, connectors, MCP and packs. When the AI is inside our
> app, how does it work? And menu clicks have real power: do we still need them?"

This spec answers that with **one model** that every future routing, tool and learning decision
is checked against.

---

## 2. The one model: brain and hands

An AI provider (Claude, OpenAI, Gemini, Ollama, the on-device Foundation Model) is **only a
brain**. Over an API it receives text and a list of tools, and it answers with text or with
"call tool X with these inputs". It never touches the Mac.

The Claude app and Codex feel powerful because they are **brain + harness**: the app around the
model gives it context, offers it tools, runs them, asks for permission and remembers. Their
connectors, skills, plugins and MCP live **in the app, not in the model**, so none of them come
along when Context-Dock calls the same model with an API key.

**Inside Context-Dock, Context-Dock is the harness.** The same brain is exactly as good as the
harness we build around it.

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
│ 4 TOOLS         small core + that app's connectors and MCP servers     │
│ 5 RUN           execute on the Mac · approval if risky · verify · learn│
└────────────────────────────────────────────────────────────────────────┘
        │                                       ▲
        ▼                                       │
   The Mac: apps, files, scripts, CLIs, MCP servers, web APIs
```

**The frontmost app is not a different AI or a different system.** It only decides *which
pieces are loaded into 1 to 4*. The loop, the approvals and the learning are the same
everywhere. This is the existing `AGENTS.md` rule ("App Pets are profiles over one engine")
stated from the model's side.

```
In Finder      →  global pieces  +  Finder's AGENT.md, skills, connectors, MCP
In Mail        →  global pieces  +  Mail's   AGENT.md, skills, connectors, MCP
General Chat   →  global pieces only (may borrow one app ability for one turn)
```

---

## 3. The words, once

| Word | What it is | Claude / Codex equivalent | Does the user need to think about it? |
|---|---|---|---|
| **Skill** | A saved way to do one job ("convert PDF to Word", "fix grammar") | Skill | **Yes — the one concept users should see** |
| **Tool** | Something the brain can call: run a script, read a file, call an MCP tool, press a menu item | Tool | No |
| **Connector** | A signed-in web service (API connection, UTCP) | Connector | Only to sign in |
| **MCP server** | A local or remote tool provider speaking MCP; the same protocol as Claude Code | MCP | Only to add one |
| **Pack** | A box that installs skills + connectors + MCP + AGENT.md for one app, or globally | Plugin | Only when installing or sharing |
| **Menu command** | One app feature reached through its menu bar | (none) | No: a route, not a feature list |
| **Context** | Frontmost app, selection, files, page | (folder, git status) | No: it is just "where you are" |

Context is what Context-Dock has and the Claude app does not: it knows what the user is doing on
their Mac right now.

---

## 4. One turn, end to end

```
 User, in Finder with report.pdf selected: "convert this to Word"
   │
   ▼
┌──────────────────────────────────────────────────────────────────┐
│ A. UNDERSTAND   app=Finder · selection=report.pdf (PDF) · lane=data │
└──────────────────────────────┬───────────────────────────────────┘
                               ▼
┌──────────────────────────────────────────────────────────────────┐
│ B. BUILD THE REQUEST (the context packet, §5)                    │
└──────────────────────────────┬───────────────────────────────────┘
                               ▼
┌──────────────────────────────────────────────────────────────────┐
│ C. LOOP   brain picks a route (§6) → harness runs it → result →  │
│           brain checks → next step … until done                  │
│           approval card before anything that changes or sends    │
└──────────────────────────────┬───────────────────────────────────┘
                               ▼
┌──────────────────────────────────────────────────────────────────┐
│ D. VERIFY  read back the effect (file exists, mail in Drafts …)  │
└──────────────────────────────┬───────────────────────────────────┘
                               ▼
┌──────────────────────────────────────────────────────────────────┐
│ E. LEARN   it worked and no saved skill was used → save the      │
│            route as a skill (§8). Next time step C starts at it. │
└──────────────────────────────────────────────────────────────────┘
```

---

## 5. What the request contains

Example for the turn above. Everything here is assembled by the harness. The brain sees no other
source of truth.

```
INSTRUCTIONS   Dora's rules · Finder AGENT.md
CONTEXT        Frontmost: Finder
               Selected files: ~/Desktop/report.pdf (PDF, 2.1 MB)
               Lane: data
SKILLS         (names + one line; full text via skills.read)
               - Convert PDF → DOCX          [learned]
               - Compress files to ZIP       [learned]
               - Finder: tags and metadata   [Finder pack]
TOOLS          look   read_selection · read_attachment · read_app_dictionary
               do     run_command · run_script (AppleScript / JXA)
               know   skills.read · find_capability
               click  run_menu_command · computer use (last)
               + this app's connectors and MCP tools
MENUS          Finder's menu titles available on request (not listed one tool per item)
```

Today, selected Finder files already reach the AI's context (`AI/AIContextBuilder.swift:139`,
`AI/AIProviderRouter.swift:901`), as do the per-app `AGENT.md` (`AppAgentProfileStore`) and
skills listed by name and read with `skills.read`. The harness already has this shape. §11
lists what is missing.

---

## 6. The route ladder (refines the 2026-11-03 ladder)

The 2026-11-03 spec has three tiers: headless, AI-written script, Computer Use. This spec adds a
rung at the top and splits the last tier in two, because a **menu command** and **Computer Use**
behave very differently.

```
 0  SAVED SKILL        A route that already worked for this kind of job.      fastest · offline
        │ none fits
 1  DIRECT DATA        Built-in capability, connector, MCP tool, CLI,         headless · no focus
        │              native framework (Mail, Calendar, Reminders …)         change
        │ none exists
 2  AI-WRITTEN SCRIPT  Brain reads the app's dictionary (sdef) and writes     headless · approval
        │              AppleScript / JXA, or a shell command for files.       if it changes things
        │ app not scriptable, or it is the app's own feature on the open document
 3  MENU COMMAND       Press one exact, cached, live-verified menu item.     app comes forward
        │ not in a menu
 4  COMPUTER USE       Accessibility clicks, typing, screen reading.          slowest · most fragile
```

The brain chooses. The ladder is the order its instructions tell it to prefer, not a hard-coded
router. That matches #204, which is retiring pre-model shortcuts into the ladder.

**One exception: the UI lane.** When the request is *about the interface* ("show the sidebar",
"open a new tab", "split view"; see `RequestLane.decide`, `Services/DataLane.swift:20`), the
menu is the correct first route, because the interface is the job.

---

## 7. Menu commands: kept, with two jobs

**Yes, we still need menus.** They are the one interface every Mac app has, including apps with
no AppleScript, no CLI and no MCP (most Electron apps, many pro apps). Some features exist *only*
there (for example "Clean Build Folder" in Xcode, or an export option a dictionary doesn't
expose). Dropping menus would make those apps unreachable.

Menus are just **not the first route**, for four reasons:

| Menus… | So |
|---|---|
| need the app frontmost, so they steal focus | not for data jobs (`DataLane.swift:38`) |
| return no data (a press is not a read) | the result must be verified separately |
| change with app version and system language | a saved menu route can go stale |
| do one press at a time | slower for multi-step jobs than a script |

They still rank **above Computer Use**: a menu press targets an exact item, is checked against
the cache and live-verified before pressing (`run_menu_command`, `AI/AgentToolRegistry.swift:2092`),
and is one action instead of a sequence of clicks.

### Job 1: knowledge (read, never press)

A menu bar is a list of what the app can do. Its titles feed `AppKnowledgeSkill`
(`Services/AppKnowledgeSkill.swift`: "a menu is a way to *do* something and was never a way to
*know* something"), and `AIPackSynthesizer` uses them to draft packs. Reading titles opens
nothing.

### Job 2: action (rung 3, or rung 1 in the UI lane)

One tool, `run_menu_command(app, path)`. Menu items are **not** offered as one tool per item and
**not** pasted wholesale into every prompt. The brain asks for the app's menu titles when it
needs them, the same way it reads a skill's full text only when needed.

### What this means for the UI

Menu commands stop being a *feature list* the user browses as the main way to get things done.
The user asks, and the brain may choose a menu. A menu browser can stay as a power-user view, but
it is not the product's centre.

---

## 8. Learning: save what worked

**Today:** `AI/ComputerUseSkillRecorder.swift` turns a successful run into a per-app skill
("Learned: …") automatically. It is called only from Computer Use (`ComputerUseTool.swift:361`,
`ComputerUseAXTools.swift:414`), so it learns **clicks**, the slowest rung. A script the brain
wrote and ran successfully (`AI/SynthesizedScriptTool.swift`, `run_command`) is not saved.

**Target:** save the route that worked on whichever rung it ran:

| Rung that worked | What the learned skill stores |
|---|---|
| 1 direct | Which capability, connector or MCP tool, with input names |
| 2 script | The script itself, with the specifics turned into blanks: `ditto -c -k --keepParent "{file}" "{file}.zip"` |
| 3 menu | The menu path, plus the app version it was seen on |
| 4 Computer Use | The steps (as today) |

Rules (the existing recorder already keeps the first two):

1. **Never store the user's content**: no typed text, no message bodies, no file contents. Only
   the route, with blanks for inputs.
2. **A Stop, a failure or a failed verify discards the run.**
3. **Scope by what it acts on, not only by app.** "Convert PDF → DOCX" belongs to *a selected PDF
   anywhere*, not only to Finder. A skill is scoped to an app, or to a selection type (text, PDF,
   image, any file), or global.
4. **Higher rung wins.** If a rung-4 skill exists and a rung-2 route later works for the same
   job, the new one replaces it.
5. **Replay safety.** A learned skill that changes, sends or deletes something shows the
   approval card the first time it replays and runs afterwards under the app's existing standing
   consent (`Settings → Integrations → Access`). Read-only skills just run.
6. **Visible and editable.** Learned skills sit with the app's skills in Settings and can be
   edited, disabled or deleted (as today).

---

## 9. Offline: learn online, replay offline

The on-device model is small. It is weak at inventing a correct script, but good at filling in
the blanks of a known one.

```
 First time (online)   strong cloud brain works out the route → it works → saved as a skill
 Next time (offline)   on-device brain sees the skill → fills {file} → harness runs it
```

So the **saved skill list and the small tool core must be offered to the on-device session too**
(`Services/OnDeviceToolBridge.swift`), not only to cloud providers. Whatever a user has done once
keeps working without WiFi.

---

## 10. A small tool core

Claude Code gives its model about five general tools; Bash covers everything nobody built a tool
for. `AgentToolRegistry` today registers 40+ named tools (`run_capability`,
`run_adapter_action`, `run_menu_command`, `find_capability`, `compose_message`, `send_mail`,
`create_reminder` …). A long menu of special cases makes the brain's choice harder, and that is
the same confusion the owner described from the user's side.

Target core, grouped by job:

| Group | Tools |
|---|---|
| **look** | read selection / attachment / page · read app data · read app dictionary · OCR / screen |
| **do** | run command (shell) · run script (AppleScript / JXA) · call connector / MCP tool |
| **know** | list / read skills · find capability · read menu titles |
| **click** | run menu command · Computer Use |

Specific tools such as `send_mail` stay where a dedicated tool is genuinely safer or faster (for
example, one with its own approval wording), but by default a specific job is a **skill** that
uses the core. The trim is gradual and measured: one tool at a time, with phrasebook tests
(`RoutingPhrasebookTests`) proving nothing regresses.

---

## 11. What exists, what is new

| Piece | Status | Where |
|---|---|---|
| Brain/harness loop | ✅ exists | `AI/AgentToolRegistry.swift`, `AI/AIProviderRouter.swift` |
| Per-app instructions | ✅ exists | `AppAgentProfileStore` (AGENT.md) |
| Selection and Finder files in context | ✅ exists | `AI/AIContextBuilder.swift:139`, `Services/ContextDetector.swift` |
| Data lane first | ✅ exists | `Services/DataLane.swift` |
| Skills by name, read on demand | ✅ exists | `SkillStore`, `skills.read` |
| AI-written scripts | ✅ exists | `AI/SynthesizedScriptTool.swift` (#368) |
| Menu press, verified | ✅ exists | `run_menu_command` |
| Menus as knowledge | ✅ exists | `Services/AppKnowledgeSkill.swift` |
| File type → CLI tools | ✅ exists | `Services/FileTypeToolRegistry.swift` |
| Packs bind to an app or global | ✅ exists | `Services/Plugins/StorePackInstaller.swift` |
| Approvals | ✅ exists | approval card, `AI/OutboundGate.swift` |
| **Rung 0: saved skill tried first** | 🆕 new | ladder instructions + skill lookup |
| **Learn scripts / direct routes, not only clicks** | 🆕 new | extend `ComputerUseSkillRecorder` (or a sibling) to rungs 1–3 |
| **Skills scoped by selection type** | 🆕 new | `SkillScope` (`Services/SkillScope.swift:90`: `app` / `surface` / `global` today) gains a selection-type case |
| **Learned skills on-device** | 🆕 new | `OnDeviceToolBridge` session gets skill list + core |
| **Tool core trim** | 🆕 new, gradual | `AgentToolRegistry` |
| **Menus: one tool + titles on demand everywhere** | 🔧 tighten | prompt assembly (`ScopedPromptAssembler`) |

---

## 12. Proposed work, in order (not filed until the owner approves)

Each line becomes one issue and one PR, following the current #204 pattern.

1. **H1: Learn the route that worked.** Record successful rung 1–3 routes as learned skills, with
   blanks for inputs and the replay-safety rule (§8). The biggest win, and self-contained.
2. **H2: Rung 0.** Ladder instructions tell the brain to check learned and installed skills first;
   phrasebook rows prove a learned job replays without re-solving.
3. **H3: Selection-scoped skills.** Learned skills about a selection type show up in any app with
   that selection.
4. **H4: Menus tightened.** One menu tool, titles on demand, no per-item tools, UI-lane-first only.
5. **H5: Learned skills on-device.** The on-device session gets the skill list and tool core, so
   replay works offline. Depends on #152 / #153 (E5) landing first.
6. **H6: Tool core trim.** Gradual, one tool per PR, measured with phrasebook tests.

H1 to H3 make the app feel like Claude Code. H5 is the offline promise. H6 is ongoing cleanup.

---

## 13. Open questions for the owner

1. **Learned skills: automatic or confirmed?** Save silently (as the recorder does today), or show
   a one-line "Saved as a skill: Convert PDF → DOCX · Undo"? *Recommendation: save silently,
   show the line.*
2. **Replay of changing skills:** approval on the first replay only, or every time? *Recommendation:
   first replay, then the app's standing consent.*
3. **Menu browser UI:** keep it as a power-user view, or remove it once H4 lands?
4. **Sharing:** can a user export learned skills as a pack for the Store? (Fits the 2026-11-05 pack
   schema; post-1.0.)

---

## 14. Not in scope

- A new shell, surface or per-mode container (the one-shell rule stands).
- Per-Pet model loops, registries or approval paths (`AGENTS.md`: one engine).
- Building a window manager. Window jobs are skills over scripts, the menu, or an installed
  tool's MCP / CLI (for example KiwiDesk's `kiwidesk-mcp`).
- Carrying a user's claude.ai connectors into the app. They belong to the Claude app, not to the
  API.
