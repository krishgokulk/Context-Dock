// AppDocumentationCrawl.swift
// Context-Dock
//
// A homepage is a poster. The answer is usually one link further in.
//
// Asked what an app does, DoraX answered by reciting its menu bar — About, Check for
// Updates…, Hide Others — which describes a Mac app in general and this app not at all. The
// fix was supposed to be reading the vendor's own page, and a homepage on its own is rarely
// enough: it says "the best way to watch tutorials" and keeps the features, the shortcuts and
// the FAQ one click away, on /features, /docs, /help.
//
// So the pages a homepage points at are read too — once, bounded, and only the ones that look
// like documentation. The bound is the point. A marketing site with a blog is hundreds of
// pages, most of them irrelevant, and a model handed all of it answers a question about
// caches from a launch announcement.

import Foundation

struct AppDocumentationCrawl {

    /// Pages fetched per app, including the page crawled from. Small on purpose: the value is
    /// in the two or three pages that describe the product, and everything after them is
    /// mostly navigation furniture repeated.
    static let maximumPages = 6

    /// Path fragments that mark a page as being about the product rather than about the
    /// company, the pricing or the legal position.
    private static let documentationHints = [
        "/doc", "/docs", "/help", "/guide", "/manual", "/support", "/faq", "/features",
        "/getting-started", "/how-to", "/tutorial", "/usage", "/reference", "/wiki",
        "/readme", "/changelog", "/release",
    ]

    /// Paths that are never the answer, however prominent the link.
    private static let ignoredHints = [
        "/privacy", "/terms", "/legal", "/eula", "/pricing", "/buy", "/purchase", "/cart",
        "/login", "/signin", "/signup", "/account", "/careers", "/jobs", "/press",
        "/contact", "/cookie", "/sitemap", "/rss", "/feed", "/tag/", "/category/",
        "/author/", "/twitter", "/facebook", "/mastodon", "/discord",
    ]

    /// Links worth following from a page, best first.
    ///
    /// Same host only. A homepage links to its App Store listing, its Twitter, its payment
    /// processor and its analytics provider, and none of those documents the software — while
    /// following them would turn "read this app's docs" into crawling the open web on the
    /// user's connection.
    static func documentationLinks(in markdown: String, from pageURL: String) -> [String] {
        guard let base = URL(string: pageURL), let host = base.host?.lowercased() else {
            return []
        }
        // MarkItDown emits ordinary Markdown links, so the hrefs survive conversion — which
        // is why the crawl reads the converted text rather than raw HTML.
        let pattern = #"\]\(\s*([^)\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var scored: [(score: Int, url: String)] = []
        var seen = Set<String>()
        for match in regex.matches(
            in: markdown, range: NSRange(markdown.startIndex..., in: markdown))
        {
            guard let range = Range(match.range(at: 1), in: markdown) else { continue }
            let raw = String(markdown[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard let resolved = URL(string: raw, relativeTo: base)?.absoluteURL,
                let scheme = resolved.scheme?.lowercased(), scheme == "https" || scheme == "http",
                resolved.host?.lowercased() == host
            else { continue }

            // The fragment is the same page; two links to #features and #pricing are one
            // document, and fetching it twice spends the budget on nothing.
            var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            guard let clean = components?.url?.absoluteString,
                clean.caseInsensitiveCompare(pageURL) != .orderedSame,
                seen.insert(clean.lowercased()).inserted
            else { continue }

            let path = (components?.path ?? "").lowercased()
            guard !ignoredHints.contains(where: path.contains) else { continue }
            guard let hint = documentationHints.first(where: path.contains) else { continue }
            // Shallower paths first: /docs before /docs/v2/api/internals, because the top of
            // a manual describes the product and the leaves describe its corners.
            let depth = path.split(separator: "/").count
            scored.append((score: 100 - depth * 5 - (documentationHints.firstIndex(of: hint) ?? 0), url: clean))
        }
        return scored.sorted { $0.score > $1.score }.map(\.url)
    }
}
