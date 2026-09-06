import Foundation
import Testing

@testable import Context_Dock

/// Which apps a protocol-only answer may be recovered through.
///
/// The recovery itself runs routes and needs a live machine; this is the decision in front of
/// it — who to ask, in what order — which is a value question and the part that was wrong.
@Suite("Chat route recovery")
struct ChatRouteRecoveryTests {
    private func bundleID(_ name: String) -> String? {
        switch name {
        case "Messages": return "com.apple.MobileSMS"
        case "Code": return "com.microsoft.VSCode"
        case "Ghost": return nil
        default: return nil
        }
    }

    @Test func appScopeAsksItsOwnApp() {
        let candidates = ChatRouteRecovery.candidateApps(
            scope: .app(bundleId: "com.apple.MobileSMS"),
            attachedAppNames: [],
            scopeAppName: "Messages",
            bundleID: bundleID)

        #expect(candidates.map(\.bundleID) == ["com.apple.MobileSMS"])
    }

    /// The failure that started this: a combined thread had no recovery at all, so a resolved
    /// Messages call was reported undeliverable instead of being run.
    @Test func combinedThreadAsksEveryMemberInOrder() {
        let candidates = ChatRouteRecovery.candidateApps(
            scope: .thread(id: "combined-code+messages"),
            attachedAppNames: ["Messages", "Code"],
            scopeAppName: nil,
            bundleID: bundleID)

        #expect(candidates.map(\.bundleID) == ["com.apple.MobileSMS", "com.microsoft.VSCode"])
        #expect(candidates.map(\.name) == ["Messages", "Code"])
    }

    @Test func generalWithOneAttachedAppAsksThatApp() {
        let candidates = ChatRouteRecovery.candidateApps(
            scope: .general,
            attachedAppNames: ["Code"],
            scopeAppName: nil,
            bundleID: bundleID)

        #expect(candidates.map(\.bundleID) == ["com.microsoft.VSCode"])
    }

    @Test func generalWithNothingAttachedHasNobodyToAsk() {
        let candidates = ChatRouteRecovery.candidateApps(
            scope: .general,
            attachedAppNames: [],
            scopeAppName: nil,
            bundleID: bundleID)

        #expect(candidates.isEmpty)
    }

    /// The scope's own app leads: it is what the thread is about, so its routes are tried
    /// before an app that was merely attached to the conversation.
    @Test func scopeAppLeadsAndIsNeverAskedTwice() {
        let candidates = ChatRouteRecovery.candidateApps(
            scope: .app(bundleId: "com.microsoft.VSCode"),
            attachedAppNames: ["Messages", "Code"],
            scopeAppName: "Code",
            bundleID: bundleID)

        #expect(candidates.map(\.bundleID) == ["com.microsoft.VSCode", "com.apple.MobileSMS"])
    }

    @Test func anAppWithNoBundleIDIsSkippedRatherThanFailingTheRest() {
        let candidates = ChatRouteRecovery.candidateApps(
            scope: .general,
            attachedAppNames: ["Ghost", "Messages"],
            scopeAppName: nil,
            bundleID: bundleID)

        #expect(candidates.map(\.bundleID) == ["com.apple.MobileSMS"])
    }
}
