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
