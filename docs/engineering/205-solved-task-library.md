# P11 #205 — Solved-task library (design note)

Spec: `docs/master/00-APP-AGENT-PLUGIN-PLAN.md` §6.3. This note records the implementation shape
decided for the PR; it does not restate the spec.

## Decision: typed route-chain, not literal L2 bash

§6.3 says "store in the `L2ExtensionManager` format (folder + `extension.json` + script)". The only
L2 run path in code is free-form `/bin/bash` (`LayeredExtensionManager.executeBashScript`), which
violates §6.3 **rule 5** (argv, no free-form shell, no network in a read skill) and would add a
second execution + safety path (AGENTS.md forbids a second engine/registry/safety path).

Owner decision (2026-10-27): a saved read-skill is a **parameterized `WorkflowRecipe`** (typed
route-chain) run through the existing `WorkflowRecipeRunner.bind` / `ChatPlanRunner.run` — the same
approval gates, console log and post-step verification. `bind()` re-resolves every step against live
capabilities at run time, which is rule 7 (re-test before use) by construction. The L2 folder format
is an **export for Settings › Plugins visibility only**, never the execution path. This is the same
engine `WorkbenchIntent` "save that as X" / "run X" already uses — #205 adds *automatic* capture,
parameterization, and *automatic* match-before-model on top of it.

## The rules, and where each is enforced

| § rule | Enforced by |
|---|---|
| 1 only verified, uncorrected successes | capture requires `Answer.evidenceReceipts.contains { $0.isVerification && $0.success }` and no error this turn; redo-retraction (next-turn correction) is a fast-follow |
| 2 parameterized + tested, no hard-coded values | reject a captured skill with zero param slots over an entity-bearing query |
| 3 nothing shaped by untrusted text auto-saved | reject when `UntrustedContent.containsFence` holds over any receipt output |
| 4 auto-save reads only; writes gate every run | read-only aggregate over the chain (`ChatRoute.isReadOnly`); writes not auto-saved in this slice |
| 5 argv, no free-form shell, no network | satisfied by construction — typed routes, no bash |
| 6 visible in Settings › Plugins, "made by DoraX" | deferred to a follow-up PR (surface only) |
| 7 re-tested after app version change | `WorkflowRecipeRunner.bind` re-resolves live each run |
| 8 Claude Code writes; on-device AI only fills params | capturing the executed typed chain means no script to author; `{sender}/{day}` filled deterministically in v1, on-device AI later |

## Hooks (one each)

- **Capture:** in `AppScopedChatService.send`, after `sendUntraced` returns its `Answer`
  (`AppScopedChatService.swift:~1339`). Single chokepoint, already inside `TurnRecorder`.
- **Match (D1, before the model):** right after the `WorkbenchIntent.intent` block
  (`AppScopedChatService.swift:~1475`) — the spec's "ladder stage 4, `WorkbenchIntent`". Dock twin
  at `DockCore+AIChat.swift:~3174` follows in a later PR.

## First vertical slice (this PR)

Capture one verified Mail read → parameterized saved skill → D1 match-before-model on the second
sentence → "Used saved skill (no model)" step. Owner hand check: "unread mail from SBI today", then
"unread mail from ICICI yesterday" (the second shows "Used saved skill (no model)").

Deferred: Dock-surface twin hook, Settings surface (rule 6), on-device Apple-Intelligence param
fill (deterministic fallback ships first), write/approval-gated skills (rule 4 second half),
Claude-Code-authored script skills (P12 #206 territory).

## Known limits (slice 1)

- Rule-3 fence check does not yet cover persisted `argTemplate` inputs.
- Replay returns the raw capability output as `Answer.text` with empty `rows` (parity with the model summary deferred), and inlines the scope check + read-back instead of dispatching `run_capability`.
- `{day}` is limited to today/yesterday, the only values `mail.search` honors.
