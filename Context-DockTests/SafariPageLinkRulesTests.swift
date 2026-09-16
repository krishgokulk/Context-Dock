// SafariPageLinkRulesTests.swift
// Context-DockTests
//
// Two answers about the page in front of the user that were wrong on a real page.

import Foundation
import Testing

@testable import Context_Dock

@Suite("Safari page link rules")
struct SafariPageLinkRulesTests {

    /// docs.brew.sh, as the reader saw it: a sidebar of internal documentation links with
    /// the page's single off-site link — github.com/Homebrew/brew — as the last anchor.
    private func brewDocsLinks() -> [(text: String, url: String)] {
        var links = (1...75).map { index in
            (text: "Doc \(index)", url: "https://docs.brew.sh/Doc-\(index)")
        }
        links.append((text: "github", url: "https://github.com/Homebrew/brew"))
        return links
    }

    @Test("The one social link on the page survives the cap")
    func theOffSiteLinkSurvives() {
        let ranked = SafariPageLinkRules.prioritised(
            brewDocsLinks(), pageHost: "docs.brew.sh", limit: 60)

        #expect(ranked.count == 60)
        // Sixtieth in document order, it was dropped, and "does this page have social
        // links?" was answered "no" about a page that has one.
        #expect(ranked.contains { $0.url == "https://github.com/Homebrew/brew" })
    }

    @Test("Ranking keeps document order among equals")
    func equalsKeepTheirOrder() {
        let ranked = SafariPageLinkRules.prioritised(
            brewDocsLinks(), pageHost: "docs.brew.sh", limit: 60)
        let internalLinks = ranked.filter { $0.url.contains("docs.brew.sh") }

        #expect(internalLinks.first?.url == "https://docs.brew.sh/Doc-1")
        #expect(internalLinks.count == 59)
    }

    @Test("A link off this site is notable; one of a hundred internal links is not")
    func leavingTheSiteIsWhatMakesALinkNotable() {
        #expect(
            SafariPageLinkRules.isNotable(
                text: "github", url: "https://github.com/Homebrew/brew",
                pageHost: "docs.brew.sh"))
        #expect(
            !SafariPageLinkRules.isNotable(
                text: "Bottles", url: "https://docs.brew.sh/Bottles",
                pageHost: "docs.brew.sh"))
        // Named on the page's own host, and still worth keeping.
        #expect(
            SafariPageLinkRules.isNotable(
                text: "Troubleshooting", url: "https://docs.brew.sh/Troubleshooting",
                pageHost: "docs.brew.sh"))
    }

    @Test("Opening a link on the page is more than three verbs")
    func openingIsRecognisedHoweverItIsSaid() {
        // The one that failed: it reached the page-script author, which refuses to
        // navigate, so the dock said it could not do a thing it can do.
        #expect(SafariPageLinkRules.opensAPageLink("launch troubleshoot page from this page."))
        #expect(SafariPageLinkRules.opensAPageLink("open the github link"))
        #expect(SafariPageLinkRules.opensAPageLink("take me to the docs from this page"))
        #expect(SafariPageLinkRules.opensAPageLink("go to the guide"))
    }

    @Test("Changing the page is not opening a link")
    func pageActionsAreLeftAlone() {
        // These belong to the page-script author; classifying them here would take the
        // author's work away and answer with a link instead.
        #expect(!SafariPageLinkRules.opensAPageLink("dark mode for this page"))
        #expect(!SafariPageLinkRules.opensAPageLink("hide the sidebar on this page"))
        #expect(!SafariPageLinkRules.opensAPageLink("show all comments on this page"))
        #expect(!SafariPageLinkRules.opensAPageLink("open a new tab"))
    }
}
