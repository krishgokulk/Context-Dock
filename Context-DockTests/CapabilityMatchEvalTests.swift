import Foundation
import Testing

@testable import Context_Dock

// Evals for whether an app's own tools are even considered.
//
// "Add current page to bookmarks note in notes app" produced "Registered tools: no capability
// matched" and then offered to click `Edit → Add Link…` in Notes. notes.append was never in
// the running: the only word the sentence shared with it was "note", and "note" was on a
// stopword list meant to stop matching on the app's name. So the word that identifies every
// Notes capability was the word that disqualified them all, and the request fell through to
// driving the menu bar.

@MainActor
struct CapabilityMatchEvalTests {

    private func candidateIDs(_ query: String) -> [String] {
        AppAdapterCapabilityCatalog.registeredCandidates(
            appName: "Notes", bundleID: "com.apple.Notes", query: query
        ).compactMap(\.capabilityID)
    }

    @Test func askingToAddSomethingToNotesFindsANotesCapability() {
        let ids = candidateIDs("add current page to bookmarks note in notes app")
        #expect(!ids.isEmpty, "a note request must reach at least one Notes capability")
    }

    @Test func everydayVerbsReachTheCapabilityNamedAfterTheApi() {
        // People say "add", the capability is called "append"; people say "save", it is
        // called "create". Token overlap alone never bridges that.
        #expect(AppAdapterCapabilityCatalog.verbSynonyms(for: "notes.append").contains("add"))
        #expect(AppAdapterCapabilityCatalog.verbSynonyms(for: "notes.create").contains("save"))
        #expect(AppAdapterCapabilityCatalog.verbSynonyms(for: "notes.search").contains("find"))
    }

    @Test func aRequestAboutSomethingElseDoesNotDragNotesIn() {
        // The other half of the fix: loosening the match must not make every sentence look
        // like a note request.
        #expect(candidateIDs("restart the wifi").isEmpty)
    }
}
