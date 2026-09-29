import Foundation
import Testing

@testable import Context_Dock

// MARK: - Task 16e: Edit → Copy is not an answer to "where is it"
//
// Asked "find my passport pdfs gokulakannan" in a Finder chat, the offer DoraX built was
// `Edit → Copy`. Nothing about Copy has anything to do with finding a file; it got there
// because ranking is word overlap and every app has an Edit menu, so the generic rows are
// always in the pool and always match something.
//
// A search request must not be able to reach them at all. The rule is deliberately small:
// the five or six commands every Mac app has, under Edit, against a request that asks
// where something is.

@MainActor
struct SearchIsNotAnEditCommandTests {

    private func menuCandidate(_ path: [String]) -> DoraXActionCandidate {
        var made = DoraXActionCandidate(
            id: "menu.\(path.joined(separator: "."))",
            title: path.last ?? "",
            appName: "Find My",
            bundleID: "com.apple.findmy",
            source: .cachedMenu,
            route: .verifiedMenu,
            capabilityID: nil,
            requiredInputs: [],
            riskLevel: .low,
            confidence: 0.5,
            permissionKey: "generalAI.execute.menu",
            debugReason: "test")
        made.menuPath = path
        return made
    }

    // MARK: - The reported offer

    @Test func theReportedOfferIsRefused() {
        #expect(!ActionReadiness.isOfferable(
            menuCandidate(["Edit", "Copy"]),
            query: "find my passport pdfs gokulakannan"))
    }

    @Test func noGenericEditCommandAnswersASearch() {
        for command in ["Copy", "Paste", "Cut", "Select All", "Undo", "Redo"] {
            #expect(
                !ActionReadiness.isOfferable(
                    menuCandidate(["Edit", command]), query: "find the lease pdf"),
                "Edit → \(command)")
        }
    }

    @Test func everyWayOfAskingWhereSomethingIsCounts() {
        for request in ["find the invoice", "search for the lease", "where is my passport",
                        "locate the tax return", "looking for last year's receipts"] {
            #expect(ActionReadiness.asksToFind(request), "\"\(request)\"")
        }
        for request in ["copy this", "create a note", "open safari", "send it"] {
            #expect(!ActionReadiness.asksToFind(request), "\"\(request)\"")
        }
    }

    // MARK: - What the rule must not swallow

    @Test func askingToCopyStillOffersCopy() {
        // The rule is about a mismatch, not about hiding Copy.
        #expect(ActionReadiness.isOfferable(
            menuCandidate(["Edit", "Copy"]), query: "copy this to the clipboard"))
    }

    @Test func theAppsOwnFindCommandIsStillAnAnswer() {
        // Edit → Find is exactly what somebody searching inside an app wants.
        #expect(ActionReadiness.isOfferable(
            menuCandidate(["Edit", "Find", "Find…"]), query: "find the word lease on this page"))
    }

    @Test func aMeaningfulCommandThatHappensToBeCalledCopyIsUntouched() {
        // Only the Edit menu's generic rows. "Share → Copy Link" is a real action.
        #expect(!ActionReadiness.isGenericEditCommand(
            path: ["Share", "Copy Link"], title: "Copy Link"))
        #expect(!ActionReadiness.isGenericEditCommand(
            path: ["File", "Copy to iCloud"], title: "Copy to iCloud"))
        #expect(ActionReadiness.isGenericEditCommand(path: ["Edit", "Copy"], title: "Copy"))
        #expect(ActionReadiness.isGenericEditCommand(
            path: ["Edit", "Paste and Match Style"], title: "Paste and Match Style"))
    }

    @Test func aSearchThatNamesNoMenuIsUnaffected() {
        // A real capability answering a search request keeps its place in the list.
        var capability = DoraXActionCandidate(
            id: "capability.notes.search", title: "Search Apple Notes",
            appName: "Notes", bundleID: "com.apple.Notes",
            source: .mcp, route: .adapter, capabilityID: "notes.search",
            requiredInputs: ["query"], riskLevel: .low, confidence: 0.9,
            permissionKey: "generalAI.execute.notes.search", debugReason: "test")
        capability.inputValues = ["query": "lease"]
        #expect(ActionReadiness.isOfferable(capability, query: "find the lease note"))
    }
}

// MARK: - Task 16e: discovery ranks, approval acts

@MainActor
struct CandidateDiscoveryPolicyTests {

    @Test func discoveryNeverLaunchesAnything() {
        #expect(CandidateDiscoveryPolicy.mayLaunchApps == false)
    }

    @Test func aClosedAppIsSkippedRatherThanOpened() {
        // The reported behaviour: Find My came up on screen while DoraX was still working
        // out what to offer. A closed app is now simply not read.
        let read = CandidateDiscoveryPolicy.menusToRead(
            bundleIDs: ["com.apple.findmy"],
            isRunning: { _ in false },
            isCacheWarm: { _ in false })
        #expect(read.isEmpty)
    }

    @Test func aRunningAppWithAColdCacheIsRead() {
        let read = CandidateDiscoveryPolicy.menusToRead(
            bundleIDs: ["com.apple.Safari"],
            isRunning: { _ in true },
            isCacheWarm: { _ in false })
        #expect(read == ["com.apple.Safari"])
    }

    @Test func anAlreadyWarmAppIsNotReadAgain() {
        let read = CandidateDiscoveryPolicy.menusToRead(
            bundleIDs: ["com.apple.Safari"],
            isRunning: { _ in true },
            isCacheWarm: { _ in true })
        #expect(read.isEmpty)
    }

    @Test func scopePlaceholdersAndDuplicatesAreDropped() {
        let read = CandidateDiscoveryPolicy.menusToRead(
            bundleIDs: ["scope://files", "", "com.apple.Notes", "com.apple.notes"],
            isRunning: { _ in true },
            isCacheWarm: { _ in false })
        #expect(read == ["com.apple.Notes"])
    }

    @Test func theRunningOnesSurviveAMixedList() {
        let read = CandidateDiscoveryPolicy.menusToRead(
            bundleIDs: ["com.apple.findmy", "com.apple.Safari", "com.apple.Notes"],
            isRunning: { $0 != "com.apple.findmy" },
            isCacheWarm: { $0 == "com.apple.Notes" })
        #expect(read == ["com.apple.Safari"])
    }
}
