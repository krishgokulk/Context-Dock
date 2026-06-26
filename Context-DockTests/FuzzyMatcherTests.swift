import Testing
@testable import Context_Dock

// MARK: - FuzzyMatcher Tests
// FuzzyMatcher is pure static logic with no I/O, AppKit, or singleton
// dependencies — it's the ideal starting point for the test suite.

struct FuzzyMatcherTests {

    // MARK: Basic matching

    @Test func exactMatchScoresHighest() {
        let score = FuzzyMatcher.score("safari", against: "Safari")
        #expect(score == 1000.0)
    }

    @Test func prefixMatchScoresAbove900() {
        let score = FuzzyMatcher.score("saf", against: "Safari")
        #expect((score ?? 0) >= 900)
    }

    @Test func noMatchReturnsNil() {
        let score = FuzzyMatcher.score("xyz", against: "Safari")
        #expect(score == nil)
    }

    @Test func emptyQueryReturnsNil() {
        let score = FuzzyMatcher.score("", against: "Safari")
        #expect(score == nil)
    }

    @Test func emptyTargetReturnsNil() {
        let score = FuzzyMatcher.score("safari", against: "")
        #expect(score == nil)
    }

    // MARK: Acronym matching

    @Test func acronymMatchReturnsScore() {
        // "gc" should match "Google Chrome" (first letters of each word)
        let score = FuzzyMatcher.score("gc", against: "Google Chrome")
        #expect(score != nil)
        #expect((score ?? 0) >= 850)
    }

    @Test func partialAcronymMatchReturnsScore() {
        let score = FuzzyMatcher.score("vs", against: "Visual Studio")
        #expect(score != nil)
        #expect((score ?? 0) >= 850)
    }

    // MARK: CamelCase matching

    @Test func camelCaseMatchAddsBonus() {
        // "gc" → "googleChrome" (uppercase G, C extracted)
        let score = FuzzyMatcher.score("gc", against: "googleChrome")
        #expect(score != nil)
    }

    // MARK: Ranking — better matches score higher

    @Test func exactMatchBeatsPrefixMatch() {
        let exact = FuzzyMatcher.score("safari", against: "Safari") ?? 0
        let prefix = FuzzyMatcher.score("safari", against: "Safari Browser") ?? 0
        #expect(exact > prefix)
    }

    @Test func prefixMatchBeatsMidwordMatch() {
        let prefix = FuzzyMatcher.score("not", against: "Notes") ?? 0
        let mid = FuzzyMatcher.score("not", against: "Cannot") ?? 0
        #expect(prefix > mid)
    }

    @Test func consecutiveMatchScoresHigherThanSpread() {
        // "abc" consecutive in "abc xyz" should beat spread "a_b_c_d"
        let consecutive = FuzzyMatcher.score("abc", against: "abcdef") ?? 0
        let spread = FuzzyMatcher.score("abc", against: "a1b2c3") ?? 0
        #expect(consecutive > spread)
    }

    // MARK: Case insensitivity

    @Test func caseInsensitiveQuery() {
        let lower = FuzzyMatcher.score("safari", against: "Safari") ?? 0
        let upper = FuzzyMatcher.score("SAFARI", against: "Safari") ?? 0
        #expect(lower == upper)
    }

    @Test func caseInsensitiveTarget() {
        let mixed = FuzzyMatcher.score("saf", against: "SAFARI") ?? 0
        let lower = FuzzyMatcher.score("saf", against: "safari") ?? 0
        #expect(mixed == lower)
    }

    // MARK: Word-boundary bonus

    @Test func wordBoundaryMatchScoresHigher() {
        // "note" at word boundary in "Notes App" vs mid-word in "Endnotes"
        let boundary = FuzzyMatcher.score("note", against: "Notes App") ?? 0
        let midword = FuzzyMatcher.score("note", against: "Endnotes") ?? 0
        #expect(boundary > midword)
    }

    // MARK: Pre-lowercased variant

    @Test func lowercasedVariantMatchesNormalVariant() {
        let normal = FuzzyMatcher.score("safari", against: "Safari")
        let lowercased = FuzzyMatcher.score("safari", againstLower: "safari", original: "Safari")
        #expect(normal == lowercased)
    }

    @Test func lowercasedVariantReturnsNilForNoMatch() {
        let score = FuzzyMatcher.score("xyz", againstLower: "safari", original: "Safari")
        #expect(score == nil)
    }
}
