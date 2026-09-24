# 02 · Context Dock — Fixes

---

## F1 · Doc: "stale menu cache" risk overstated `[done]`
- **Finding:** doc §8 #1 flagged staleness as an open `[?]`. Execution actually live-verifies:
  `MenuExecutionCoordinator.swift:160–178` waits for the live menu item and requires
  `isEnabled` before acting; `AppMenuCapabilityCache` re-scans to mirror the live menu and
  carries `bundleVersion` + `localeIdentifier` so items go stale on app update/locale change.
- **Fix:** corrected §8 #1 to "handled; here's the mechanism".
- **Effort:** S · **Risk:** none.

## F2 · Doc: "no tests" claim was false `[done]`
- **Finding:** §8 #3 said no tests. `FrontmostMenuMatcherTests` (~15), `CornerFrontmostAppPillsTests`,
  `IrreversibleMenuConsentTests`, `CornerDockAnchor/Keyboard/Layout/PhaseTests`, `AXMenuReaderTests`
  all exist.
- **Fix:** corrected §8 #3.
- **Effort:** S · **Risk:** none.

---

## F3 · `fillerWords` contains a domain word: `"monitor"` `[proposed · real risk]`
- **Finding:** `AppMenuCapabilityCache.fillerWords` (`:742`) =
  `["app","application","open","show","view","use","please","the","a","an","to","in","on",
  "for","with","using","usage","usages","activity","monitor"]`. `"activity"` and `"monitor"`
  are **not** grammatical filler — they're the literal name of **Activity Monitor**. Stripping
  them can make a query for that app/its menus match nothing or mismatch.
- **Why:** exactly the class of bug `CapabilityMatchEvalTests` locks (a real word on a filler
  list disqualifying the thing it names). This one is concrete and shippable-wrong today.
- **Fix:** remove `"activity"`/`"monitor"` (and audit the rest); if they were added to suppress
  a specific noisy menu item, suppress that item by path, not by eating the word globally. Add
  a test: a query for "activity monitor" resolves the app.
- **Effort:** S · **Risk:** M (changes matching — run `FrontmostMenuMatcherTests` +
  `GlobalIntegrationSearchTests` on a Mac).

## F4 · Frontmost detection depends on `previousFrontmostApp` `[document + guard]`
- **Finding:** because the dock steals frontmost focus when open, scope uses
  `AppDelegate.previousFrontmostApp` (doc §5). If that value is ever wrong/nil (fast app
  switches, dock re-open races), the whole surface scopes to the wrong app silently.
- **Fix:** this is correctness-critical and invisible when it fails — add a test/assertion that
  `previousFrontmostApp` is set before pills build, and document it as a guarded invariant.
- **Effort:** S · **Risk:** low. Needs Mac to test the timing.

---

## Validation
F3/F4 touch matching/scoping → run the Context Dock suites on a Mac (`./scripts/test.sh`);
green evals are the bar.
