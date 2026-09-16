import Testing
@testable import Context_Dock

struct CrossAppGeneralChatClarifierTests {
    private let safari = (name: "Safari", bundleId: "com.apple.Safari")

    @Test func incompleteCrossAppStatementRequestsOperationAndProjectApp() {
        let answer = CrossAppGeneralChatClarifier.questionIfNeeded(
            query: "currently visited Safari about llbrain.dev, to our project",
            namedApp: safari)

        #expect(answer?.contains("What should I do") == true)
        #expect(answer?.contains("which app currently has the project") == true)
    }

    @Test func explicitCrossAppTaskContinuesToExecution() {
        #expect(CrossAppGeneralChatClarifier.questionIfNeeded(
            query: "Compare the current Safari page with my Code project",
            namedApp: safari) == nil)
    }

    @Test func ordinaryAppQuestionIsNotIntercepted() {
        #expect(CrossAppGeneralChatClarifier.questionIfNeeded(
            query: "What page is currently open in Safari?",
            namedApp: safari) == nil)
    }

    @Test func projectConversationWithoutNamedAppIsNotIntercepted() {
        #expect(CrossAppGeneralChatClarifier.questionIfNeeded(
            query: "I visited a useful page for our project",
            namedApp: nil) == nil)
    }
}
