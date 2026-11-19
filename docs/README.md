# docs/

Documentation index for Context-Dock (DoraX). AI agents: orient here before reading source.

## 1. Master docs (`docs/master/`)

| File | Purpose |
|---|---|
| `DORAX-BLUEPRINT.md` | Full product, architecture, code, docs, workflow and 15-week plan |
| `00-NOW.md` | Current tasks in order; owner decisions |
| `00-MODEL-ROUTING.md` | Which model per job; subagent configuration |
| `00-DOCK-AND-CORNER.md` | Dock and Corner shell rules; read before touching either |
| `00-ENGINEERING-OPERATING-MODEL.md` | How work is done |

## 2. Architecture truth (`docs/architecture/`)

Stable, implemented facts. These files are the canonical source for how the system works today.

| File | Subject |
|---|---|
| `AI_TURN_LIFECYCLE.md` | End-to-end turn lifecycle through TurnEngine |
| `CHAT_SCOPES.md` | ConversationScope, App Pet vs General Chat vs Combined Chat |
| `FRONTMOST_AGENT.md` | Frontmost-app agent and computer-use escalation |
| `PLUGINS.md` | `.doraxpack` v2 plugin system |
| `SAFARI_TODAY.md` | Safari dual-engine browser architecture |

## 3. Active specs (`docs/superpowers/specs/`) and Historical Archive

### Active specs (October–November 2026)

These specs document decisions still being implemented or recently landed. They are the live
design record — coding agents may read them.

| File | Subject |
|---|---|
| `2026-10-27-app-pets-combined-chat-design.md` | App Pets & Combined Chat canonical design |
| `2026-10-28-pet-presentation-and-expansion-lifecycle.md` | Pet presentation and expansion lifecycle |
| `2026-11-03-dynamic-bar-notch-and-liquid-glass.md` | Dynamic bar, notch, and Liquid Glass |
| `2026-11-03-unified-frontmost-app-agent-and-computer-use.md` | Unified frontmost agent + computer-use |
| `2026-11-04-one-app-perfect-flow-messages.md` | One-app perfect-flow message routing |
| `2026-11-05-streamline-settings-and-extensions.md` | Streamlined settings & extensions |
| `2026-11-08-issue-204-retire-mail-question-shortcut.md` | Retire Mail question shortcut (issue #204) |
| `2026-11-08-issue-204-retire-menu-command-shortcut.md` | Retire menu-command shortcut (issue #204) |
| `2026-11-08-issue-257-headless-dock-engine.md` | Headless Dock engine (issue #257) |
| `2026-11-08-issue-77-test-host-corner-decoupling.md` | Test-host / Corner decoupling (issue #77) |
| `2026-11-08-issue-83-selection-action-source.md` | Selection action source (issue #83) |
| `2026-11-09-agent-harness-model.md` | Agent harness model |
| `2026-11-09-issue-204-retire-messages-shortcut.md` | Retire messages shortcut (issue #204) |
| `2026-11-10-issue-204-retire-mailbox-search-shortcut.md` | Retire mailbox-search shortcut (issue #204) |
| `2026-11-10-unified-spotlight-pet-surface.md` | Unified Spotlight + Pet surface |

### Historical Specs Archive (`docs/history/specs/`)

> [!CAUTION]
> **DO NOT use these files for implementation.** They contain retired terminology and obsolete
> patterns. Preserved for provenance only.

See [`docs/history/specs/README.md`](history/specs/README.md) for the full table of archived
August–September 2026 specs and their modern successors.

## 4. Engineering docs (`docs/engineering/`)

| File | Purpose |
|---|---|
| `codebase.md` | How the code is laid out today |

## 5. Runbooks (`docs/runbooks/`)

Operational guides: ship a release, diagnose an AI turn, the owner's workspace, coordinate across
accounts.

## 6. Plans (`docs/superpowers/plans/`)

Implementation task plans. These may reference archived specs — treat the plan's cited spec as
historical context, and follow the architecture truth files for current design.
