import Testing
import Foundation
@testable import Context_Dock

// MARK: - Reading about a thing vs asking for one
//
// This router runs before executable routing, deliberately, so a question about personal
// data is not misread as a command. It had no way to notice the reverse. `create a reminder
// "call sujith" today at 5pm` carries "today" and names the reminders domain, so it was
// classified a read and answered "You have no open reminders" — nothing created, and the
// reply about something else entirely.

@MainActor
struct ReadOnlyDataRouterTests {

    // MARK: The bug

    /// The exact request that was answered with a list.
    @Test func creatingAReminderIsNotReadingReminders() {
        #expect(ReadOnlyDataRouter.domain(for: #"create a reminder "to call sujith " today at 5pm"#) == nil)
        #expect(ReadOnlyDataRouter.domain(for: #"create a reminder "call mum" today at 5pm"#) == nil)
    }

    /// The same shape in every domain this router owns. Each has a read signal and a domain
    /// word, and each is plainly an instruction.
    @Test func writesInEveryDomainFallThroughToExecutableRouting() {
        #expect(ReadOnlyDataRouter.domain(for: "add a meeting to my calendar today") == nil)
        #expect(ReadOnlyDataRouter.domain(for: "delete my recent reminders") == nil)
        #expect(ReadOnlyDataRouter.domain(for: "send a message to my contact today") == nil)
        #expect(ReadOnlyDataRouter.domain(for: "remind me today to call the bank") == nil)
    }

    // MARK: Reads still route

    @Test func questionsAboutPersonalDataStillRoute() {
        #expect(ReadOnlyDataRouter.domain(for: "show me my reminders") == .reminders)
        #expect(ReadOnlyDataRouter.domain(for: "what's on my calendar today") == .calendar)
        #expect(ReadOnlyDataRouter.domain(for: "do i have any unread messages") == .messages)
        #expect(ReadOnlyDataRouter.domain(for: "show me my notes about the launch") == .notes)
    }

    /// The regression the whole-word rule exists for: "saved" is not the verb "save".
    @Test func aVerbInsideAnotherWordDoesNotDisqualifyARead() {
        #expect(ReadOnlyDataRouter.domain(for: "show me my saved reminders") == .reminders)
        #expect(ReadOnlyDataRouter.domain(for: "list the events i created this week") == .calendar)
    }

    // MARK: Neither

    /// Both halves are required. A data word with no read signal, or a read signal with no
    /// data word, is not this router's business.
    @Test func oneHalfAloneIsNotAread() {
        #expect(ReadOnlyDataRouter.domain(for: "what is email") == nil)
        #expect(ReadOnlyDataRouter.domain(for: "reminder") == nil)
        #expect(ReadOnlyDataRouter.domain(for: "") == nil)
    }

    /// A person's details are a contacts lookup even when the sentence names no app.
    @Test func personLookupsRouteToContacts() {
        #expect(ReadOnlyDataRouter.domain(for: "show me salman's phone number") == .contacts)
    }
}

// MARK: - The head noun decides
//
// "find my bookmarks note and summarise that" answered from browser bookmarks. The user
// asked for a *note* — in English a noun phrase is head-final, so "bookmarks note" is a
// note about bookmarks, not a bookmark. The router matched on whichever domain came first
// in its own list rather than on which word the sentence was actually about.

@MainActor
struct ReadDomainHeadNounTests {

    /// The sentence from the report.
    @Test func aBookmarksNoteIsANote() {
        #expect(ReadOnlyDataRouter.domain(for: "find my bookmarks note and summarise that")
            == .notes)
    }

    @Test func theModifierDoesNotWin() {
        #expect(ReadOnlyDataRouter.domain(for: "show me my meeting notes") == .notes)
    }

    /// A phrase states the subject outright and beats a later bare word: "note about the
    /// meeting" is a note, even though "meeting" is the last domain word in it.
    @Test func aPhraseBeatsALaterBareWord() {
        #expect(ReadOnlyDataRouter.domain(for: "find my note about the meeting") == .notes)
    }

    /// Not covered, and deliberately left alone: "find my email notes" resolves to
    /// contacts, because looksLikeContactInfoLookup returns before this map is consulted.
    /// That early return predates the head-noun rule and changing it is a separate
    /// question about what "email" means in a sentence.
    @Test func theContactShortcutStillRunsFirst() {
        #expect(ReadOnlyDataRouter.domain(for: "find my email notes") == .contacts)
    }

    /// Single-domain sentences are unchanged.
    @Test func plainQueriesAreUnaffected() {
        #expect(ReadOnlyDataRouter.domain(for: "what's on my calendar today") == .calendar)
        #expect(ReadOnlyDataRouter.domain(for: "show me my unread messages") == .messages)
        #expect(ReadOnlyDataRouter.domain(for: "list my reminders") == .reminders)
    }

    /// Whole words only: "notebook" is not "note".
    @Test func partialWordsAreNotTheHeadNoun() {
        #expect(ReadOnlyDataRouter.domain(for: "find my notebook charger") != .notes)
    }
}
