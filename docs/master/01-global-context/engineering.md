# 01 · Global Context — Engineering

Refactors, tests, performance, tech-debt. Non-behavioural unless noted.

---

## E1 · Extract ranking constants `[proposed]` (pairs with routing R1)
- Move every literal in `matchScore` / `learnedUsageBoost` into a named, documented tier/weight
  type. Pure rename → scores identical. Prereq for tuning and for readable diffs.
- **Effort:** M · **Risk:** low (verify byte-identical via eval suite).

## E2 · One stop-word source `[proposed]` (pairs with routing R2)
- Land the `StopWords` type from R2; delete the ≥9 local copies incrementally.
- **Effort:** L · **Risk:** M per migration. Highest debt-reduction in the surface.

## E3 · Test the live ranker's tiers directly `[proposed]`
- **Finding:** existing tests (`LauncherQueryShapeTests`, `GlobalIntegrationSearchTests`,
  `CornerScopeWalkTests`) cover query *shapes* and integration, but there's no test that pins
  the **tier ordering** of `matchScore` (exact > word-exact > all-words > prefix > substring).
- **Fix:** add `GlobalSearchServiceRankingTests` asserting the precedence with a fixed corpus —
  this is also the seed of the aggregate metric.
- **Effort:** M · **Risk:** none (adds coverage).

## E4 · Performance guardrails are documented but untested `[proposed]`
- **Finding:** `PERFORMANCE_RULES.md` mandates "no AX/menu scan while typing" and cache-first
  search; nothing asserts these in code, so a future change can quietly reintroduce a scan on
  the typing path.
- **Fix:** a lightweight assertion/telemetry counter that fails a test if the typing path
  triggers an AX refresh; or an OSSignpost the test inspects. (OSLog is unreliable on the dev
  Mac per `CLAUDE.md` — prefer an in-process counter.)
- **Effort:** M · **Risk:** low.

## E5 · Two rankers, one surface — document the boundary `[proposed]`
- **Finding:** `GlobalSearchService.matchScore` (live, Global Context) and `CapabilityIndex`
  (not yet wired, capability routing) coexist. Nothing states which is authoritative where, so
  a future contributor may "fix" the wrong one (I nearly documented the wrong one).
- **Fix:** a one-paragraph header in each pointing at the other and stating scope. If
  `CapabilityIndex` is meant to eventually replace `matchScore`, record that migration intent.
- **Effort:** S · **Risk:** none.

## E6 · `insertRanked` tie behaviour `[investigate]`
- **Finding:** `insertRanked` (`:501`) inserts at the first strictly-greater slot; equal scores
  keep insertion (dictionary) order, which can be unstable across launches for ties. The
  `CapabilityIndex` ranker breaks ties by id for exactly this reason.
- **Fix:** break score ties deterministically (by document id) so the same query resolves the
  same way every launch. Confirm current behaviour first — it may already be stable upstream.
- **Effort:** S · **Risk:** low.

---

## Sequencing
E5 (S, docs) and E3 (tests) first — they're safe and unblock the rest. Then E1 (constants) →
E6 (tie stability) → E4 (perf guard) → E2 (stop-word consolidation, the big one). All
behaviour-touching items verified with `./scripts/test.sh` on a Mac.
