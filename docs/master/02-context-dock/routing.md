# 02 · Context Dock — Routing (frontmost-menu matching & pill ordering)

The path: `ContextDockPillCoordinator.schedule` (debounce + generation guards) →
`buildPills(query)` (the frontmost-menu matcher, pinned by `FrontmostMenuMatcherTests`) →
ordered pills, learned-usage-boosted (see `intelligence.md`).

---

## R1 · `fillerWords` eats domain words `[proposed]` (see fixes F3, ties to 01 R2)
- The frontmost matcher strips `fillerWords` (`AppMenuCapabilityCache.swift:742`) which wrongly
  includes `"activity"`/`"monitor"`. Fix locally (F3) **and** fold this list into the app-wide
  `StopWords` consolidation from `01-global-context/routing.md` R2 — this is one of the ≥9
  divergent lists.
- **Effort:** S local / L consolidated · **Risk:** M.

## R2 · The matcher's rules are good but implicit `[proposed]`
- **Finding:** `FrontmostMenuMatcherTests` documents strong, sensible rules — exact > prefix,
  word-in-title, typo tolerance (≤2 edits, tokens ≥4 only), shallower-path tie-break,
  menu-spread on empty query, Apple-menu suppression, disabled-item exclusion. But the ranking
  numbers themselves live inline in the matcher (same magic-number issue as 01).
- **Why:** the *rules* are testable and tested; the *weights* aren't named, so tuning is blind.
- **Fix:** name the tiers (as in 01 R1); keep behaviour identical, verified by the existing
  matcher tests.
- **Effort:** M · **Risk:** low (behaviour-preserving).

## R3 · Overlap with Global Context menu search — keep the boundary `[owner]`
- **Finding:** both Context Dock and Global Context surface/execute app menu commands. The
  distinction is scope: Context Dock is **fixed to the frontmost app**; Global Context searches
  menus **across apps**. `CornerFrontmostAppPillsTests` already asserts the frontmost path
  "populates the same pill data Global Context uses" — i.e. shared data, different scoping.
- **Why:** if the two matchers drift (they're currently separate — see engineering E1), the
  same menu command could rank differently in the two surfaces, which reads as a bug.
- **Fix:** decide whether they should share one matcher (E1); until then, document that they're
  intentionally separate and why.
- **Effort:** S doc / L unify · **Risk:** depends on choice.

## R4 · Empty-query "spread across menus" is a real UX rule `[keep + protect]`
- **Finding:** `FrontmostMenuMatcherTests` pins "with no query the list spreads across menus
  instead of draining the first one" — a deliberate, good behaviour (you see File/Edit/View…,
  not 30 File items).
- **Fix:** none needed; call it out so a future ranking change doesn't silently break it. Keep
  the test.
- **Effort:** — · **Risk:** —.

---

## Validation
R1/R2 change matching → the `FrontmostMenuMatcherTests` + integration suites must stay green on
a Mac. R2 (naming tiers) should be byte-identical.
