import Foundation
import Testing

@testable import Context_Dock

// What may be offered as "Run it?".
//
// The reported turn: "rewrite make it as next fix current note" in a Notes chat offered
// **Create Apple Note**, the owner approved it, and it failed with `Missing capability input:
// title`. Nothing had gone wrong at execution time — the offer was impossible before it was
// made, twice over.

struct ActionReadinessTests {

    private func candidate(
        capabilityID: String?, required: [String] = [], values: [String: String] = [:]
    ) -> DoraXActionCandidate {
        var made = DoraXActionCandidate(
            id: capabilityID ?? "candidate",
            title: "Candidate",
            appName: "Notes",
            bundleID: "com.apple.Notes",
            source: .appAdapter,
            route: .adapter,
            capabilityID: capabilityID,
            requiredInputs: required,
            riskLevel: .medium,
            confidence: 0.9,
            permissionKey: "com.apple.Notes",
            debugReason: "test")
        made.inputValues = values
        return made
    }

    @Test func aCapabilityMissingItsRequiredInputCannotRun() {
        // The exact failure: notes.create offered with no title and no body.
        let offered = candidate(capabilityID: "notes.create", required: ["title", "body"])
        #expect(!ActionReadiness.canRun(offered))
    }

    @Test func blankIsMissing() {
        // A key present with whitespace in it is the same as absent, and the executor's own
        // guard treats it that way — `guard let title, !title.isEmpty`.
        let offered = candidate(
            capabilityID: "notes.create", required: ["title"], values: ["title": "   "])
        #expect(!ActionReadiness.canRun(offered))
    }

    @Test func aFilledCapabilityRuns() {
        let offered = candidate(
            capabilityID: "notes.create", required: ["title", "body"],
            values: ["title": "Shopping", "body": "Milk"])
        #expect(ActionReadiness.canRun(offered))
    }

    @Test func aRouteWithNoRequiredInputsAlwaysRuns() {
        // Menu and keyboard routes declare none; this filter must not touch them.
        #expect(ActionReadiness.canRun(candidate(capabilityID: nil)))
    }

    @Test func rewritingSomethingIsNotCreatingIt() {
        for request in [
            "rewrite make it as next fix current note",
            "update this note",
            "edit the current note",
            "fix that note",
            "replace the existing note body",
        ] {
            #expect(
                ActionReadiness.namesExistingItem(request),
                "\"\(request)\" is about something that already exists")
        }
    }

    @Test func makingANewThingStillReachesCreate() {
        for request in [
            "create a note about the release",
            "note down the build numbers",
            "add a note titled Shopping",
        ] {
            #expect(
                !ActionReadiness.namesExistingItem(request)
                    || request.lowercased().contains("new"),
                "\"\(request)\" should still be able to create")
        }
    }

    @Test func theWordNewWins() {
        // "rewrite this as a new note" is a create, and the person who typed "new" meant it.
        #expect(!ActionReadiness.namesExistingItem("rewrite this as a new note"))
    }

    @Test func createVerbsAreReadFromTheCapabilityID() {
        #expect(ActionReadiness.createsSomethingNew(capabilityID: "notes.create"))
        #expect(ActionReadiness.createsSomethingNew(capabilityID: "reminders.create"))
        #expect(ActionReadiness.createsSomethingNew(capabilityID: "calendar.add"))
        #expect(!ActionReadiness.createsSomethingNew(capabilityID: "notes.update"))
        #expect(!ActionReadiness.createsSomethingNew(capabilityID: "notes.append"))
        #expect(!ActionReadiness.createsSomethingNew(capabilityID: nil))
    }

    @MainActor
    @Test func aDestructiveCommandIsNotAnAnswerToAConstructiveRequest() {
        // Asked to create a note, the offer list's third row was `Edit ▸ Delete Note`. Word
        // overlap put it there — "note" matched — and one mis-click loses the user's work.
        var candidate = candidate(capabilityID: nil)
        candidate.menuPath = ["Edit", "Delete Note"]
        #expect(!ActionReadiness.isOfferable(candidate, query: "create a note of my open tabs"))
    }

    @MainActor
    @Test func askingToDeleteStillOffersDelete() {
        // The rule is about mismatched intent, not about hiding destructive commands from
        // someone who asked for one.
        var candidate = candidate(capabilityID: nil)
        candidate.menuPath = ["Edit", "Delete Note"]
        #expect(ActionReadiness.isOfferable(candidate, query: "delete this note"))
    }

    @Test func destructiveIntentIsReadFromTheRequestsOwnWords() {
        for request in ["delete this note", "empty the trash", "remove that file", "send it"] {
            #expect(ActionReadiness.asksToDestroy(request), "\"\(request)\"")
        }
        for request in ["create a note of my open tabs", "summarise this page", "open safari"] {
            #expect(!ActionReadiness.asksToDestroy(request), "\"\(request)\"")
        }
    }

    @Test func anOfferNamesEveryAppItWouldEnable() {
        // A button saying "Notes" that quietly also enables Safari is a scope change the
        // user did not agree to.
        let request = EnableAppRequest(
            name: "Notes", bundleId: "com.apple.Notes",
            query: "create a note of all open tabs in safari",
            companions: [.init(name: "Safari", bundleId: "com.apple.Safari")])
        #expect(request.appsSentence == "Notes and Safari")
        #expect(request.allApps.count == 2)

        let single = EnableAppRequest(
            name: "Notes", bundleId: "com.apple.Notes", query: "notes about the release")
        #expect(single.appsSentence == "Notes")
    }

    @Test func theReportedOfferIsRefusedOnBothCounts() {
        let create = candidate(capabilityID: "notes.create", required: ["title", "body"])
        #expect(!ActionReadiness.isOfferable(create, query: "rewrite current note"))

        // …and the capability that actually does the job is still offerable, once it has the
        // note it is meant to change.
        let update = candidate(
            capabilityID: "notes.update", required: ["noteID"],
            values: ["noteID": "x-coredata://ICNote/p2044", "body": "new text"])
        #expect(ActionReadiness.isOfferable(update, query: "rewrite current note"))
    }
}
