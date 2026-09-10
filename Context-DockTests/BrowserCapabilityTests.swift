// BrowserCapabilityTests.swift
// Context-DockTests
//
// The browser reads already existed — history, bookmarks, tabs, current page. What no
// capability could do was search the page in front of the user, or open a link it contains:
// both were reachable only through keyword classifiers chosen before the model spoke, and
// `isSafariPageLinkOpenQuery` knew three verbs, so "launch troubleshoot page from this page"
// was refused while the app had every piece needed to do it.
//
// The read-only line these sit behind is held by `SafariAdapterEvalTests.noBrowserCapabilityWrites`:
// operating the browser goes through the menu route, where AppMenuConsentStore gates it. A
// first draft of this family added a page-script capability at `.medium` and that test caught
// it. These tests keep the new pair inside the same line.

import Foundation
import Testing

@testable import Context_Dock

@Suite("Browser capabilities")
@MainActor
struct BrowserCapabilityTests {

    private var registry: CapabilityRegistry { CapabilityRegistry.shared }

    @Test("Searching the page and opening a link are registered")
    func theMissingPairExists() {
        let ids = Set(registry.all.map(\.id))
        #expect(ids.contains("browser.findInPage"))
        #expect(ids.contains("browser.openURL"))
        // And they join the reads that were already there rather than replacing them.
        for existing in [
            "browser.history", "browser.bookmarks", "browser.tabs", "browser.currentPage",
        ] {
            #expect(ids.contains(existing), "lost \(existing)")
        }
    }

    @Test("Neither of them asks for approval")
    func theyStayInsideTheReadOnlyLine() {
        // The dock already opens a page link with no approval when its own classifier
        // fires. A capability must not be more dangerous than the button beside it — and a
        // browser capability that required approval would fail the family's contract test.
        for id in ["browser.findInPage", "browser.openURL"] {
            #expect(registry.capability(id: id)?.riskLevel == .low, "\(id)")
            #expect(
                registry.capability(id: id)?.riskLevel.requiresApproval == false, "\(id)")
        }
    }

    @Test("A browser question can reach them from any scope")
    func visibleFromEveryScope() {
        for scope in ["com.apple.Safari", "com.apple.finder", "cli://brew"] {
            let ids = Set(registry.capabilities(for: scope).map(\.id))
            #expect(ids.contains("browser.findInPage"), "not offered in \(scope)")
            #expect(ids.contains("browser.openURL"), "not offered in \(scope)")
        }
    }

    @Test("Nothing here is selection-safe")
    func selectionScopeStaysNarrow() {
        // Selection Scope acts on what the user picked. A page read is app state they did
        // not select, so none of these may run there.
        for id in ["browser.findInPage", "browser.openURL"] {
            #expect(registry.capability(id: id)?.selectionSafety.isSelectionSafe == false)
        }
    }

    @Test("Opening refuses anything that is not an http(s) URL")
    func openURLRefusesOtherSchemes() async throws {
        guard let capability = registry.capability(id: "browser.openURL") else {
            Issue.record("browser.openURL is not registered")
            return
        }
        // `file://` would reach the disk and `javascript:` would run script, both through a
        // door labelled "open a link the page already has".
        for bad in ["", "file:///etc/passwd", "javascript:alert(1)", "not a url"] {
            let result = try await capability.executor(
                AICapabilityExecutionRequest(input: ["url": bad], context: .none))
            #expect(!result.success, "should refuse \(bad)")
        }
    }

    @Test("Find-in-page matches the page's text and its links")
    func findingTextInABlock() {
        let block = """
            CURRENT PAGE TITLE: Homebrew Documentation
            CURRENT PAGE URL: https://docs.brew.sh/
            PAGE TEXT EXCERPT:
            Homebrew installs the stuff you need.
            Troubleshooting covers common failures.

            PAGE LINKS (action links first, as they appear on the page):
            - github → https://github.com/Homebrew/brew
            """

        let hits = BrowserCapabilities.matchingLines(in: block, for: "troubleshoot")
        #expect(hits.count == 1)
        #expect(hits.first?.contains("Troubleshooting") == true)

        // The links are part of the page, so "does this page link to GitHub" is answerable.
        #expect(!BrowserCapabilities.matchingLines(in: block, for: "github").isEmpty)
        #expect(BrowserCapabilities.matchingLines(in: block, for: "kubernetes").isEmpty)
        #expect(BrowserCapabilities.matchingLines(in: block, for: "").isEmpty)
    }

    @Test("Tabs can be asked about, not just listed")
    func tabsTakeAFilter() {
        let fields = registry.capability(id: "browser.tabs")?.inputSchema.fields ?? []
        // "Which tab has the invoice open" was answered by returning sixty rows and hoping
        // the model matched them — after the list had already been truncated.
        #expect(fields.contains { $0.name == "matching" })
    }

    @Test("The current page is read with its links, around what was asked")
    func currentPageTakesAnAboutHint() {
        let fields = registry.capability(id: "browser.currentPage")?.inputSchema.fields ?? []
        #expect(fields.contains { $0.name == "about" })
    }
}
