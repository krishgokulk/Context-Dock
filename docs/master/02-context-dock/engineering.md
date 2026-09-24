# 02 · Context Dock — Engineering

---

## E1 · Three matching systems — reconcile or document `[proposed · cross-cutting]`
- **Finding:** matching is done by (a) `GlobalSearchService.matchScore` — Global Context;
  (b) the **frontmost-menu matcher** on `LauncherView` — Context Dock (pinned by
  `FrontmostMenuMatcherTests`); (c) `CapabilityIndex` — not wired. Their tie-breaks differ
  (frontmost: shallower path first; global: score then id).
- **Why:** three lexical matchers with divergent rules is the same fragmentation that the ≥9
  stop-word lists cause — the same menu command can rank differently in two surfaces, reading as
  a bug (see routing R3).
- **Fix:** decide the target. Either (i) unify Context Dock + Global Context onto one matcher
  with a scope parameter, or (ii) keep them separate but write a one-paragraph header in each
  stating scope + why, and a shared tie-break rule. Do **not** unify without the eval suite green.
- **Effort:** S (document) / L (unify) · **Risk:** L if unifying.

## E2 · Extract the frontmost matcher off `LauncherView` `[proposed · refactor-in-progress]`
- **Finding:** `FrontmostMenuMatcherTests` header says the matcher "was a method on LauncherView
  — a SwiftUI struct with 420+ @State vars — and nothing could construct one. These pin the
  behaviour as it shipped, so moving it into [its own type] is safe." The tests were written to
  enable this extraction; it hasn't happened.
- **Why:** the matcher is untestable-in-isolation and unreusable while it lives on the view;
  extracting it is what lets E1 (unify) even be considered.
- **Fix:** move the matcher into a free `struct FrontmostMenuMatcher` (pure function over menu
  items + query), leave a thin delegate on `LauncherView`. The tests already lock the behaviour.
- **Effort:** M · **Risk:** M (verify tests stay green on a Mac). This is the highest-value
  engineering item for this surface.

## E3 · Name the matcher's ranking tiers `[proposed]` (pairs routing R2)
- Extract the inline score literals into named constants once E2 lands. Behaviour-preserving.
- **Effort:** S · **Risk:** low.

## E4 · `ContextDockPillCoordinator` is solid — keep it that way `[keep]`
- **Finding:** the coordinator (`Search/ContextDockPillCoordinator.swift`) is careful:
  generation-guarded debounce, cancellation checks at each await, deferred `commitPreview` to
  avoid "Publishing changes from within view updates", question-style short-circuit. Low debt.
- **Fix:** none. Note it as the reference pattern for other surfaces' debounced rebuilds.

## E5 · Perf guardrail (shared with 01 E4) `[proposed]`
- The "live menu updates only after the typing path, sheet stays mounted, backspace doesn't
  collapse a valid sheet" rules (`PERFORMANCE_RULES.md`) are unasserted. Add an in-process
  counter test that fails if a live menu scan runs on the typing path.
- **Effort:** M · **Risk:** low.

---

## Sequencing
E4 is already good. Do E2 (extract matcher) → E3 (name tiers) → E1 (reconcile/document the 3
matchers) → E5 (perf guard). E2 unblocks the rest; all behaviour-touching items verified with
`./scripts/test.sh` on a Mac.
