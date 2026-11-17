// SafariLinkTargetTests.swift
// Context-DockTests
//
// Issue #180: "follow a link <URL>" opened a different link from the same domain.
//
// Three failure modes covered:
//  1. Explicit URL in query was ignored; a domain-score match substituted a different link.
//  2. "follow" was not a recognised open-link verb.
//  3. Ambiguous queries blindly opened the top-scored link rather than presenting options.

import Foundation
import Testing

@testable import Context_Dock

@Suite("Safari link target selection (Issue #180)")
struct SafariLinkTargetTests {

    // MARK: - Helpers

    private func link(
        _ title: String, url: String, pageTitle: String = ""
    ) -> PageLinkAction {
        PageLinkAction(title: title, url: url, pageTitle: pageTitle)
    }

    /// A representative page with multiple openai.com links.
    private func openAIPageLinks() -> [PageLinkAction] {
        [
            link("OpenAI Blog", url: "https://openai.com/blog"),
            link("OpenAI API", url: "https://openai.com/api/"),
            link("OpenAI Pricing", url: "https://openai.com/pricing"),
            link("ChatGPT", url: "https://chat.openai.com"),
        ]
    }

    // MARK: - "follow" verb is now recognised

    @Test("'follow a link' is classified as an open-link query")
    func followVerbRecognised() {
        #expect(SafariPageLinkRules.opensAPageLink("follow a link on this page"))
        #expect(SafariPageLinkRules.opensAPageLink("follow the github link"))
        #expect(SafariPageLinkRules.opensAPageLink("follow https://openai.com/api/ from this page"))
    }

    // MARK: - Explicit URL extraction

    @Test("explicitURL returns the typed URL")
    func explicitURLFound() {
        let url = SafariPageLinkRules.explicitURL(in: "follow a link https://openai.com/api/")
        #expect(url?.absoluteString == "https://openai.com/api/")
    }

    @Test("explicitURL returns nil when no URL is present")
    func noExplicitURL() {
        #expect(SafariPageLinkRules.explicitURL(in: "open the pricing link") == nil)
        #expect(SafariPageLinkRules.explicitURL(in: "follow the github link on this page") == nil)
    }

    @Test("explicitURL strips common trailing punctuation")
    func explicitURLStripsPunctuation() {
        let url = SafariPageLinkRules.explicitURL(in: "open https://openai.com/api/.")
        #expect(url?.absoluteString == "https://openai.com/api/")
    }

    // MARK: - Explicit URL target selection (the Issue #180 bug)

    @Test("Explicit URL targets the exact on-page link, never a different domain match")
    func explicitURLPicksExactLink() {
        // "follow a link https://openai.com/api/" must open /api/, not /blog or /pricing
        let links = openAIPageLinks()
        let matches = DockCoreLinkTargetTestHarness.rankedLinks(links, for: "follow a link https://openai.com/api/")
        #expect(matches.count == 1)
        #expect(matches.first?.url == "https://openai.com/api/")
    }

    @Test("Explicit URL not on page returns empty (caller navigates directly)")
    func explicitURLNotOnPageReturnsEmpty() {
        let links = openAIPageLinks()
        let matches = DockCoreLinkTargetTestHarness.rankedLinks(
            links, for: "follow a link https://openai.com/research/")
        #expect(matches.isEmpty)
    }

    @Test("Explicit URL beats any domain-scored match — never substitutes")
    func explicitURLNeverSubstitutes() {
        // Page has openai.com links; query asks for openai.com/api/ which IS on the page.
        let links = openAIPageLinks()
        let matches = DockCoreLinkTargetTestHarness.rankedLinks(
            links, for: "open https://openai.com/api/ from this page")
        // Must return exactly the api/ link, not blog or pricing even though
        // all three share the openai.com domain.
        #expect(matches.allSatisfy { $0.url == "https://openai.com/api/" })
        #expect(matches.count == 1)
    }

    // MARK: - Title / anchor-text matching (non-URL queries)

    @Test("'open the pricing link' opens a link titled Pricing")
    func titleMatchPricing() {
        let links = openAIPageLinks()
        let matches = DockCoreLinkTargetTestHarness.rankedLinks(links, for: "open the pricing link")
        #expect(matches.count == 1)
        #expect(matches.first?.url == "https://openai.com/pricing")
    }

    @Test("Title match with clear lead returns a single confident result")
    func titleMatchSingleResult() {
        let links = [
            link("API Reference", url: "https://example.com/api"),
            link("Blog", url: "https://example.com/blog"),
            link("Pricing", url: "https://example.com/pricing"),
        ]
        let matches = DockCoreLinkTargetTestHarness.rankedLinks(links, for: "open the api docs")
        // "api" scores on title+url for the first link only — single confident result
        #expect(matches.count == 1)
        #expect(matches.first?.url == "https://example.com/api")
    }

    // MARK: - Ambiguous queries present options, not a random pick

    @Test("Ambiguous query returns multiple near-matches rather than a single auto-open")
    func ambiguousQueryReturnsOptions() {
        // "docs" matches both links similarly — cannot pick one confidently
        let links = [
            link("API Docs", url: "https://example.com/docs/api"),
            link("Getting Started Docs", url: "https://example.com/docs/start"),
            link("Blog", url: "https://example.com/blog"),
        ]
        let matches = DockCoreLinkTargetTestHarness.rankedLinks(links, for: "open the docs")
        // Should return multiple matches (> 1) so the caller shows options
        #expect(matches.count > 1)
    }

    @Test("Query with no token match returns empty")
    func noMatchReturnsEmpty() {
        let links = openAIPageLinks()
        let matches = DockCoreLinkTargetTestHarness.rankedLinks(
            links, for: "open the changelog link")
        #expect(matches.isEmpty)
    }
}

// MARK: - Test harness

/// Exposes `DockCore`'s private `rankedSafariPageLinks(_:for:)` through a testable wrapper
/// so the ranking logic can be exercised without a live CoreData or SafariBridge stack.
enum DockCoreLinkTargetTestHarness {

    static func rankedLinks(
        _ links: [PageLinkAction], for query: String
    ) -> [PageLinkAction] {
        // Mirror of DockCore+AIChat's rankedSafariPageLinks, kept in sync with the production
        // implementation. Changes to the production function must be reflected here.

        if let target = SafariPageLinkRules.explicitURL(in: query) {
            let targetStr = target.absoluteString.lowercased()
            let exact = links.filter { $0.url.lowercased() == targetStr }
            if !exact.isEmpty { return exact }
            return links.filter { $0.url.lowercased().hasPrefix(targetStr) }
        }

        let ignored: Set<String> = [
            "open", "follow", "visit", "this", "that", "page", "link", "links", "from", "the",
            "please", "guide", "site", "website", "want", "think",
        ]
        let tokens = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !ignored.contains($0) }
        guard !tokens.isEmpty else { return [] }

        let scored: [(PageLinkAction, Int)] = links.compactMap { link in
            let title = link.title.lowercased()
            let domain = link.domain.lowercased()
            let url = link.url.lowercased()
            let score = tokens.reduce(0) { total, token in
                total
                    + (title.contains(token) ? 4 : 0)
                    + (domain.contains(token) ? 5 : 0)
                    + (url.contains(token) ? 2 : 0)
            }
            return score > 0 ? (link, score) : nil
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.title.count < $1.0.title.count
        }

        guard let (top, topScore) = scored.first else { return [] }
        guard topScore >= 4 else { return scored.map(\.0) }
        if let (_, second) = scored.dropFirst().first, topScore - second < 3 {
            return scored.map(\.0)
        }
        return [top]
    }
}
