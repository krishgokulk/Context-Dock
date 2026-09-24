# 02 · Context Dock — work folder

Deep-dive **improvement** work for the frontmost-app command layer. Actionable layer under
[`../02-CONTEXT-DOCK.md`](../02-CONTEXT-DOCK.md).

> Every item is grounded with `file:line`, states why it matters, proposes a fix, tags
> **effort** (S/M/L) + **risk** and whether it needs a Mac build. Nothing applied to code yet.

## Files

| File | Holds |
|---|---|
| [`fixes.md`](fixes.md) | Corrections + real correctness items |
| [`routing.md`](routing.md) | Frontmost-menu matching & pill ordering quality |
| [`intelligence.md`](intelligence.md) | Learned usage / personalization of pills |
| [`engineering.md`](engineering.md) | Refactors, the 3-matcher problem, tests, perf |

## Two corrections to `../02-CONTEXT-DOCK.md` from this pass `[code]`

1. **"Stale menu cache" is largely mitigated, not an open risk.** Doc §8 #1 flagged staleness
   with `[?]` timing. In fact `MenuExecutionCoordinator.executeDockMenuAction` live-verifies
   before running — `waitForExecutableMenuItem` → `guard let liveMatch, liveMatch.isEnabled`
   (`MenuExecutionCoordinator.swift:160–178`) — and `AppMenuCapabilityCache` re-scans to mirror
   the live menu and is **version+locale-aware** (`AppMenuCapabilityRecord.bundleVersion` /
   `localeIdentifier`; stale-on-update filtering `:812`). Corrected in the doc.
2. **Context Dock IS tested.** Doc §8 #3 ("no tests") was wrong. `FrontmostMenuMatcherTests`
   (~15 cases: prefix, word-in-title, typo ≤2 edits for tokens ≥4, dedupe, exact>prefix,
   shallower-path tie-break, limit, menu-spread, Apple-menu policy, disabled-item exclusion),
   `CornerFrontmostAppPillsTests`, `IrreversibleMenuConsentTests`, `CornerDock*` all exercise
   it. Corrected in the doc.

## Headline finding: three matching systems, divergent rules `[code]`

Global Context uses `GlobalSearchService.matchScore` (01). Context Dock uses a **separate
frontmost-menu matcher** (pinned by `FrontmostMenuMatcherTests`, originally a method on
`LauncherView`). `CapabilityIndex` is a third, not-wired ranker. Their tie-breaks even differ
(frontmost: shallower path first; global: score then id). Same fragmentation risk as the
≥9 stop-word lists in 01 — see `engineering.md` E1.

## Suggested order

1. `fixes.md` (doc corrections — done; plus F3 the `"monitor"` filler bug).
2. `engineering.md` E2 (extract the matcher off `LauncherView` — a refactor the tests were
   written to enable) → E1 (reconcile/document the 3 matchers).
3. `routing.md` R1 (`fillerWords` domain-word bug) — ties to 01's stop-word consolidation.
4. `intelligence.md` — after the aggregate metric exists (same rule as 01).
