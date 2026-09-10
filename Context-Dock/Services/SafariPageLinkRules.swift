// SafariPageLinkRules.swift
// Context-Dock
//
// Two rules about the links on the page in front of the user, kept out of the view so they
// can be argued with in tests rather than in Safari.
//
// Both existed as literals inside `LauncherView+AIChat`, and both were wrong in a way that
// only showed on a real page:
//
//  1. The direct page reader collected anchors in document order and cut the list at sixty.
//     On docs.brew.sh the only off-site link — github.com/Homebrew/brew — is the seventy-
//     sixth anchor, behind a sidebar of internal documentation links, so "does this page
//     have any social links?" was answered "it doesn't contain links matching that request"
//     about a page that does. Our own Safari extension already ranked action-shaped links
//     ahead of the cap for exactly this reason; the fallback reader did not.
//
//  2. Opening a link found on the page was recognised only after "open", "go to" or
//     "visit". "launch troubleshoot page from this page" fell through to the page-script
//     author, which correctly refuses — a page script may not navigate — so the dock said
//     it could not do a thing it can do.

import Foundation

enum SafariPageLinkRules {

    // MARK: - Which links survive the cap

    /// Links that are worth keeping when there are more than fit.
    ///
    /// Mirrors the extension's `ACTION_LINK_PATTERN`, plus the social hosts, because the
    /// two readers answer the same questions and a link that survives one route and not the
    /// other makes the same question true or false depending on which route ran.
    private static let interesting = [
        "download", "install", "release", "docs", "documentation", "guide", "repo",
        "github", "source", "pricing", "buy", "sign up", "signup", "sign in", "login",
        "log in", "start", "try", "troubleshoot", "support", "contact",
    ]

    static let socialHosts = [
        "github.", "twitter.", "x.com", "mastodon.", "patreon.", "facebook.",
        "instagram.", "linkedin.", "youtube.", "discord.", "reddit.", "threads.",
        "bluesky.", "bsky.", "tiktok.", "slack.",
    ]

    /// Whether this link is one of the few worth keeping.
    static func isNotable(text: String, url: String, pageHost: String) -> Bool {
        let host = URL(string: url)?.host?.lowercased() ?? ""
        if socialHosts.contains(where: host.contains) { return true }
        // Anything leaving this site. An internal link is one of hundreds; a link off the
        // page's own host is a deliberate destination, and it is what "does this page link
        // to X" is nearly always asking about.
        if !pageHost.isEmpty, !host.isEmpty, !host.hasSuffix(pageHost.lowercased()) {
            return true
        }
        // The keywords are matched against the label and the path, never the host: on
        // docs.brew.sh every internal link contains "docs" in its host, which made all
        // seventy-five of them notable and left the ranking with nothing to say.
        let path = url.lowercased()
            .replacingOccurrences(of: host, with: "")
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        let haystack = "\(text.lowercased()) \(path)"
        return interesting.contains(where: haystack.contains)
    }

    /// Order links so the cap drops the ones nobody asks about.
    ///
    /// Stable within each group: document order still decides among equals, so a page's own
    /// reading order survives wherever ranking has nothing to say.
    static func prioritised(
        _ links: [(text: String, url: String)], pageHost: String, limit: Int
    ) -> [(text: String, url: String)] {
        var notable: [(text: String, url: String)] = []
        var rest: [(text: String, url: String)] = []
        for link in links {
            if isNotable(text: link.text, url: link.url, pageHost: pageHost) {
                notable.append(link)
            } else {
                rest.append(link)
            }
        }
        return Array((notable + rest).prefix(limit))
    }

    /// The host of the page the links were read from, for the "leaves this site" rule.
    static func host(of pageURL: String) -> String {
        URL(string: pageURL)?.host?.replacingOccurrences(of: "www.", with: "") ?? ""
    }

    // MARK: - Opening one of them

    /// The user is asking to open a destination that lives on the current page.
    ///
    /// Two halves: something that means "open", and something that says the destination is
    /// on this page or names it. Both halves matter — "open the sidebar" is browser chrome,
    /// not a link — but the verb half was three words long, and every other way people say
    /// it landed in the page-script author instead.
    static func opensAPageLink(_ query: String) -> Bool {
        let lower = query.lowercased()
        let verbs = [
            "open", "go to", "goto", "visit", "launch", "take me to", "navigate",
            "jump to", "bring up", "load",
        ]
        guard verbs.contains(where: lower.contains) else { return false }

        // Deliberately not "show" or a bare "page": "show the page in dark mode" is a
        // change to the document, and this classifier runs ahead of the page-script author.
        let destinations = [
            "link", "this page", "from page", "from this", "on this page", "guide",
            "github", "twitter", "documentation", "docs",
        ]
        return destinations.contains(where: lower.contains)
    }
}
