# 00 — Project Tree: every folder, one job

> The DoraX layout drawn the way the popular "AI agent project structure" posters draw it:
> one line per folder saying what it is for. Two trees: **the app** and **the agent harness**
> (`.claude/`). Detail behind each line: [`00-APP-STRUCTURE.md`](00-APP-STRUCTURE.md),
> [`00-ENGINEERING-OPERATING-MODEL.md`](00-ENGINEERING-OPERATING-MODEL.md).
> Items marked **NEW** do not exist yet.

---

## 1. The app

```
Context-Dock/                                  repo root
├── README.md                                  what DoraX is, install, 60-second video
├── AGENTS.md                                  the ONE rulebook for Claude + Codex
├── CLAUDE.md                                  3 lines: @AGENTS.md + Claude-only notes
├── MEMORY.md                        NEW       shift log: what each session did, what is next
├── CHANGELOG.md                               user-facing change per release
├── .gitignore                                 *.dmg, .build/, settings.local.json
│
├── Context-Dock/                              THE APP (UI + wiring only)
│   ├── App/                                   entry point = "main.py": launch, hotkeys, routing
│   ├── Shell/                                 the one dock window, input, rows, animation
│   ├── Surfaces/
│   │   ├── Find/                              search + launch + front-app commands
│   │   ├── Ask/                               AI chat (dock sheet + window)
│   │   ├── ActOnThis/                         selection + clipboard actions
│   │   └── Labs/                              experiments, off by default
│   ├── Settings/                              one file per settings page
│   ├── Onboarding/                  NEW       first-run: permissions, provider, first task
│   └── Resources/                             assets, Info.plist, entitlements, Prompts/ (NEW)
│
├── Packages/                        NEW       the brain, split so layers can't tangle
│   ├── DoraXEngine/                           = "agent/ + models/ + prompts/"
│   │   ├── Loop/                              tool loop, turn runner, budget, receipts
│   │   ├── Planner/                           multi-step plans, saved workflows
│   │   ├── Providers/                         Apple, Anthropic, OpenAI, Ollama… clients
│   │   ├── Grounding/                         prompt builders (templates in Resources/Prompts)
│   │   ├── Verification/                      "did it really happen?" read-backs
│   │   └── Safety/                            approvals, risk levels, authority
│   ├── DoraXCapabilities/                     = "tools/": what DoraX can DO
│   │   ├── Menus/  Adapters/  MCP/            drive app menus, app adapters, MCP servers
│   │   ├── Terminal/  Shortcuts/  Files/      CLI (approval-gated), Shortcuts, Finder
│   │   └── AppleApps/                         Notes, Reminders, Calendar, Contacts, Mail
│   ├── DoraXContext/                          what DoraX can SEE: AX, selection, web page
│   ├── DoraXMemory/                           Markdown memory vault
│   └── DoraXCore/                             = "utils/": models, storage, keychain, logging
│
├── Context-DockTests/                         app-level tests (surfaces, UI state)
├── Tests/Corpus/                    NEW       = "data/": golden AI eval set (200 requests)
├── Context-DockExtension/                     Safari Web Extension
│
├── docs/
│   ├── README.md                              start here: map of all docs
│   ├── product/                               vision, features (F1…B8), roadmap, pricing
│   ├── architecture/                          how it is built — true today
│   ├── surfaces/                              one doc per surface
│   ├── engineering/                           workflow, code rules, testing, release
│   ├── decisions/                             one short file per decision
│   ├── specs/  plans/                         per feature, before building
│   ├── runbooks/                              ship, diagnose a turn, notarize
│   ├── history/                               finished audits, old plans
│   └── assets/                                images, diagrams, mockups
│
├── scripts/
│   ├── dev-run.sh                             = "run.sh": build Debug + relaunch
│   ├── check.sh                     NEW       build + fast tests + file-size check
│   ├── test.sh                                full test suite
│   ├── ship.sh                                release from main — OWNER ONLY
│   └── bootstrap.sh                 NEW       = "install.sh": set up a new Mac in one line
│
└── .github/
    ├── workflows/build.yml                    CI: build + tests + corpus score (tests NEW)
    ├── pull_request_template.md               issue, feature id, test, doc, changelog
    └── ISSUE_TEMPLATE/                        bug, feature, chore
```

### What we deliberately do NOT copy from Python agent templates

| Poster item | DoraX instead | Why |
|---|---|---|
| `.env` for API keys | macOS **Keychain** (`KeychainStore`) | keys never touch a file, not even locally `[code]` |
| `requirements.txt` | Swift Package Manager (Xcode resolves SwiftTerm) | Swift, not Python |
| `docker-compose.yml` | nothing | a Mac app has no server to run |
| `api/` | `DoraXMCPServer` inside Capabilities | DoraX exposes itself over MCP, not HTTP `[code]` |
| `logs/` in the repo | `~/Library/Application Support/Context-Dock/turns.log` | logs name the user's apps and questions — they never go in git |
| `prompts/*.py` | `Resources/Prompts/*.md` (NEW) | prompts today live inside Swift strings (`ScopedAppPromptBuilder`); as files they can be diffed and evaluated |

---

## 2. The agent harness

```
.claude/                                       how AI agents work on DoraX
├── CLAUDE.md                                  contract: points to AGENTS.md
├── settings.json                              shared permissions + hooks (generic, no personal paths)
├── settings.local.json                        your machine only — git-ignored
├── hooks/                           NEW       reflexes that enforce the rules
│   ├── pre-tool-use.sh                        block: ship.sh, rm -rf, push to main, stash, reset --hard
│   ├── post-tool-use.sh                       format changed Swift files, log what ran
│   ├── stop.sh                                run scripts/check.sh — no turn ends on a broken build
│   └── graphify-guard.sh                      today's graphify hook, via $HOME not /Users/<name>
├── agents/                          NEW       subagents, each in a fresh context
│   ├── planner.md                             issue → spec + plan with "done when"
│   ├── reviewer.md                            reviews a PR it did not write
│   ├── verifier.md                            runs the app, checks the acceptance test
│   └── doc-keeper.md                          keeps docs/ true to the code
├── skills/                                    muscle memory
│   ├── graphify/  caveman*/                   already installed
│   ├── swiftui-pro/  swift-concurrency-pro/   today in root skills/ — move here so they auto-load
│   ├── app-intents/  *-accessibility-auditor/ same
│   ├── dorax-where-does-it-go/      NEW       the layer rule: which folder/package a file belongs in
│   ├── dorax-add-command/           NEW       add a feature as one Command (search + AI + ⌘K)
│   ├── dorax-diagnose-turn/         NEW       read turns.log to explain an AI turn
│   └── dorax-eval/                  NEW       run + extend the golden corpus
└── .mcp.json                        NEW       project MCP tools (XcodeBuildMCP), not only in ~/.claude
```

### Today vs this tree `[code]`

| Piece | Today | Change |
|---|---|---|
| Rulebook | `CLAUDE.md` 310 lines + `AGENTS.md` 285 lines, drifted by 131 lines | one `AGENTS.md`, `CLAUDE.md` imports it |
| `settings.json` | 150 one-off allow rules, 25 with `/Users/gokulakannan/`, allows `ship.sh` and `rm -rf` | generic rules shared; personal ones local; deny list |
| Hooks | inline in `settings.json`, hard-coded path | scripts in `hooks/`, portable |
| Subagents | none in the repo | planner, reviewer, verifier, doc-keeper |
| Skills | caveman + graphify in `.claude/skills/`; 7 vendored skills sit in root `skills/` and never auto-load | all in `.claude/skills/` + 4 DoraX-specific |
| MCP | XcodeBuildMCP in your user settings only | `.mcp.json` in the repo |
| Cross-session memory | "current sequence" in CLAUDE.md, "brain issues" | `MEMORY.md` shift log + GitHub milestone |

`MEMORY.md` rule: append-only, dated entries (`2026-09-24 · session · did · next · blocked`), so
several agents can write without overwriting each other.
