import Foundation
import Testing

@testable import Context_Dock

// Evals for what General Chat does before it has an app, and for telling a broken read from
// an empty one.
//
// Both were the same failure wearing different clothes: the app knew it could not answer, and
// said so in a way the user could do nothing with.

@MainActor
struct GeneralChatScopeFlowEvalTests {

    @Test func aQuestionAboutTalkingSuggestsMessages() {
        // "Who do I talk to most" names no app and needs one. Answering "I can't see your
        // messages" is true and useless; asking which app to open is the answer.
        let suggestions = AppScopedChatService.appSuggestionForUnnamedRequest(
            query: "who do i talk to most", scope: .general, attachedAppNames: [])
        #expect(suggestions.first?.bundleId == "com.apple.MobileSMS")
    }

    @Test func aQuestionThatNamesItsAppIsLeftToTheAccessGate() {
        // Naming the app already goes through the gate that asks about that app. Two prompts
        // for one decision is worse than either.
        let suggestions = AppScopedChatService.appSuggestionForUnnamedRequest(
            query: "what does Safari have in history", scope: .general, attachedAppNames: [])
        #expect(suggestions.isEmpty)
    }

    @Test func aChatThatAlreadyHasAnAppIsNotAskedAgain() {
        let suggestions = AppScopedChatService.appSuggestionForUnnamedRequest(
            query: "who do i talk to most", scope: .general, attachedAppNames: ["Messages"])
        #expect(suggestions.isEmpty)
    }

    @Test func anAppScopedThreadIsNeverAskedToPickAnApp() {
        let suggestions = AppScopedChatService.appSuggestionForUnnamedRequest(
            query: "who do i talk to most",
            scope: .app(bundleId: "com.apple.MobileSMS"), attachedAppNames: [])
        #expect(suggestions.isEmpty)
    }

    @Test func enablingAnAppSaysWhatCameWithIt() {
        // The permission just granted, and the tools it brought, are the most important
        // thing in the conversation at that moment — and were the one thing never shown.
        let summary = GeneralChatWindowModel.scopeSummary(
            for: EnableAppRequest(
                name: "Messages", bundleId: "com.apple.MobileSMS", query: "who do i talk to most"))
        #expect(summary.contains("Messages is now in this chat"))
        #expect(summary.contains("other apps stay out"))
    }
}

struct MessagesReadQualityEvalTests {

    @Test func applescriptNullsCountAsAFailedRead() {
        // macOS restricts the Messages AppleScript dictionary: the read succeeds, returns
        // rows, and carries no facts. That reached the user as "the rest came back as
        // missing value" — AppleScript's null, quoted as though it were data.
        let degraded = """
            missing value | snippet:
            missing value | snippet:
            Tokers | snippet: see you then
            missing value | snippet:
            """
        #expect(MessagesReadQuality.isDegraded(degraded))
    }

    @Test func oneUnnamedGroupChatIsNotABrokenRead() {
        // Proportional, not absolute: an unnamed group thread among named ones is ordinary.
        let fine = """
            Ruby | snippet: on my way
            Naveen | snippet: thanks
            missing value | snippet: group thread
            Salman | snippet: call me
            """
        #expect(!MessagesReadQuality.isDegraded(fine))
    }

    @Test func nothingAtAllIsAlsoAFailedRead() {
        #expect(MessagesReadQuality.isDegraded(""))
        #expect(MessagesReadQuality.isDegraded("   \n  "))
    }
}
