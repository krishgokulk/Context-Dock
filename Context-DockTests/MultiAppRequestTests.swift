import Foundation
import Testing

@testable import Context_Dock

// One piece of work, two apps.
//
// "create a note all opened tabs in safari." names Notes and Safari and describes a single
// job: read from one, write into the other. General Chat offered to enable Notes, left Safari
// outside the conversation, and the cross-app planner — which needs two apps in scope before
// it will look at a request at all — never ran. What came back was three Notes commands, one
// of which was Edit ▸ Delete Note.

@MainActor
struct MultiAppRequestTests {

    @Test func bothAppsInOneSentenceAreFound() {
        // Notes and Safari ship with macOS, so this holds on any Mac the suite runs on.
        let found = GeneralAIActionResolver.shared.namedInstalledApps(
            in: "put my safari tabs into notes")
        let bundles = Set(found.map { $0.bundleId.lowercased() })
        #expect(bundles.contains("com.apple.notes"))
        #expect(bundles.contains("com.apple.safari"))
    }

    @Test func anAppThatIsOnlyImpliedIsStillFound() {
        // The reported sentence names Safari outright and says "a note" — singular, and not
        // an app name at all. Reading only the names offers half the job.
        let implied = AppScopedChatService.subjectApps(
            in: "create a note all opened tabs in safari")
        let bundles = Set(implied.map { $0.bundleId.lowercased() })
        #expect(bundles.contains("com.apple.notes"))
    }

    @Test func oneAppNamedOnceIsNotReportedTwice() {
        let found = GeneralAIActionResolver.shared.namedInstalledApps(
            in: "open safari and then safari again")
        #expect(found.filter { $0.bundleId.lowercased() == "com.apple.safari" }.count == 1)
    }

    @Test func asentenceNamingNoAppFindsNone() {
        #expect(GeneralAIActionResolver.shared.namedInstalledApps(in: "what is 2 + 2").isEmpty)
    }

    @Test func theOfferCarriesTheSecondAppSoOneTapScopesTheWholeJob() {
        // The reported case, as the gate sees it: a General Chat with nothing attached.
        let request = AppScopedChatService.appNeedingAccess(
            query: "create a note all opened tabs in safari",
            scope: .general,
            attachedAppNames: [])
        #expect(request != nil)
        let bundles = Set((request?.allApps ?? []).map { $0.bundleId.lowercased() })
        #expect(bundles.contains("com.apple.notes"))
        #expect(bundles.contains("com.apple.safari"))
    }

    @Test func anAppAlreadyInTheChatIsNotOfferedAgain() {
        let request = AppScopedChatService.appNeedingAccess(
            query: "create a note all opened tabs in safari",
            scope: .general,
            attachedAppNames: ["Safari"])
        // Safari is already there; the offer is about what is missing.
        let bundles = Set((request?.allApps ?? []).map { $0.bundleId.lowercased() })
        #expect(!bundles.contains("com.apple.safari"))
        #expect(bundles.contains("com.apple.notes"))
    }
}
