import Testing
import Foundation
@testable import Context_Dock

// MARK: - What the sentence is actually looking for
//
// Siri, asked "find my bookmarks note and summarise that", searched Notes, found three
// candidates and asked which one. DoraX dumped fifteen recent notes.
//
// Not a difference in intelligence. DoraX picked its search term like this:
//
//     let nameGuess = query.split(separator: " ").map(String.init)
//         .filter { $0.first?.isUppercase ?? false }
//         .max(by: { $0.count < $1.count }) ?? ""
//
// The search term was whichever capitalised word was longest. Type in lower case and
// there is no term at all, so it stopped searching and listed recent items instead — with
// "bookmarks" sitting in the sentence, unused.

struct DataSubjectTests {

    // MARK: - The sentence from the report

    @Test func theSubjectIsFoundInLowerCase() {
        #expect(DataSubject.subject(in: "find my bookmarks note and summarise that")
            == "bookmarks")
    }

    @Test func capitalisationIsNotRequiredAndNotSpecial() {
        #expect(DataSubject.subject(in: "find my Bookmarks note") == "bookmarks")
        #expect(DataSubject.subject(in: "open my project alpha note") == "project alpha")
    }

    /// Several words are one subject. Taking only the longest threw away half the name.
    @Test func multiWordSubjectsSurvive() {
        #expect(DataSubject.subject(in: "show me my quarterly review notes")
            == "quarterly review")
    }

    // MARK: - Nothing to search for

    /// "show my notes" names no subject, and searching for "" would match everything.
    /// An empty subject is the signal to list recent items, which is the right answer here.
    @Test func aBareDomainHasNoSubject() {
        #expect(DataSubject.subject(in: "show my notes") == "")
        #expect(DataSubject.subject(in: "list my reminders") == "")
        #expect(DataSubject.subject(in: "what's on my calendar today") == "")
    }

    // MARK: - What gets stripped

    /// The domain noun is not the subject: in "bookmarks note", "note" says where to look
    /// and "bookmarks" says what to look for.
    @Test func domainNounsAreNotTheSubject() {
        #expect(!DataSubject.subject(in: "find my bookmarks note").contains("note"))
        #expect(!DataSubject.subject(in: "find my standup reminder").contains("reminder"))
    }

    /// Verbs and filler are instructions to DoraX, not things to search Notes for.
    @Test func verbsAndFillerAreStripped() {
        let subject = DataSubject.subject(in: "please find my invoice note and summarise it")
        #expect(subject == "invoice")
    }

    /// Dates belong to the query, not to the title being searched for.
    @Test func timeWordsAreNotSubjects() {
        #expect(DataSubject.subject(in: "show me today's notes") == "")
    }
}
