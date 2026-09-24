# Skill Canonical Standard

This document defines the required schema for every skill in the source repository (rgmez/apple-accessibility-skills), reproduced here for reference alongside the three vendored accessibility auditor skills (`swiftui-accessibility-auditor`, `uikit-accessibility-auditor`, `appkit-accessibility-auditor`).

Source: https://github.com/rgmez/apple-accessibility-skills

## Frontmatter Requirements

Each `SKILL.md` must include:

```yaml
---
name: <skill-name>
description: <what it does + when to use it>
version: 1.0.0
compatibility: [cursor, claude, codex, skills.sh]
---
```

Notes:
- `name` must stay stable to avoid breaking installs.
- `description` should be concise and action-oriented.
- `version` tracks behavior/output contract changes.

## Required Section Order

All skill files must use this order:

1. Role
2. Inputs you can receive
3. Non-goals
4. Guardrails
5. Audit checklist
6. Output contract
7. Verification protocol
8. Style rules
9. Example request
10. References
11. Version

## Guardrails (Mandatory)

- Prefer minimal, localized changes.
- Do not propose architecture rewrites unless blocker-level.
- Do not invent APIs.
- Do not modify user-facing copy unless accessibility requires it.
- Make assumptions explicit when context is missing.

## Output Contract (Mandatory)

Every response must include:

- Findings grouped by priority (`P0`, `P1`, `P2`)
- Patch-ready changes
- Manual verification checklist references

Each finding must include:
- what is wrong
- why it matters
- exact fix

## Verification Protocol (Mandatory)

Each response must end with:
- concrete manual test steps
- expected accessibility outcomes
- explicit note on regression risk

Skill responses should reference the skill-specific `checklist.md` as required validation.
