# 02 · Context Dock — Intelligence / learning

Context Dock's intelligence is **learned pill ordering**: the app's commands you use most
float up. Same rule as 01 — don't tune the weights before an aggregate metric exists.

---

## I1 · Pills are already personalized (two signals) `[exists]`
- **Finding:** pill ordering blends usage learning: `UsageTracker.getScore` and
  `AppInteractionStore.frequencyBoost(bundleId:actionId:)`
  (`LauncherView+ContextDockPills.swift:3376, 3384`), recorded on use
  (`UsageTracker.recordAccess`, `AppInteractionStore.record`). So the dock adapts per app to the
  actions you actually run.
- **Why note it:** this is real intelligence, not a gap — document it so it isn't "rebuilt".
- **Fix:** none; capture in the doc that Context Dock personalizes via these two stores.

## I2 · The weights are hand-tuned and unmeasured `[proposed]`
- **Finding:** the boost multipliers (like 01's `learnedUsageBoost`) are literals; nothing
  measures whether "used before" is weighted right vs the typed query.
- **Why:** too strong → the dock ignores what you typed; too weak → no learning benefit.
- **Fix:** include Context-Dock pill ordering in the same labelled corpus/metric planned for 01
  (query + per-app usage history → expected top pill). Tune from the number.
- **Effort:** M · **Risk:** M — gated on the metric.

## I3 · Cross-surface learning consistency `[investigate]`
- **Finding:** Context Dock uses `UsageTracker` + `AppInteractionStore`; Global Context's
  `learnedUsageBoost` uses `UsageTracker` + `AppUsageLearner`. Two different "second learners"
  across surfaces for the same underlying idea (which action did the user pick).
- **Why:** a menu command you run from the dock may or may not raise its rank in Global Context
  depending on which learner recorded it — inconsistent memory of the same act.
- **Fix:** confirm whether `AppInteractionStore` and `AppUsageLearner` observe the same events;
  if not, unify the "action was chosen" signal so learning is consistent across surfaces.
- **Effort:** M · **Risk:** M.

## I4 · Predictive pills (later) `[idea, deferred]`
- Once measured: surface the app's likely-next command from context (time of day, recent
  sequence) — but only behind the metric, and only if it beats plain frequency. Not now.

---

## Through-line
The dock is already smart in the way that matters (per-app frequency). The ceiling is the same
as 01: unnamed, unmeasured weights, and a learning signal that may differ from Global Context's
(I3). Fix measurement + consistency before adding anything new.
