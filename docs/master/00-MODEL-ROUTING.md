# 00 — Model routing and context diet

Claude Code runs **one model per session**; it does not switch per task. Economy comes from (a) the
session's model, (b) the subagents in `.claude/agents/`, and (c) loading less into context.

**The default is Sonnet, enforced.** `.claude/settings.json` pins `"model": "sonnet"`, so every
session that opens this project — including `/loop /builder` — starts on Sonnet, not Opus. Opus is
~5× the cost per token; defaulting to it is how a 5-hour limit vanishes in half a day. Opt *up*
deliberately with `/model opus` only for the two jobs below that need it; never leave a build session
on Opus.

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

Only `/planner` and the pre-ready `reviewer` pass run Opus. For those: `/model opus` at the start of
a planning session; let the `reviewer` subagent (already pinned to Opus) carry review. Everything
else — building issues, fixes, sweeps, edits, summaries — stays on Sonnet or Haiku.

## Cost discipline (how not to blow the 5-hour limit)

The limit goes to the session model and to subagents (each subagent runs its own requests). Three
rules, in order of how much they save:

1. **Never build on Opus.** The default is Sonnet; confirm with `/model` at the start of a build
   session. Upgrade to Opus only for a planning session, then drop back.
2. **One `reviewer` pass per PR, not per commit.** The `reviewer` subagent is Opus — the most
   expensive thing you can spawn in a loop. Run it once, before a PR is marked ready, not on every
   builder iteration. If `/loop /builder` spawns it each cycle, fix the loop, not the model.
3. **Don't spawn a subagent for work the session can do inline.** A "thorough" task is not a reason
   to fan out. Use `scout` (Haiku) for pure "where is X" sweeps so file dumps stay out of context;
   use `graphify query` before grep, and read only the line ranges you need rather than whole files.

Account plugins (`productivity`, `data`) load into every session's context — keep them off in the
desktop app's plugin settings (see Context diet below).

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

## App Pets provider rule (2026-10-27, #327)

- The provider selected for a conversation remains its default across App Pet and Combined Chat.
- Adding a Pet or step never silently changes providers.
- The host fits recent turns, rolling summary, relevant retrieved history, Pet profile and required
  evidence to that provider's budget; the full local transcript is the source of truth.
- The host owns tool/round/time/no-progress budgets, scope, approvals, execution and verification.
- A provider without tool schemas uses the same typed capability layer through its supported
  bridge; it receives no extra authority.
(`scripts/check-skills-parity.sh`, run by the Stop hook). A local Ollama model gets `AGENTS.md` plus
`graphify` output and narrow, reviewed tasks only.
