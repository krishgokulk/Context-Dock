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

    /// The tab list is grounding the user never sees unless the receipt says it was read.
    /// Counted from the header, so a list capped at forty still reports every tab seen.
    @Test func openTabsAreCountedAndReceipted() {
        let block = """
        CURRENT PAGE TITLE: Install Llbrain
        CURRENT PAGE URL: https://llbrain.dev/install

        OPEN TABS (3 open in this browser):
        - Install Llbrain — https://llbrain.dev/install (active — the page above)
        - Invoice 4021 — https://billing.example.com/4021
        - GitHub — https://github.com/example/llbrain
        PAGE TEXT EXCERPT:
        Install the package into your project.
        """

        let evidence = BrowserPageReadEvidence.parse(
            promptBlock: block, browserName: "Safari", source: "Safari Extension")

        #expect(evidence?.tabCount == 3)
        // A tab row is not a page link. Counting one as the other reports evidence about the
        // page that the page does not contain.
        #expect(evidence?.linkCount == 0)
        #expect(evidence?.traceLines.last?.contains("3 open tabs") == true)
        #expect(evidence?.receipt.output.contains("Open tabs: 3") == true)
    }

    /// A browser read that reached the tab list found something, even when the page itself
    /// was unreadable — that is the case "which tab has the invoice" is asked in.
    @Test func tabsAloneAreStillASuccessfulRead() {
        let block = """
        CURRENT PAGE TITLE: (unknown)
        CURRENT PAGE URL: (unknown)

        OPEN TABS (2 open in this browser):
        - Invoice 4021 — https://billing.example.com/4021
        - GitHub — https://github.com/example/llbrain
        PAGE TEXT: (unavailable — could not read the page)
        """

        let evidence = BrowserPageReadEvidence.parse(
            promptBlock: block, browserName: "Safari", source: "live browser reader")

        #expect(evidence?.tabCount == 2)
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

// MARK: - The tab list the grounding block carries
//
// `dorax_browser_tabs` was exposed over MCP to other agents while DoraX's own turn got the
// front page and nothing else, so "which tab has the invoice" was unanswerable by every
// provider and especially by one with no tools to go looking. These pin the shape of the
// block, which is the only thing a tool-less provider gets.

@MainActor
struct BrowserTabGroundingTests {

    private func tabs() -> [BrowserTab] {
        [
            BrowserTab(
                url: "https://llbrain.dev/install", title: "Install Llbrain",
                windowIndex: 1, tabIndex: 1),
            BrowserTab(
                url: "https://billing.example.com/4021", title: "Invoice 4021",
                windowIndex: 1, tabIndex: 2),
        ]
    }

    @Test func theActiveTabIsTheOneThePageBlockDescribes() {
        let section = ScopedGroundingBlocks.formatTabs(
            tabs(), activeURL: "https://llbrain.dev/install")

        #expect(section.contains("OPEN TABS (2 open in this browser):"))
        #expect(section.contains("- Install Llbrain — https://llbrain.dev/install (active"))
        #expect(section.contains("- Invoice 4021 — https://billing.example.com/4021\n"))
        // The other tab's URL is present verbatim, which is what makes the question
        // answerable without a tool to go and fetch it.
        #expect(section.contains("https://billing.example.com/4021"))
    }

    /// A tab row must not read as a page link to the evidence parser, or the receipt reports
    /// links the page does not have.
    @Test func tabRowsAreNotCountedAsPageLinks() {
        let section = ScopedGroundingBlocks.formatTabs(tabs(), activeURL: "")
        let evidence = BrowserPageReadEvidence.parse(
            promptBlock: "CURRENT PAGE URL: https://llbrain.dev/install" + section,
            browserName: "Safari", source: "live browser reader")

        #expect(evidence?.linkCount == 0)
        #expect(evidence?.tabCount == 2)
    }

    /// Sixty tabs is an ordinary Tuesday. The cap keeps the block bounded and says what it
    /// left out, so the model does not report the cap as the total.
    @Test func theListIsCappedAndSaysWhatItLeftOut() {
        let many = (1...45).map {
            BrowserTab(
                url: "https://example.com/\($0)", title: "Tab \($0)",
                windowIndex: 1, tabIndex: $0)
        }
        let section = ScopedGroundingBlocks.formatTabs(many, activeURL: "")

        #expect(section.contains("OPEN TABS (45 open in this browser):"))
        #expect(section.contains("…and 5 more open tabs, not listed."))
        #expect(!section.contains("Tab 41 —"))
    }

    @Test func noTabsMeansNoSection() {
        #expect(ScopedGroundingBlocks.formatTabs([], activeURL: "").isEmpty)
    }
}
