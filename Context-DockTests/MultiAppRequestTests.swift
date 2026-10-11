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

// The gate must never ask for the app the chat is already about.
@MainActor
struct ScopedAccessGateTests {

    @Test func aSafariChatIsNotAskedToEnableSafari() {
        // Asked "list all my open tabs with their URLs" in a Safari-scoped chat, DoraX
        // answered "That needs Safari, and this chat is scoped to Safari" — an offer to
        // enable the app whose chat it already was, and a dead end for a question its own
        // tools can answer.
        let request = AppScopedChatService.appNeedingAccess(
            query: "list all my open tabs with their URLs",
            scope: .app(bundleId: "com.apple.Safari"),
            attachedAppNames: [])
        #expect(
            request == nil,
            "offered: \(request?.allApps.map(\.bundleId).joined(separator: ", ") ?? "nil")")
    }

    @Test func aScopeNamedRatherThanIdentifiedIsStillTheSameApp() {
        // What actually happened: the MCP server's installed-apps cache was cold, the name
        // fell through to `.app(bundleId: "Safari")`, and a gate comparing bundle ids decided
        // Safari was a different app from Safari.
        let request = AppScopedChatService.appNeedingAccess(
            query: "list all my open tabs with their URLs",
            scope: .app(bundleId: "Safari"),
            attachedAppNames: [])
        #expect(
            request == nil,
            "offered: \(request?.allApps.map(\.bundleId).joined(separator: ", ") ?? "nil")")
    }

    @Test func aSafariChatIsStillAskedAboutNotes() {
        // The boundary the gate exists for stays: another app is asked about.
        let request = AppScopedChatService.appNeedingAccess(
            query: "save this page to my notes",
            scope: .app(bundleId: "com.apple.Safari"),
            attachedAppNames: [])
        let bundles = Set((request?.allApps ?? []).map { $0.bundleId.lowercased() })
        #expect(bundles.contains("com.apple.notes"))
        #expect(!bundles.contains("com.apple.safari"))
    }
}

// An app name that is also an ordinary word.
@MainActor
struct AppNameIsAlsoAWordTests {

    @Test func aWordDoingItsOrdinaryJobIsNotARequestForThatApp() {
        // Apple named its apps after nouns people use all day. "read the console output of this
        // page" offered to enable Console.app; the same question with "messages" in a tool name
        // offered Messages.
        for query in [
            "read the console output of the page open in Safari",
            "use the browser_console_messages tool on this page",
            "what music is on this page",
            "show me the photos on this page",
        ] {
            let request = AppScopedChatService.appNeedingAccess(
                query: query, scope: .app(bundleId: "com.apple.Safari"), attachedAppNames: [])
            #expect(
                request == nil,
                "\(query) → offered \(request?.name ?? "nothing")")
        }
    }

    @Test func pointingAtAnAppStillReachesIt() {
        // The cue is how people actually name an app, and these must keep working.
        for (query, expected) in [
            ("save this page to my notes", "com.apple.notes"),
            ("add this link in Notes", "com.apple.notes"),
            ("open this in Messages", "com.apple.mobilesms"),
        ] {
            let request = AppScopedChatService.appNeedingAccess(
                query: query, scope: .app(bundleId: "com.apple.Safari"), attachedAppNames: [])
            let bundles = Set((request?.allApps ?? []).map { $0.bundleId.lowercased() })
            #expect(
                bundles.contains(where: { $0.contains(expected.split(separator: ".").last!) }),
                "\(query) → \(bundles)")
        }
    }

    @Test func theCueRuleIsAboutPointingNotAboutLength() {
        #expect(AppScopedChatService.namesAppDeliberately(query: "open Notes", appName: "Notes"))
        #expect(AppScopedChatService.namesAppDeliberately(query: "Notes: add a line", appName: "Notes"))
        #expect(AppScopedChatService.namesAppDeliberately(query: "put it in the Notes app", appName: "Notes"))
        #expect(!AppScopedChatService.namesAppDeliberately(query: "read the console output", appName: "Console"))
        // A multi-word name is never typed by accident.
        #expect(AppScopedChatService.namesAppDeliberately(
            query: "what does visual studio code say", appName: "Visual Studio Code"))
    }
}
