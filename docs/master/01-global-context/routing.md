# 01 · Global Context — Routing & ranking

How the right result reaches the top. The ranker: `GlobalSearchService.query` (`:155`) gathers
n-gram candidates (`grams`, `:115`) then scores each with `matchScore` (`:339`) +
`learnedUsageBoost` (`:430`); `insertRanked` (`:501`) keeps a stable top-N.

---

## R1 · Name the magic-number tiers `[proposed · high leverage]`
- **Finding:** `matchScore` is built from bare literals — `12_000` exact, `10_600` word-exact,
  `9_600` full-prefix, `8_900` word-prefix, `8_000` acronym, `11_250` all-words, `4_900`
  substring, plus per-tier `+ q.count*20`, `- i*34`, etc. Nothing names or documents the
  ordering; a score "you cannot reason about" is the exact thing `CapabilityIndex`'s header
  warns against — and this is the ranker actually in use.
- **Why:** you can't tune, test, or explain what has no names. Every intelligence item below is
  blocked on this.
- **Fix:** extract a `enum MatchTier { static let exact = 12_000 … }` with a one-line doc per
  tier; leave behaviour identical (pure rename). Add a comment block stating the intended
  precedence: exact > word-exact/alias-exact > all-words > full-prefix > word-prefix > acronym
  > substring.
- **Effort:** M · **Risk:** low if it's a pure constant-extraction (byte-identical scores);
  verify with the existing eval suite on a Mac.

## R2 · Consolidate the ≥9 stop-word lists `[proposed · highest leverage, cross-cutting]`
- **Finding:** independent stop/filler/ignorable sets exist in at least:
  `GlobalSearchService.swift:399` (`ignorable`), `CapabilityIndex.swift:194` (`filler`),
  `L2AppActionRouter.swift:96` (`fillerWords`), `AgentToolRegistry.swift:864` (`stopwords`),
  `GeneralAIActionResolver.swift:1145` (inline filler), `OnDeviceToolBridge.swift:384`
  (`stopWords`), `AppMenuCapabilityCache.swift:742` (`fillerWords`),
  `OnDeviceStructuredStubs.swift:92` (`filler`), `ContactSearchManager.swift:234` (`stopWords`).
- **Why:** divergent lists are how "note"/"file"/"message" get eaten in one router and kept in
  another — the precise class of bug `CapabilityMatchEvalTests` exists to catch. Nine sources of
  truth means nine ways to reintroduce it.
- **Fix (staged, low-risk):**
  1. Create one `StopWords` type with **named, documented sets** — a tiny "grammatical" set
     (the/and/for…) that is always safe, and separate opt-in "domain-noun" sets (file/note/
     message…) that a caller includes only when correct. Do **not** force one flat list on all
     callers — that's how "note" got eaten.
  2. Migrate call sites one at a time, each behind its own test, keeping current behaviour.
  3. Delete the local copies as each is migrated.
- **Effort:** L (many call sites) · **Risk:** M per site; do it incrementally, never big-bang.
  This is the single change that most reduces routing regressions app-wide.

## R3 · Make the source hierarchy explicit `[proposed]`
- **Finding:** `matchScore` base = `sourceKind.rawValue + rankingBoost + learnedBoost`
  (`:340`). The raw value of the source enum silently sets a floor per source type, so source
  ordering is encoded in enum order, undocumented.
- **Why:** "why did a running-app rank above a menu command?" has no readable answer today.
- **Fix:** document the intended source precedence beside the enum, and assert it in a test
  (e.g. equal-text app vs menu → app wins by exactly the source delta).
- **Effort:** S · **Risk:** low.

## R4 · Expose "why ranked" (match reasons) `[proposed]`
- **Finding:** `CapabilityIndex.Hit` carries `matched` + `coverage` (explainable); the live
  `GlobalSearchService` path returns only a score.
- **Why:** explainability is both a debugging tool and a user feature ("matched: 'saf' → Safari").
  It's also the prerequisite for the aggregate eval metric (you score *why*, not just rank).
- **Fix:** thread an optional `matchedTerms`/tier out of `matchScore` for diagnostics; off the
  hot path by default.
- **Effort:** M · **Risk:** low.

---

## Validation
R1/R3 are behaviour-preserving → the eval suite must stay **byte-green**. R2/R4 change behaviour
→ add tests first, then migrate. All verified via `./scripts/test.sh` on a Mac.
