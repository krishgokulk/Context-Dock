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

    /// "short 4 line summary of this page." opens with none of the question words, so it
    /// reached the imperative fallback — mentions "page", under ten words — and the dock
    /// wrote a JavaScript panel for a request that only wanted the page read back.
    @Test func summarisingThePageIsAReadNotAPageScript() {
        #expect(!BrowserActionAuthor.looksLikePageAction(
            "short 4 line summary of this page."))
        #expect(!BrowserActionAuthor.looksLikePageAction(
            "tldr this page"))
        #expect(!BrowserActionAuthor.looksLikePageAction(
            "translate this page to tamil"))
    }

    @Test func workflowGuidanceRequiresPageFindingBeforeClarification() {
        let guidance = BrowserActionAuthor.crossAppProjectGuidance(
            "install this in my VS Code project")
        #expect(guidance.contains("Read the supplied current-page evidence"))
        #expect(guidance.contains("require the exact project/workspace"))
        #expect(guidance.contains("Never answer that a page script cannot access local files"))
    }
}
