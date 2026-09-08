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

    private static let mail = GeneralChatScopeResolver.Candidate(
        bundleId: "com.apple.mail", name: "Mail",
        vocabulary: ["mail", "email", "inbox", "message", "sender"])
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
