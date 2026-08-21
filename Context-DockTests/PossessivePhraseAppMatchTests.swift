import Testing
import Foundation
@testable import Context_Dock

// MARK: - An app name that is also an English phrase
//
// "find my bookmarks note and summarise that" was answered with:
//
//   "Find My isn't in this chat's scope yet. General Chat only reads the apps you
//    choose, so you stay in control — enable it below to let me answer about Find My."
//
// The user named no app. They used a possessive: find / my / bookmarks note. But
// "Find My" is an installed application, `wordPhraseOffset` finds it at position 0, and
// ranking is leftmost-first — so it beat every other candidate in the sentence, including
// the word "note".
//
// The rule cannot be "special-case Find My". It is that an app name which doubles as an
// ordinary English possessive is not an app reference when it is being used as one — and
// the thing that tells them apart is the noun that follows.

@MainActor
struct PossessivePhraseAppMatchTests {

    // MARK: - English, not an app

    /// The sentence from the screenshot.
    @Test func findMyBookmarksNoteIsNotTheFindMyApp() {
        #expect(GeneralAIActionResolver.isPossessiveEnglish(
            "find my bookmarks note and summarise that", phrase: "find my", start: 0))
    }

    /// Every noun a person can own inside their own machine.
    @Test func possessedDataNounsAreNeverAnApp() {
        for noun in ["notes", "note", "bookmarks", "files", "reminders", "emails",
                     "tabs", "photos", "documents", "messages", "downloads", "passwords"] {
            #expect(
                GeneralAIActionResolver.isPossessiveEnglish(
                    "find my \(noun)", phrase: "find my", start: 0),
                "expected 'find my \(noun)' to read as English")
        }
    }

    /// Other verbs form the same phrase.
    @Test func otherVerbsFormTheSamePossessive() {
        #expect(GeneralAIActionResolver.isPossessiveEnglish(
            "show my notes", phrase: "show my", start: 0))
        #expect(GeneralAIActionResolver.isPossessiveEnglish(
            "open my downloads", phrase: "open my", start: 0))
    }

    // MARK: - Genuinely the app

    /// "Find My" is a real app with real uses, and this must keep working. The noun after
    /// the phrase is a device, not something stored on this Mac.
    @Test func findMyIPhoneIsStillTheApp() {
        #expect(!GeneralAIActionResolver.isPossessiveEnglish(
            "find my iphone", phrase: "find my", start: 0))
        #expect(!GeneralAIActionResolver.isPossessiveEnglish(
            "find my airtag", phrase: "find my", start: 0))
        #expect(!GeneralAIActionResolver.isPossessiveEnglish(
            "find my friends", phrase: "find my", start: 0))
    }

    /// Nothing after the phrase at all: "open Find My" is the app, plainly.
    @Test func theBarePhraseIsTheApp() {
        #expect(!GeneralAIActionResolver.isPossessiveEnglish(
            "find my", phrase: "find my", start: 0))
        #expect(!GeneralAIActionResolver.isPossessiveEnglish(
            "open find my", phrase: "find my", start: 5))
    }

    /// A match that has no possessive in it is untouched by this rule — the guard must not
    /// start suppressing ordinary app names.
    @Test func ordinaryAppNamesAreUnaffected() {
        #expect(!GeneralAIActionResolver.isPossessiveEnglish(
            "safari new private window", phrase: "safari", start: 0))
        #expect(!GeneralAIActionResolver.isPossessiveEnglish(
            "open notes and write this down", phrase: "notes", start: 5))
    }

    // MARK: - What should win instead

    /// With "find my" out of the way, the sentence still names a real app, and it is the
    /// one the user meant. This is the whole point of suppressing the phrase.
    @Test func theRealAppInTheSentenceIsFound() {
        let target = GeneralAIActionResolver.shared.namedInstalledApp(in: "find my notes")
        #expect(target?.name != "Find My")
    }
}
