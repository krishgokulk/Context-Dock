import Foundation
import Testing

@testable import Context_Dock

// MARK: - Task 16e: an app name that is also an ordinary phrase
//
// Owner hand test, Corner Finder App Chat: "find my passport pdfs gokulakannan". DoraX
// answered
//
//   "This needs Find My, not Finder — it would run Edit → Copy there.
//    Allow Find My for this chat and run it?"
//
// and Find My opened before anything was approved. Three separate rules were missing, and
// the first of them is here: the words "find my" opened a request, they did not name an
// application.
//
// An earlier fix listed the nouns that make the phrase English ("find my notes",
// "find my bookmarks"). That only moved the bug one word along — "passport" is not on any
// such list and never will be. The default is now the other way round, and the same test
// covers every Apple app whose name is a word people use: a name that is also ordinary
// English is an app reference only when the sentence points at it.

@MainActor
struct AppNamePhraseRoutingTests {

    /// Ask the rule the way `resolveTargetApp` asks it: the phrase, and where it sits.
    private func readsAsAnApp(_ query: String, _ phrase: String) -> Bool {
        let lowered = query.lowercased()
        guard let range = lowered.range(of: phrase) else {
            Issue.record("\"\(phrase)\" does not appear in \"\(query)\"")
            return false
        }
        let start = lowered.distance(from: lowered.startIndex, to: range.lowerBound)
        return GeneralAIActionResolver.isAppReference(
            in: lowered, original: query, phrase: phrase, start: start)
    }

    // MARK: - The reported sentence

    @Test func theReportedQueryDoesNotNameFindMy() {
        #expect(!readsAsAnApp("find my passport pdfs gokulakannan", "find my"))
    }

    @Test func theReportedQueryResolvesToNoAppAtAll() {
        // End to end through the matcher the Corner's chat actually calls. Nothing in the
        // sentence names an app, so a Finder chat stays in Finder.
        let target = GeneralAIActionResolver.shared.namedInstalledApp(
            in: "find my passport pdfs gokulakannan")
        #expect(target?.name != "Find My", "resolved \(target?.name ?? "nothing")")
    }

    /// The general shape of it: any noun a person keeps on their Mac.
    @Test func aPossessiveAboutTheUsersOwnThingsIsEnglish() {
        for thing in ["passport pdfs", "tax return", "invoice from june", "lease",
                      "screenshots", "notes", "bookmarks", "holiday pictures"] {
            #expect(
                !readsAsAnApp("find my \(thing)", "find my"),
                "\"find my \(thing)\" should read as English")
        }
    }

    // MARK: - Find My, when it really is Find My

    @Test func findMyKeepsWorkingForTheThingsItFinds() {
        for thing in ["iphone", "ipad", "airtag", "airpods", "friends", "devices"] {
            #expect(
                readsAsAnApp("find my \(thing)", "find my"),
                "\"find my \(thing)\" is the app")
        }
    }

    @Test func openFindMyIsTheApp() {
        #expect(readsAsAnApp("open find my", "find my"))
        #expect(readsAsAnApp("find my", "find my"))
    }

    // MARK: - The same rule for the other everyday names

    @Test func aVerbPhraseAtTheStartNeverNamesAnApp() {
        #expect(!readsAsAnApp("photos of the trip please", "photos"))
        #expect(!readsAsAnApp("home improvements list", "home"))
    }

    @Test func anOrdinaryUseOfTheWordIsNotTheApp() {
        #expect(!readsAsAnApp("show photos of the beach", "photos"))
        #expect(!readsAsAnApp("i took notes yesterday", "notes"))
        #expect(!readsAsAnApp("check the weather before we go", "weather"))
        #expect(!readsAsAnApp("read the news about it", "news"))
        #expect(!readsAsAnApp("driving home tonight", "home"))
    }

    @Test func aCueInFrontOfTheNameMakesItTheApp() {
        #expect(readsAsAnApp("open photos", "photos"))
        #expect(readsAsAnApp("put this in photos", "photos"))
        #expect(readsAsAnApp("save it to my notes", "notes"))
        #expect(readsAsAnApp("copy it from messages", "messages"))
        #expect(readsAsAnApp("quit music", "music"))
    }

    @Test func theWordAppIsACueOnItsOwn() {
        #expect(readsAsAnApp("the notes app is slow", "notes"))
    }

    @Test func theNameWrittenAsTheAppWritesItIsTheApp() {
        // Capitalisation is a cue in its own right — but not at the very start of a
        // sentence, where every word gets a capital for free.
        #expect(readsAsAnApp("drafted this Notes entry", "notes"))
        #expect(!readsAsAnApp("Notes entry about the lease", "notes"))
    }

    @Test func theWholeRequestBeingTheNameIsTheApp() {
        // How `installedAppMatch(named:)` asks the question, and how a launcher row asks it.
        #expect(readsAsAnApp("photos", "photos"))
        #expect(readsAsAnApp("reminders", "reminders"))
    }

    @Test func namesThatAreNotEnglishAreUntouched() {
        // The gate exists for ambiguous names only; it must not start suppressing the rest.
        #expect(readsAsAnApp("i was using safari yesterday", "safari"))
        #expect(readsAsAnApp("ghostty quick terminal", "ghostty"))
        #expect(readsAsAnApp("safari new private window", "safari"))
    }

    // MARK: - What the old rule promised, still true

    @Test func theRealAppInTheSentenceIsStillFound() {
        // "find my" is out of the way, and the sentence still names one: "my notes".
        let target = GeneralAIActionResolver.shared.namedInstalledApp(in: "find my notes")
        #expect(target?.name != "Find My")
    }
}

// MARK: - The scoped app wins unless another is named

@MainActor
struct ScopedAppWinsTests {

    @Test func aCandidateForTheScopedAppIsAlwaysAllowed() {
        #expect(ActionReadiness.mayOfferCrossApp(
            candidateApp: "Finder", scopedApp: "Finder", namedApp: nil))
    }

    @Test func aCandidateForAnUnnamedAppIsNotOffered() {
        // The reported prompt: a Finder chat offering to drive Find My, which the sentence
        // never named.
        #expect(!ActionReadiness.mayOfferCrossApp(
            candidateApp: "Find My", scopedApp: "Finder", namedApp: nil))
    }

    @Test func aCandidateForTheAppTheSentenceNamedIsOffered() {
        // "save this page to Notes" from a Safari chat still reaches Notes.
        #expect(ActionReadiness.mayOfferCrossApp(
            candidateApp: "Notes", scopedApp: "Safari", namedApp: "Notes"))
    }

    @Test func namingOneAppDoesNotOpenTheDoorToAnother() {
        #expect(!ActionReadiness.mayOfferCrossApp(
            candidateApp: "Find My", scopedApp: "Safari", namedApp: "Notes"))
    }
}
