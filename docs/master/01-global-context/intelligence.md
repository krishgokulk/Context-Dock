# 01 · Global Context — Intelligence / AI / learning

What makes Global Context smarter over time. Today's intelligence is **learned personalization**
(usage boosts), not semantics. Order matters: **do not start these until `routing.md` R1
(named tiers) and an aggregate metric exist** — tuning weights blind is how you regress.

---

## I1 · The learned-usage boost is real but hand-tuned & unmeasured `[proposed]`
- **Finding:** `learnedUsageBoost` (`GlobalSearchService.swift:430`) blends two learners —
  `UsageTracker.getScore` and `AppUsageLearner.blendedActionScore` — through hand-picked
  multipliers/caps per action kind: `×7 cap 420`, `×95 cap 760` (menus/adapters), `×85 cap 680`
  (system/user-ext), `×75 cap 520` (launch), `×70 cap 520` (cli), `×4 cap 220` (browser), final
  `min(…, 1_050)`.
- **Why:** these numbers decide how strongly "what you used before" overrides "what you typed".
  Too high → the launcher stops responding to the query; too low → no personalization. Nobody
  can currently say which. This is where an **aggregate ranking metric** pays off directly.
- **Fix:** (a) name these constants (with R1); (b) build a small labelled corpus of
  (query, session-history → expected top result) and measure how the caps move the number;
  (c) tune from the metric, not by feel.
- **Effort:** M · **Risk:** M (changes result order) — gated on the metric.

## I2 · Give the user control over learning `[proposed · product]`
- **Finding:** learned boosts have no visible "forget this" / reset (doc §12 #5).
- **Why:** a one-off wrong click can bias results for a long time with no recourse; trust in a
  launcher dies when it "won't stop suggesting the wrong thing".
- **Fix:** a per-item "don't learn from this" and a global reset in Settings; decay old signals
  so recency wins (some decay may already exist in `AppUsageLearner` — confirm).
- **Effort:** M · **Risk:** low.

## I3 · Semantic ranking — only once measured `[deferred, on purpose]`
- **Finding:** ranking is purely lexical (prefix/substring/word tiers). `CapabilityIndex`'s
  header states the house position: *"Embeddings are a refinement to add once this is measured,
  not the starting point."*
- **Why:** semantics would fix "find my bookmarks note" → Notes-type failures, but added blind
  it makes ranking unexplainable and unfalsifiable.
- **Fix:** defer until R1 + the metric land; then trial an on-device embedding **re-rank of the
  top-K only** (keep the lexical shortlist for speed/explainability), measured against the
  corpus. Local, no network.
- **Effort:** L · **Risk:** M — do not start early.

## I4 · Smart-query intelligence `[proposed]`
- **Finding:** `SmartQueryType` (`LauncherView+Search.swift`) routes to Apple-app content
  panels (contacts/photos/notes/…) and `webSearch`; detection is keyword-shaped.
- **Why:** this is where "typed intent → the right vertical" lives; misfires send a query to the
  wrong panel.
- **Fix:** fold smart-query detection into the same measured harness (treat "which panel" as a
  routing label); consider the on-device classifier already used elsewhere
  (`QueryIntentCache`).
- **Effort:** M · **Risk:** M.

---

## The through-line
Global Context's intelligence is **personalized ranking**. Its ceiling right now is not the
model — it's that the weights are unnamed (R1) and unmeasured. Fix those two and this surface
gets measurably smarter with low risk; skip them and every change here is a coin flip.
