# 01 · Global Context — work folder

Deep-dive **improvement** work for the Global Context surface, split by kind. This is the
actionable layer under the description in [`../01-GLOBAL-CONTEXT.md`](../01-GLOBAL-CONTEXT.md).

> Every item is grounded in code with `file:line`, states why it matters, proposes a fix, and
> tags **effort** (S/M/L) and **risk** + whether it needs a Mac build to verify.
> Nothing here is applied to code yet — it's the plan you approve item by item.

## Files

| File | Holds |
|---|---|
| [`fixes.md`](fixes.md) | Bugs, correctness issues, and doc corrections found while reading the code |
| [`routing.md`](routing.md) | Ranking & routing quality — how the right result gets to the top |
| [`intelligence.md`](intelligence.md) | AI / learning / personalization — making it smarter over time |
| [`engineering.md`](engineering.md) | Refactors, constants, tests, performance, tech-debt |

## Doc accuracy in this pass `[code]`

1. **One genuine correction:** doc §12 #4 said "no tests found" for Global Context. Wrong —
   `LauncherQueryShapeTests`, `GlobalIntegrationSearchTests`, `CornerScopeWalkTests`,
   `DockPinStoreTests`, `CornerCLIScopeTests` exercise it. Corrected in the doc (F2).
2. **One enrichment (not a correction):** doc §7 was already right that `grams` gathers
   candidates and `matchScore` scores. Added that `matchScore` is *tiered* and pointed §7 at
   `routing.md`. `CapabilityIndex` is a *separate, not-yet-wired* ranker — worth keeping
   distinct so nobody edits the wrong one (see `engineering.md` E5).

## Headline finding (cross-cutting, starts here)

**Stop-word lists are fragmented across ≥9 files.** `GlobalSearchService.ignorable` (`:399`)
is one of at least nine independent stop/filler lists (see `routing.md` R2). Divergent stop
lists are the exact cause of the bug `CapabilityMatchEvalTests` locks (the word "note"
disqualifying every Notes capability). This is the single highest-leverage routing fix and it
reaches well beyond Global Context.

## Suggested order

1. `fixes.md` F1–F2 (doc corrections — done) and any real bugs.
2. `routing.md` R2 (stop-word consolidation) — highest leverage.
3. `routing.md` R1 (name the magic-number tiers) — unblocks everything else being tunable.
4. `intelligence.md` — only after R1/R2, because you can't tune what you can't name or measure.
5. `engineering.md` — ongoing.
