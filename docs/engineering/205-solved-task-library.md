# P11 #205 — Solved-task library (design & as-built note)

Spec: `docs/master/00-APP-AGENT-PLUGIN-PLAN.md` §6.3. This note records the implementation shape
as built and merged in PR #367 (and extended in #408); it reflects code truth.

## As-built implementation: standalone `SolvedSkill`

Rather than raw bash or heavy `WorkflowRecipe` indirection, the merged implementation in
`Context-Dock/AI/` uses three lightweight, purpose-built components:
- `SolvedSkill.swift`: Defines `SolvedSkill`, `SolvedSkillStep`, and `SolvedSkillStore` (`~/Library/Application Support/Context-Dock/solved-skills.json`).
- `SolvedSkillCapture.swift`: Monitors turns via `SolvedSkillToolCallCollector.shared.hadVerifiedReadBack`. In `AppScopedChatService.sendUntraced` (~line 1430), successful, verified, single-tool read turns are captured as parameterized skills.
- `SolvedSkillMatch.swift`: In `AppScopedChatService.sendUntraced` (~line 1574), before invoking the AI model, queries are matched against `SolvedSkillStore.shared.skills(for: appID)`. If a match is found, `SolvedSkillMatch.run` replays the tool call directly through `GeneralAIActionExecutor.shared.execute`, answering in 0ms with zero model tokens.
- **Settings integration (#408):** Solved skills are listed in `Settings › Extensions › Apps › <App> › Capabilities & Skills` under the "Made by DoraX" section.

## The rules, and where each is enforced

| § rule | Enforced by |
|---|---|
| 1 only verified, uncorrected successes | capture requires `SolvedSkillToolCallCollector.shared.hadVerifiedReadBack` and no error this turn |
| 2 parameterized + tested, no hard-coded values | entity extraction parameterizes dates (`{day}`) and entities (`{query}`) |
| 3 nothing shaped by untrusted text auto-saved | reject when `UntrustedContent.containsFence` holds over any output |
| 4 auto-save reads only; writes gate every run | read-only capabilities only (`mail.search`, `mail.read`, etc.); writes are never auto-saved |
| 5 argv, no free-form shell, no network | satisfied by construction — typed capabilities through `GeneralAIActionExecutor` |
| 6 visible in Settings › Extensions › Apps | listed in `Capabilities & Skills` under "Made by DoraX" (#408) |
| 7 re-tested after app version change | verified read-back confirmed on execution |
| 8 Claude Code writes; on-device AI only fills params | deterministic entity filling in v1 |

## Hooks (one each)

- **Capture:** in `AppScopedChatService.swift:~1430`, after turn verification completes.
- **Match (before the model):** in `AppScopedChatService.swift:~1574`, right before provider prompt assembly.

## Verified flow

1. First turn: "unread mail from SBI today" runs via provider with `mail.search`, verifies receipt, and auto-saves `SolvedSkill`.
2. Second turn: "unread mail from ICICI yesterday" matches before model, runs `mail.search` with ICICI/yesterday, returns verified answer with "Used saved skill (no model)" in 0ms.
