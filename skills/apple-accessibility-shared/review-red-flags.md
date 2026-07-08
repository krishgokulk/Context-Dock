# Accessibility Review Red Flags

Use this sheet during PR review to catch common low-signal or risky patterns.

Source: https://github.com/rgmez/apple-accessibility-skills (applies to `swiftui-accessibility-auditor`, `uikit-accessibility-auditor`, `appkit-accessibility-auditor`)

## Red flags

- "Looks accessible" with no VoiceOver or keyboard proof.
- Adds labels everywhere without checking duplicates.
- Fixes accessibility by changing unrelated architecture.
- Treats color as the only state signal.
- Uses fixed fonts in user-facing text.
- Adds hints that repeat the label without extra value.
- Ignores focus order in dense layouts and custom controls.
- Suggests broad rewrites instead of minimal, local fixes.

## Reviewer questions

- What is the concrete user impact if this stays as is?
- Can a keyboard-only user complete the core flow?
- Is VoiceOver output understandable and non-duplicated?
- Does this change preserve existing behavior while improving accessibility?
- Is there a smaller fix that achieves the same outcome?

## Fast pass checklist

- P0 issues are clearly blocked and justified.
- P1 issues are actionable with patch-ready edits.
- Suggested changes include manual validation steps.
- No speculative APIs or architecture detours.
