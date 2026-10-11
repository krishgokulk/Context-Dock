// Context-DockTests/SensitivePageChatTests.swift
//
// Task 9: the chat's own page reading honours SensitivePageGuard. A bank page, or a page whose
// address carries a sign-in token, contributes no title, text, selection or links to a prompt
// or to `read_page` — only its origin and the guard's reason, so the model says why instead of
// guessing. An ordinary page reads as before.

import Foundation
import Testing

@testable import Context_Dock

@MainActor
@Suite("Sensitive pages in chat")
struct SensitivePageChatTests {

    private static let secret = "Balance £12,345.67 — account 12345678"

    private static func page(_ url: String) -> BrowserPageSnapshot {
        BrowserPageSnapshot(
            url: url, title: "Your accounts — \(secret)", text: "Summary. \(secret)",
            selectedText: secret,
            links: [SafariPageLink(url: "\(url)/transfer", text: "Transfer \(secret)")])
    }

    // MARK: The reader boundary

    @Test("A bank page keeps only its origin and the reason")
    func bankPageIsWithheld() {
        let read = BrowserPageReader.guarded(Self.page("https://www.paypal.com/myaccount/summary"))
        #expect(read.withheld != nil)
        #expect(read.url == "https://www.paypal.com")
        #expect(read.title.isEmpty && read.text.isEmpty && read.selectedText.isEmpty)
        #expect(read.links.isEmpty)
        #expect(read.refusal == read.withheld)
    }

    @Test("An ordinary page passes through untouched")
    func ordinaryPageIsRead() {
        let page = Self.page("https://swift.org/documentation")
        let read = BrowserPageReader.guarded(page)
        #expect(read == page)
        #expect(read.withheld == nil)
        #expect(read.text.contains("Summary."))
    }

    @Test("A token in the query is refused, and the token is not kept")
    func tokenInQueryIsWithheld() {
        let url = "https://example.com/welcome?token=abcdef0123456789abcdef"
        let read = BrowserPageReader.guarded(Self.page(url))
        #expect(read.withheld == .tokenInURL)
        #expect(read.url == "https://example.com")
        #expect(!read.url.contains("abcdef"))
        #expect(read.text.isEmpty)
        // The actions built on the reader still refuse it for the right reason.
        #expect(PageMarkdownExport.refusal(for: read) == SensitivePageGuard.Reason.tokenInURL.message)
        #expect(AppChatPromptModel.askRefusal(page: read) != nil)
    }

    // MARK: The grounding block

    @Test("The withheld block names the reason and carries no page text")
    func withheldBlockNamesTheReason() throws {
        let read = BrowserPageReader.guarded(Self.page("https://online.chase.com/dashboard"))
        let reason = try #require(read.withheld)
        let block = ScopedGroundingBlocks.withheldPageBlock(origin: read.url, reason: reason)
        #expect(block.contains(reason.message))
        #expect(block.contains(ScopedGroundingBlocks.withheldMarker))
        #expect(!block.contains("12,345"))
        #expect(!block.contains("PAGE TEXT"))
    }

    @Test("A URL-only reader gets the same block, and none for an ordinary page")
    func withheldBlockForURL() {
        let block = ScopedGroundingBlocks.withheldPageBlock(
            forURL: "https://login.example.com/cb?code=0123456789abcdefgh")
        #expect(block?.contains(ScopedGroundingBlocks.withheldMarker) == true)
        #expect(block?.contains("0123456789abcdefgh") == false)
        #expect(ScopedGroundingBlocks.withheldPageBlock(forURL: "https://swift.org/") == nil)
    }

    // MARK: read_page

    @Test("read_page on a refused page returns the refusal, not page content")
    func readPageReturnsTheRefusal() {
        let reason = SensitivePageGuard.Reason.financialHost("www.paypal.com")
        let block = ScopedGroundingBlocks.withheldPageBlock(
            origin: "https://www.paypal.com", reason: reason)
        let result = AgentToolRegistry.readPageResult(block: block)
        #expect(result.success == false)
        #expect(result.output.contains(reason.message))
    }

    @Test("read_page on an ordinary page returns the fenced page")
    func readPageReturnsThePage() {
        let result = AgentToolRegistry.readPageResult(
            block: "CURRENT PAGE URL: https://swift.org/\nPAGE TEXT EXCERPT:\nSwift is fast.")
        #expect(result.success)
        #expect(result.output.contains("Swift is fast."))
    }

    // MARK: Other tabs

    @Test("A sensitive tab stays listed by origin, without title or query")
    func sensitiveTabIsListedByOrigin() {
        let tabs = [
            BrowserTab(
                url: "https://www.paypal.com/activity?sid=abcdefghijklmnop",
                title: Self.secret, windowIndex: 1, tabIndex: 1),
            BrowserTab(
                url: "https://swift.org/blog", title: "Swift Blog", windowIndex: 1, tabIndex: 2),
        ]
        let block = ScopedGroundingBlocks.formatTabs(tabs, activeURL: "")
        #expect(block.contains("https://www.paypal.com"))
        #expect(!block.contains("abcdefghijklmnop"))
        #expect(!block.contains("12,345"))
        #expect(block.contains("Swift Blog — https://swift.org/blog"))

        let safe = ScopedGroundingBlocks.promptSafeTab(
            title: Self.secret, url: "https://example.com/?token=abcdef0123456789")
        #expect(safe.url == "https://example.com")
        #expect(!safe.title.contains("12,345"))
    }
}
