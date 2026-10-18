# 00 — Model routing and context diet

Claude Code runs **one model per session**; it does not switch per task. Economy comes from (a) the
session's model, (b) the subagents in `.claude/agents/`, and (c) loading less into context.

## Which model for which job

| Job | Where | Model |
|---|---|---|
| Plan, design, architecture decisions, `/planner` | main session | strongest (Opus) |
| Build an issue end to end, `/builder` | main session | Sonnet |
| "Where is X / what calls Y" sweeps | `scout` subagent | Haiku |
| Renames, test scaffolding, doc edits, a decided pattern across a few files | `mechanic` subagent | Sonnet |
| Review a diff before ready | `reviewer` subagent | Opus |
| Daily brief, summaries | scheduled task | Sonnet |

Downgrade when the brief fits in three lines and needs no judgement. Upgrade the moment a task needs
a design choice.

## Context diet (the bigger lever)

- Claude connectors are off for this project (`ENABLE_CLAUDEAI_MCP_SERVERS=false` in
  `.claude/settings.json`). Project servers that stay: `llmbrain`, `dorax`.
- Account plugins (`productivity`, `data`) are not controlled by this repo — turn them off in the
  Claude desktop app's plugin settings.
- `MEMORY.md` keeps the last ~30 days. Once a month the planner (not a builder) moves older dated
  lines to `docs/history/MEMORY-YYYY-MM.md`; builders still only append.
- Navigate with `graphify query` before grep; push sweeps to `scout`.

## One source of truth for every provider

`AGENTS.md` is the neutral core any model can read. `CLAUDE.md` and `.agents/` carry provider-only
depth (hooks, MCP, skills). Skills that exist in both trees must match
(`scripts/check-skills-parity.sh`, run by the Stop hook). A local Ollama model gets `AGENTS.md` plus
`graphify` output and narrow, reviewed tasks only.
