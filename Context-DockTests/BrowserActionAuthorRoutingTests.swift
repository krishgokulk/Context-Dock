import Testing
@testable import Context_Dock

@MainActor
struct BrowserActionAuthorRoutingTests {
    @Test func installIntoMisspelledVSCodeProjectIsNotAPageScript() {
        let query = "install this to our vscide project"
        #expect(BrowserActionAuthor.isCrossAppProjectRequest(query))
        #expect(!BrowserActionAuthor.looksLikePageAction(query))
    }

    @Test func installIntoWorkspaceIsNotAPageScript() {
        #expect(!BrowserActionAuthor.looksLikePageAction(
            "add this to my current workspace"))
    }

    @Test func actualDOMChangeRemainsAPageScript() {
        #expect(BrowserActionAuthor.looksLikePageAction(
            "highlight all prices on this page"))
    }

    @Test func workflowGuidanceRequiresPageFindingBeforeClarification() {
        let guidance = BrowserActionAuthor.crossAppProjectGuidance(
            "install this in my VS Code project")
        #expect(guidance.contains("Read the supplied current-page evidence"))
        #expect(guidance.contains("require the exact project/workspace"))
        #expect(guidance.contains("Never answer that a page script cannot access local files"))
    }
}
