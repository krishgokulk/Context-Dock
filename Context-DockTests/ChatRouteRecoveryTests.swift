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

    /// A drafted message should end in a Send button, not in prose the user has to copy.
    /// The trigger is the request, not the answer: the model's wording varies, the ask does
    /// not, and a heuristic over generated prose would be guessing about our own feature.
    @Test(arguments: [
        "draft a message to salman khan",
        "send salman a text about the release",
        "message sujith that I'm running late",
        "text mum the address",
        "write an imessage to Ann",
    ])
    func aRequestToWriteToSomeoneWantsSending(query: String) {
        #expect(ChatRouteRecovery.wantsMessageComposition(query))
    }

    @Test(arguments: [
        "summarise my last edit",
        "what did I change in this repo",
        "how do I send a message with the API",
        "read the messages from salman",
        "what's in my inbox",
    ])
    func aQuestionAboutMessagesIsNotARequestToSendOne(query: String) {
        #expect(!ChatRouteRecovery.wantsMessageComposition(query))
    }

    /// "Yes" is an answer, not a request. The intent it agrees to was stated a turn earlier,
    /// so resolving routes from the word itself finds nothing and the surface reports that it
    /// could not carry out something the user had just approved.
    @Test(arguments: ["yes", "Yes", "yeah", "yep", "ok", "okay", "sure", "do it", "go ahead", "yes please"])
    func aBareAgreementIsNotARequest(query: String) {
        #expect(ChatRouteRecovery.isBareConfirmation(query))
    }

    @Test(arguments: ["yes, and add the invoice", "ok now delete it", "sure thing — send it to Ann tomorrow"])
    func anAgreementThatCarriesItsOwnRequestStandsAlone(query: String) {
        #expect(!ChatRouteRecovery.isBareConfirmation(query))
    }

    @Test func confirmationResolvesAgainstWhatWasAskedBefore() {
        let history = ["draft a mail to ruby", "open compose window in Mail with this"]
        #expect(
            ChatRouteRecovery.resolutionQuery(current: "yes", previousUserRequests: history)
                == "open compose window in Mail with this")
    }

    @Test func anOrdinaryRequestResolvesAgainstItself() {
        #expect(
            ChatRouteRecovery.resolutionQuery(
                current: "open compose window in Mail",
                previousUserRequests: ["something older"])
                == "open compose window in Mail")
    }

    @Test func aConfirmationWithNothingBeforeItKeepsItsOwnWords() {
        #expect(
            ChatRouteRecovery.resolutionQuery(current: "yes", previousUserRequests: []) == "yes")
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
