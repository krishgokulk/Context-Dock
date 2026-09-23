# 01 · Global Context — Fixes

Bugs, correctness risks, and doc corrections. Each: finding → why → fix → effort/risk.

---

## F1 · Doc: ranker description — enrichment, NOT a correction `[done]`
- **Finding:** an earlier note here claimed doc §7 "conflated" n-gram and `matchScore`. That was
  itself wrong: §7 already said `grams` gathers candidates and `matchScore` scores. The only
  real change is an **enrichment** — noting `matchScore` is *tiered* (`:339`) and blends a
  two-signal `learnedUsageBoost` (`:430`), and that `CapabilityIndex` is a *different, not-wired*
  ranker.
- **Fix:** added a one-line enrichment + pointer to §7; no correction was needed.
- **Effort:** S · **Risk:** none (docs).

## F2 · Doc: "no tests" claim was false `[done]`
- **Finding:** doc §12 #4 said no tests exist for Global Context ranking. They do:
  `LauncherQueryShapeTests`, `GlobalIntegrationSearchTests`, `CornerScopeWalkTests`,
  `DockPinStoreTests`, `CornerCLIScopeTests`.
- **Fix:** corrected §12 of the doc.
- **Effort:** S · **Risk:** none.

---

## F3 · Two-word match uses bidirectional prefix (precision risk) `[proposed]`
- **Finding:** in `matchScore` two-word handling (`GlobalSearchService.swift` ~`:389`),
  `wordMatches` accepts `candidate.hasPrefix(word) || word.hasPrefix(candidate)`. The second
  direction means a **1–2 char query word** (`"me"`, `"no"`) matches many titles ("Messages",
  "Notes"…), so a short second word can wrongly satisfy `allSatisfy(wordMatches)` and lift an
  unrelated result into the strong 11,250 tier.
- **Why:** false high-tier matches are the most visible ranking failure (wrong result first).
- **Fix:** require a minimum length (e.g. ≥3) before allowing the `word.hasPrefix(candidate)`
  direction, or drop that direction for the shorter side. Add a `LauncherQueryShapeTests`
  case: `"new me"` must not rank Messages in the top tier.
- **Effort:** S · **Risk:** M (ranking change — needs the eval tests green on a Mac build).

## F4 · Verify the "ignorable" fallback can't strand a real query `[investigate]`
- **Finding:** `matchScore` builds `requiredWords = queryWords.filter { !ignorable.contains }`
  (`:399`). If a two-word query is entirely ignorable words (e.g. "notes files"), `requiredWords`
  is empty and that branch is skipped — fine — but confirm the single-word path still scores it.
- **Why:** the sibling bug in `CapabilityMatchEvalTests` was a stop list eating a whole query.
- **Fix:** add a test for an all-ignorable multi-word query; confirm it still returns the app.
- **Effort:** S · **Risk:** low. Needs Mac to run the test.

---

## How to validate any fix here
All are ranking-adjacent: after editing, run `./scripts/test.sh` on a Mac and confirm the
Global Context suites stay green. A ranking change with red evals is a regression, not a fix.
