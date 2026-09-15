import Foundation
import Testing

@testable import Context_Dock

// Which apps a General Chat request touches, when it names none of them.
//
// Today the answer is chatFocusApps — a list the user picks by hand before asking. That is
// "always ask first" wearing a different hat, and it fails the case the feature exists for:
// "where are my invoices?" does not know whether that is Mail, Files or Notes, so the person
// least able to answer is the one being asked.
//
// The decided rule (see "General Chat resolves scope per step and asks only on real ambiguity"):
// resolve from the capability inventory, per step, and ask only when two adapters compete for
// the *same* words. Two adapters matched by *different* words are not ambiguous — they are a
// two-step plan, which is what "find the invoice Sarah sent me and save it to the Client folder"
// actually is.

struct GeneralChatScopeResolverTests {

    // "sent" and "attachment" are Mail's words as much as "inbox" is. Leaving them out is what
    // made the headline case below resolve to Finder alone: "the invoice Sarah sent me" names
    // no app, and a vocabulary of only {mail, email, inbox, message, sender} cannot reach it.
    // Resolution is exactly as good as the vocabulary an adapter declares — see
    // `aRequestThatNamesNoAppNounAtAllIsUnresolved` for where that stops.
    private static let mail = GeneralChatScopeResolver.Candidate(
        bundleId: "com.apple.mail", name: "Mail",
        vocabulary: ["mail", "email", "inbox", "message", "sender", "sent", "attachment"])
    private static let finder = GeneralChatScopeResolver.Candidate(
        bundleId: "com.apple.finder", name: "Finder",
        vocabulary: ["file", "folder", "finder", "downloads", "document"])
    private static let notes = GeneralChatScopeResolver.Candidate(
        bundleId: "com.apple.Notes", name: "Notes",
        vocabulary: ["note", "notes"])
    private static let reminders = GeneralChatScopeResolver.Candidate(
        bundleId: "com.apple.reminders", name: "Reminders",
        vocabulary: ["reminder", "todo", "task"])

    private static let inventory = [mail, finder, notes, reminders]

    private func resolve(_ request: String) -> GeneralChatScopeResolver.Resolution {
        GeneralChatScopeResolver.resolve(request: request, inventory: Self.inventory)
    }

    // MARK: - The sentence this was designed around

    /// Two apps, two different words, one plan. Asking "which app?" here has no single answer —
    /// the honest reply is two answers the user should not have to give.
    @Test func aTwoStepRequestResolvesToBothAppsInOrder() {
        let resolution = resolve("find the invoice Sarah sent me and save it to the Client folder")
        #expect(
            resolution == .resolved(["com.apple.mail", "com.apple.finder"]),
            "mail for the invoice, finder for the folder — got \(resolution)")
    }

    /// Order follows the sentence, because the steps run in that order.
    @Test func theOrderIsTheOrderTheStepsAppearIn() {
        let resolution = resolve("save this file to a note")
        #expect(resolution == .resolved(["com.apple.finder", "com.apple.Notes"]))
    }

    // MARK: - One app

    @Test func oneMatchedAppIsSimplyTheScope() {
        #expect(resolve("any unread email from sarah?") == .resolved(["com.apple.mail"]))
        #expect(resolve("what's in my downloads folder?") == .resolved(["com.apple.finder"]))
    }

    // MARK: - Real ambiguity

    /// Two adapters reached by the *same* word is the case worth asking about — and the ask
    /// names them, rather than being open-ended.
    @Test func adaptersCompetingForTheSameWordAreAmbiguous() {
        let overlapping = [
            Self.notes,
            GeneralChatScopeResolver.Candidate(
                bundleId: "md.obsidian", name: "Obsidian", vocabulary: ["note", "notes", "vault"]),
        ]
        let resolution = GeneralChatScopeResolver.resolve(
            request: "add a note about the launch", inventory: overlapping)
        #expect(
            resolution == .ambiguous(candidates: ["Notes", "Obsidian"]),
            "both own \"note\"; the user has to say which — got \(resolution)")
    }

    /// Ambiguity is per word, not per turn. One contested step does not make the whole request
    /// unanswerable when the other step is clear.
    @Test func oneContestedStepDoesNotPoisonAClearOne() {
        let overlapping = Self.inventory + [
            GeneralChatScopeResolver.Candidate(
                bundleId: "md.obsidian", name: "Obsidian", vocabulary: ["note", "notes"])
        ]
        let resolution = GeneralChatScopeResolver.resolve(
            request: "save this note to my downloads folder", inventory: overlapping)
        #expect(
            resolution == .ambiguous(candidates: ["Notes", "Obsidian"]),
            "the note step is contested and must be asked about before anything runs")
    }

    // MARK: - Nothing to resolve

    /// Nothing matched is not the same as ambiguous. It means no installed adapter serves this,
    /// which is a capability gap and has its own answer.
    @Test func anUnservedRequestResolvesToNothing() {
        #expect(resolve("book me a flight to madurai") == .unresolved)
        #expect(resolve("") == .unresolved)
    }

    /// The limit of the whole approach, stated rather than discovered later.
    ///
    /// A request that describes *content* and names no kind of thing — no "email", no "file",
    /// no "note" — has nothing for a vocabulary to match, and comes back unresolved rather
    /// than guessing. Unresolved is a real answer here: General Chat says it cannot serve the
    /// request, which is honest. Guessing would produce a confident answer about the wrong
    /// app, and a wrong answer about someone's mail looks exactly like a right one.
    @Test func aRequestThatNamesNoAppNounAtAllIsUnresolved() {
        #expect(resolve("find the thing Sarah gave me") == .unresolved)
        #expect(resolve("sort out that stuff from yesterday") == .unresolved)
    }

    /// A word inside another word is not a match. "reminder" must not be found in "remembered",
    /// nor "note" in "noteworthy" — the whole point is that a wrong app is worse than none.
    @Test func matchingIsByWholeWord() {
        #expect(resolve("what did i say about noteworthy things") == .unresolved)
        #expect(resolve("i remembered something") == .unresolved)
    }

    /// Plurals are how people actually write. "invoices", "files", "notes" must reach the same
    /// adapters as their singulars.
    @Test func pluralsReachTheSameAdapters() {
        #expect(resolve("show me my emails") == .resolved(["com.apple.mail"]))
        #expect(resolve("list my files") == .resolved(["com.apple.finder"]))
    }

    // MARK: - The user's own choice still wins

    /// The resolver proposes; it never overrules. When the user has focused apps by hand, that
    /// is an explicit decision and the resolver is not consulted — this is the seam where a
    /// silently-widened scope would otherwise creep in.
    @Test func anExplicitFocusListIsUsedInsteadOfResolving() {
        let resolution = GeneralChatScopeResolver.scope(
            request: "find the invoice Sarah sent me",
            focused: ["com.apple.reminders"],
            inventory: Self.inventory)
        #expect(
            resolution == .resolved(["com.apple.reminders"]),
            "the user picked Reminders; resolving past that would ignore them")
    }

    @Test func anEmptyFocusListFallsBackToResolving() {
        let resolution = GeneralChatScopeResolver.scope(
            request: "any unread email?", focused: [], inventory: Self.inventory)
        #expect(resolution == .resolved(["com.apple.mail"]))
    }
}

// MARK: - Building the inventory from what DoraX already knows
//
// The resolver is only as good as the vocabulary it is given, so where that vocabulary comes
// from is part of the design rather than a detail. It comes from CapabilityIndex's records —
// the app name plus each capability's keywords — and not from titles or descriptions, which are
// prose full of words every adapter shares.

struct GeneralChatScopeInventoryTests {

    private func record(
        id: String, app: String, keywords: [String], isWrite: Bool = false
    ) -> CapabilityRecord {
        CapabilityRecord(
            id: id, app: app, kind: .capability, title: "Get Something",
            description: "Reads the current thing from the app", keywords: keywords,
            isWrite: isWrite)
    }

    private let ids = ["Mail": "com.apple.mail", "Finder": "com.apple.finder"]

    @Test func anAppsVocabularyIsItsNamePlusItsCapabilityKeywords() {
        let inventory = GeneralChatScopeResolver.inventory(
            from: [
                record(id: "mail.search", app: "Mail", keywords: ["email", "inbox"]),
                record(id: "mail.recent", app: "Mail", keywords: ["message", "unread"]),
            ],
            bundleId: { self.ids[$0] })

        #expect(inventory.count == 1, "one app, one candidate")
        let mail = inventory[0]
        #expect(mail.bundleId == "com.apple.mail")
        for word in ["mail", "email", "inbox", "message", "unread"] {
            #expect(mail.vocabulary.contains(word), "\(word) should reach Mail")
        }
    }

    /// Prose is excluded on purpose. "Get Something" and "Reads the current thing" contain words
    /// every adapter would claim, and an inventory where everything matches everything makes
    /// every request contested — which reads to the user as being asked "which app?" constantly.
    @Test func titlesAndDescriptionsAreNotVocabulary() {
        let inventory = GeneralChatScopeResolver.inventory(
            from: [record(id: "mail.search", app: "Mail", keywords: ["email"])],
            bundleId: { self.ids[$0] })

        for prose in ["get", "something", "reads", "current", "thing", "from", "the", "app"] {
            #expect(
                !inventory[0].vocabulary.contains(prose),
                "\"\(prose)\" is prose and belongs to every adapter")
        }
    }

    /// An app whose name does not map to a bundle id is dropped, not guessed at. A candidate
    /// with the wrong id sends a whole step to the wrong app, which is the failure this whole
    /// design is trying to avoid.
    @Test func anAppWithNoBundleIdIsLeftOut() {
        let inventory = GeneralChatScopeResolver.inventory(
            from: [
                record(id: "mail.search", app: "Mail", keywords: ["email"]),
                record(id: "ghost.do", app: "Uninstalled App", keywords: ["ghost"]),
            ],
            bundleId: { self.ids[$0] })

        #expect(inventory.map(\.name) == ["Mail"])
    }

    /// Machine-wide commands have no app, so they belong to no candidate.
    @Test func recordsWithNoAppAreSkipped() {
        let inventory = GeneralChatScopeResolver.inventory(
            from: [record(id: "globalcmd.sleep", app: "", keywords: ["sleep"])],
            bundleId: { self.ids[$0] })
        #expect(inventory.isEmpty)
    }

    /// Short and numeric fragments reach everything, so they are not vocabulary. "to" in a
    /// keyword list would make every sentence match every app.
    @Test func shortAndNumericFragmentsAreNotVocabulary() {
        let inventory = GeneralChatScopeResolver.inventory(
            from: [record(id: "mail.search", app: "Mail", keywords: ["to", "v2", "email"])],
            bundleId: { self.ids[$0] })

        #expect(!inventory[0].vocabulary.contains("to"))
        #expect(!inventory[0].vocabulary.contains("v2"))
        #expect(inventory[0].vocabulary.contains("email"))
    }
}
