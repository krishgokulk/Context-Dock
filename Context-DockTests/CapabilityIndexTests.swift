import Testing
import Foundation
@testable import Context_Dock

// MARK: - One index, one ranking
//
// Step 1 of docs/architecture/FRONTMOST_AGENT.md. Six matchers each score their own slice
// of the capability layer with their own rules, and every failure reported this week is two
// of them disagreeing or none of them firing.
//
// These test the ranking on its own, against a corpus built in the test, because the point
// of the index is that it is explainable: a score you cannot reason about is worse than one
// that is merely adequate.

struct CapabilityIndexTests {

    private var corpus: [CapabilityRecord] {
        [
            .init(id: "globalcmd.open-social", app: "Safari", kind: .globalCommand,
                  title: "Open Social",
                  description: "Open social media sites in the browser",
                  keywords: ["social", "open"], isWrite: true),
            .init(id: "finder.trash", app: "Finder", kind: .capability,
                  title: "Empty Trash",
                  description: "Permanently remove everything in the Trash",
                  keywords: ["trash", "empty", "bin"], isWrite: true),
            .init(id: "notes.search", app: "Notes", kind: .capability,
                  title: "Search Notes",
                  description: "Find a note by title or content",
                  keywords: ["note", "notes", "search"], isWrite: false),
            .init(id: "code.newWindow", app: "Code", kind: .adapterAction,
                  title: "New Window",
                  description: "Open a new editor window",
                  keywords: ["window", "new", "open"], isWrite: true),
            .init(id: "safari.newTab", app: "Safari", kind: .adapterAction,
                  title: "New Tab",
                  description: "Open a new browser tab",
                  keywords: ["tab", "new", "open"], isWrite: true),
        ]
    }

    private func search(_ query: String) -> [CapabilityIndex.Hit] {
        CapabilityIndex(records: corpus).search(query)
    }

    // MARK: - The sentence that started this

    /// "is this page related to our contextdock project in any ways you think?" shares no
    /// distinctive word with anything in the index. It was answered with "Run Open Social".
    /// The right answer is no candidate at all, which lets the caller answer in prose.
    @Test func aQuestionSharingNothingDistinctiveMatchesNothing() {
        let hits = search("is this page related to our contextdock project in any ways you think?")
        #expect(hits.isEmpty)
    }

    /// The reason it must not match: "open" and "social" are common across the index, so
    /// they carry almost no information. A word appearing in many capabilities counts for
    /// less than one appearing in few — that is the whole of idf, and it is the signal the
    /// old token-overlap matcher threw away.
    @Test func commonWordsCarryLessThanRareOnes() {
        let index = CapabilityIndex(records: corpus)
        // "open" is in three records, "trash" in one.
        #expect(index.weight(of: "trash") > index.weight(of: "open"))
    }

    /// The protective half of idf, which the test above does not exercise: the sentence
    /// about a project matched nothing because it shared no words at all. This is the case
    /// where words *do* overlap and the ranking still has to prefer the informative one.
    /// A common word must not out-score a rare one, or "open" starts winning sentences.
    @Test func aCommonWordCannotOutscoreARareOne() {
        let common = search("open").first?.score ?? 0
        let rare = search("trash").first?.score ?? 0
        #expect(rare > common)
    }

    // MARK: - Naming a capability

    @Test func aDistinctiveWordFindsItsCapability() {
        #expect(search("empty the trash").first?.record.id == "finder.trash")
        #expect(search("search my notes").first?.record.id == "notes.search")
    }

    /// Title carries more than description: "window" in a title beats "window" in prose.
    @Test func theTitleCountsForMoreThanTheDescription() {
        #expect(search("new window").first?.record.id == "code.newWindow")
    }

    /// The app named in the sentence decides between two capabilities that are otherwise
    /// alike. "new tab in safari" and "new window in code" differ only by their app.
    @Test func namingTheAppPicksBetweenSimilarCapabilities() {
        #expect(search("new tab in safari").first?.record.id == "safari.newTab")
        #expect(search("new window in code").first?.record.id == "code.newWindow")
    }

    // MARK: - Being explainable

    /// Hits come back in descending score, so "the best one" is a fact rather than an
    /// accident of dictionary order.
    @Test func hitsAreOrderedByScore() {
        let hits = search("open a new tab")
        #expect(hits.count > 1)
        for (a, b) in zip(hits, hits.dropFirst()) { #expect(a.score >= b.score) }
    }

    /// Two capabilities that genuinely tie must come back in a stable order, or the same
    /// sentence resolves differently on different launches.
    @Test func tiesAreStable() {
        let first = search("new")
        let second = search("new")
        #expect(first.map(\.record.id) == second.map(\.record.id))
    }

    /// A tie is what Step 0.5 asks about, so the caller has to be able to see one.
    @Test func aTieIsVisibleToTheCaller() {
        let hits = search("open new")
        #expect(hits.count >= 2)
        if let top = hits.first, let second = hits.dropFirst().first {
            #expect(CapabilityIndex.isTie(top, second) == (top.score - second.score < 0.05))
        }
    }

    // MARK: - Nothing to search

    @Test func anEmptyQueryMatchesNothing() {
        #expect(search("").isEmpty)
        #expect(search("   ").isEmpty)
    }

    /// Filler alone is not a request. "please" and "the" name no capability.
    @Test func fillerAloneMatchesNothing() {
        #expect(search("please the and").isEmpty)
    }
}

// MARK: - The app in scope
//
// "General AI understands, chooses the app, takes that app's adapters and tools, then
// plans and executes." The middle of that is a preference rather than a filter: choosing
// the app first is exactly where "find my bookmarks note" went to Find My, and a hard
// filter on a wrong app leaves nothing to recover with.

struct ScopedCapabilitySearchTests {

    private var corpus: [CapabilityRecord] {
        [
            .init(id: "code.newWindow", app: "Code", kind: .adapterAction,
                  title: "New Window", description: "Open a new editor window",
                  keywords: ["window", "new"], isWrite: true),
            .init(id: "safari.newWindow", app: "Safari", kind: .adapterAction,
                  title: "New Window", description: "Open a new browser window",
                  keywords: ["window", "new"], isWrite: true),
            .init(id: "finder.trash", app: "Finder", kind: .capability,
                  title: "Empty Trash", description: "Remove everything in the Trash",
                  keywords: ["trash", "empty"], isWrite: true),
            .init(id: "globalcmd.darkMode", app: "", kind: .globalCommand,
                  title: "Dark Mode", description: "Toggle system appearance",
                  keywords: ["dark", "appearance"], isWrite: true),
        ]
    }

    private func search(_ q: String, scope: String? = nil) -> [CapabilityIndex.Hit] {
        CapabilityIndex(records: corpus).search(q, scopedTo: scope)
    }

    /// The same words, two apps: the app in front of you decides.
    @Test func theScopedAppWinsBetweenIdenticalCapabilities() {
        #expect(search("new window", scope: "Code").first?.record.id == "code.newWindow")
        #expect(search("new window", scope: "Safari").first?.record.id == "safari.newWindow")
    }

    /// The recovery path, and the reason this is a weight and not a filter. Scoped to Code,
    /// a sentence that plainly names something Finder does still finds it — otherwise
    /// picking the wrong app first makes everything after it wrong and confident.
    @Test func aClearlyNamedCapabilityElsewhereStillWins() {
        #expect(search("empty the trash", scope: "Code").first?.record.id == "finder.trash")
    }

    /// Machine-wide commands belong to no app and must not be demoted for it.
    @Test func globalCommandsAreNotPenalisedByScope() {
        #expect(search("dark mode", scope: "Code").first?.record.id == "globalcmd.darkMode")
    }

    /// Without a scope nothing is boosted, so the ranking is the words alone.
    @Test func withoutAScopeTheWordsDecideAlone() {
        let hits = search("new window")
        #expect(hits.count >= 2)
        #expect(abs((hits[0].score) - (hits[1].score)) < 0.001)
    }
}
