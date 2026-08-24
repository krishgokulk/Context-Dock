import Testing
@testable import Context_Dock

struct BrowserPageReadEvidenceTests {
    @Test func extractsPageFieldsForVisibleWorkflowAndReceipt() {
        let block = """
        CURRENT PAGE TITLE: Install Llbrain
        CURRENT PAGE URL: https://llbrain.dev/install
        PAGE MARKDOWN EXCERPT:
        Install the package into your project.

        PAGE LINKS:
        - [Documentation](https://llbrain.dev/docs)
        - [GitHub](https://github.com/example/llbrain)
        """

        let evidence = BrowserPageReadEvidence.parse(
            promptBlock: block, browserName: "Safari", source: "Safari Extension")

        #expect(evidence?.title == "Install Llbrain")
        #expect(evidence?.url == "https://llbrain.dev/install")
        #expect(evidence?.textCharacterCount == 38)
        #expect(evidence?.linkCount == 2)
        #expect(evidence?.traceLines.last?.contains("2 links") == true)
        #expect(evidence?.receipt.command == "read_browser_page(Safari)")
        #expect(evidence?.receipt.success == true)
    }

    @Test func emptySnapshotDoesNotInventEvidence() {
        #expect(BrowserPageReadEvidence.parse(
            promptBlock: "", browserName: "Safari", source: "extension") == nil)
    }

    @Test func queryAwareCompactionCanKeepRelevantTextBeyondTheOldPrefix() {
        let filler = String(repeating: "introductory filler text. ", count: 260)
        let context = SafariPageContext(
            url: "https://example.com/install", title: "Install", selectedText: "",
            pageText: filler + "\n\n## Installation\nRun the unique-zebra installer.",
            description: "", scrollPercent: 0, activeFieldText: "", links: [],
            trigger: "load", timestamp: .now, receivedAt: .now)

        let compacted = context.compactedPageText(for: "unique-zebra installer", limit: 1_000)

        #expect(compacted.contains("unique-zebra installer"))
        #expect(compacted.count <= 1_100)
    }
}
