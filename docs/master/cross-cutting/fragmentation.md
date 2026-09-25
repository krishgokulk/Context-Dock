# Cross-cutting · Fragmentation of shared logic

> **Status: DRAFT / under review.** A work item that surfaced repeatedly across the per-document
> deep dives (01 stop-words, 02 the 3 matchers + 4th learner). This is the app-wide version.
> Tags: `[code]` verified · `[?]` needs confirmation. Nothing applied yet.

---

## The pattern, in one sentence

**The same three jobs — score a query against items, remember what the user picked, and strip
filler words — are each implemented many times over, independently, with divergent rules.**

That divergence is not cosmetic: it is the root cause of the bug class your own
`CapabilityMatchEvalTests` exists to catch (a real word on one stop list disqualifying the
thing it names), and of "the same command ranks differently in two surfaces," which reads to a
user as a bug.

---

## Axis 1 · Ranking / scoring — 15+ implementations `[code]`

Distinct functions that score a query (or context) against candidate items:

| Where | Symbol |
|---|---|
| Global Context | `GlobalSearchService.matchScore` (`:339`) |
| Context Dock | frontmost-menu matcher on `LauncherView` (pinned by `FrontmostMenuMatcherTests`) |
| Capability routing (not wired) | `CapabilityIndex.search` |
| L2 app actions | `L2AppActionRouter.scoreActions` / `scoreAppMatch` / `score(action:)` (`:403–447`) |
| Shortcuts | `AIShortcutMatcher` — `scoreShortcut` + 9 context scorers (`:234–559`) |
| General action routing | `GeneralAIActionResolver.matchOutranks` / `rankScore` / `rankedWithPreferences` (`:1027–1558`) |
| Global commands | `GlobalCommandCapabilities.rankedMatches` (`:142`) |
| Tool registry | `AgentToolRegistry.rankedCapabilityIDs` (`:808`) |
| Adapter actions | `AppAdapterManager.scoredActions` / `adapterActionMatchScore` (`:314, :1363`) |
| Share sheet | `ShareDestinationResolver.matchScore` / `scoreVariantMatch` (`:43, :69`) |
| Menu intent | `MenuIntentRouter.scoredCandidates` (`:78`) |
| App chat rows | `AppChatRowRanker.rank` |
| Mail | `MailAutomation.score(role:…)` (`:337`) |
| Chat start picker | `GeneralChatStartView.rank` (`:177`) |
| Context budget | `AIContextBudget.score(chunk:)` (`:143`) |

**Be fair — not all of these are duplication.** Several are legitimately domain-specific and
should stay separate: `AIContextBudget` (text-chunk relevance), `MailAutomation` (AX role
scoring), `ShareDestinationResolver` (share targets), `AIShortcutMatcher`'s context scorers
(file/text/url/contact). The **true overlap** is the cluster that all do
*"query → app / menu / action text match"* with their own magic numbers and tie-breaks:
`GlobalSearchService.matchScore`, the frontmost matcher, `CapabilityIndex`, `L2AppActionRouter`,
`AppAdapterManager.adapterActionMatchScore`, `GlobalCommandCapabilities`, `MenuIntentRouter`,
`AppChatRowRanker`. That's still **~8 implementations of one idea.**

## Axis 2 · Usage / frequency learners — 4 stores `[code]`

Four separate "what did the user pick / use" stores:
`UsageTracker` (`Services/UsageTracker.swift`), `AppUsageLearner`
(`Services/AppUsageLearner.swift`), `AppInteractionStore` (`Services/AppInteractionStore.swift`),
`FinderOpenFrequencyStore` (`Services/FinderOpenFrequencyStore.swift`).

- Global Context boosts with `UsageTracker` + `AppUsageLearner` (01).
- Context Dock boosts with `UsageTracker` + `AppInteractionStore` (02 I3).
- So the *same act* ("user ran this menu command") may be recorded by different stores on
  different surfaces → learning that doesn't transfer, or transfers inconsistently. `[?]` (needs
  confirmation of which events each store observes).

## Axis 3 · Stop-word / filler lists — 9 lists `[code]`

`GlobalSearchService.ignorable` (`:399`), `CapabilityIndex.filler` (`:194`),
`L2AppActionRouter.fillerWords` (`:96`), `AgentToolRegistry.stopwords` (`:864`),
`GeneralAIActionResolver` inline (`:1145`), `OnDeviceToolBridge.stopWords` (`:384`),
`AppMenuCapabilityCache.fillerWords` (`:742` — contains the domain words `activity`/`monitor`,
02 F3), `OnDeviceStructuredStubs.filler` (`:92`), `ContactSearchManager.stopWords` (`:234`).

---

## Why it matters

1. **Correctness.** Divergent stop lists eat real words in one path and keep them in another —
   the documented `CapabilityMatchEvalTests` failure. Divergent matchers make one command rank
   differently across surfaces.
2. **Unmeasurable + untunable.** 8 matchers × their own magic numbers = nowhere to stand to
   tune ranking. This is why the aggregate-eval gap (10 §1) and this item are linked: you can't
   measure 8 things pretending to be one.
3. **Maintenance.** A fix to ranking or a stop-word correction has to be made 8–9 times, and
   usually is made once — so regressions re-enter through the copies.

---

## The fix — staged, eval-gated, never big-bang

Priority by leverage-over-risk:

1. **Stop-words first (Axis 3).** Lowest risk, highest documented-bug payoff. Build one
   `StopWords` type with **named, documented sets** — a small always-safe grammatical set, and
   separate opt-in domain-noun sets a caller includes only when correct (do NOT force one flat
   list — that's how "note"/"monitor" got eaten). Migrate call sites one at a time, each behind
   its own test; delete each local copy as it's migrated. (Detailed in `01/routing.md` R2.)
2. **Unify the learning signal (Axis 2).** Confirm what each of the 4 stores observes; define
   one "capability/action was chosen" event that all surfaces emit and all boosts read. Keep the
   stores if their storage differs, but make the *signal* single-sourced. Start by confirming
   the overlap, not by deleting a store.
3. **Reconcile the query→item matchers (Axis 1) — last, and only after an aggregate metric
   exists.** Extract the frontmost matcher off `LauncherView` first (02 E2, tests already lock
   it). Then decide: one scoring core with a scope/candidate-source parameter, vs. keep separate
   but share the tier constants + tie-break rule. This is the largest and riskiest; do not touch
   it until the eval corpus can prove a merge didn't change behaviour.

---

## What NOT to do

- **Do not "merge all 15."** The domain-specific scorers (context-budget, mail, share, shortcut
  context) should stay separate — merging them would couple unrelated logic.
- **Do not big-bang any axis.** Each is a staged, per-call-site migration with a test at every
  step. A single commit retiring N copies is how a working router becomes a broken one (the
  `CapabilityIndex` header makes exactly this warning about its own six predecessors).
- **Do not reconcile matchers before the aggregate eval metric exists** — you'd be changing
  ranking with no way to prove you didn't regress it.

---

## Effort / risk

| Axis | Effort | Risk | Gate |
|---|---|---|---|
| 3 · Stop-words | L (many sites) | M per site, low overall if staged | eval suite green per site |
| 2 · Learners | M | M | confirm events first |
| 1 · Matchers | XL | High | **blocked on** aggregate metric + 02 E2 |

## Relationship to other items

- `01-global-context/routing.md` R2 (stop-words) and R1 (name tiers) are Axis 3 + a prerequisite
  for Axis 1.
- `02-context-dock/engineering.md` E1 (3 matchers) and E2 (extract matcher) are the first steps
  of Axis 1.
- `10-CROSS-CUTTING.md` §1 (aggregate eval metric) is the **gate** for Axis 1.

---

*End of draft. This is the app's biggest structural cleanup and its biggest ranking-quality
lever — but it is worthless, even dangerous, without the eval metric to prove each step is
behaviour-preserving. Sequence accordingly.*
