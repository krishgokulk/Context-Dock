//
//  AppWebsiteKnowledge.swift
//  Context-Dock
//
//  What the vendor says about their own product, read once per app version.
//
//  Step 3 of docs/architecture/APP_KNOWLEDGE_SKILLS.md, and the only step that leaves the
//  machine. Everything here is built to be refusable:
//
//  • Off unless the user turns it on (`appWebsiteKnowledgeEnabled`, default false).
//  • The address is never guessed. Deriving "microsoft.com" from com.microsoft.VSCode
//    would send a request somewhere the user never named, on the strength of a bundle id.
//    It comes from the adapter the user configured, or there is no fetch.
//  • HTTPS only, and never back into this machine — file:// reads the disk and localhost
//    is whatever happens to be listening.
//  • Once per app version, cached on disk. Not per launch, and not per question.
//  • Capped, because a page shares the prompt with everything else the app knows.
//

import Foundation

enum AppWebsiteKnowledge {

    /// A page is context, not a document store.
    static let maximumCharacters = 4_000

    /// Refuse anything that is not a public https page. Loopback and link-local addresses
    /// are this machine wearing a URL.
    static func fetchableURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            let url = URL(string: trimmed),
            url.scheme?.lowercased() == "https",
            let host = url.host?.lowercased(),
            !host.isEmpty
        else { return nil }

        let blocked: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"]
        guard !blocked.contains(host),
            !host.hasSuffix(".local"),
            !host.hasPrefix("192.168."),
            !host.hasPrefix("10."),
            !host.hasPrefix("169.254.")
        else { return nil }
        return url
    }

    /// One entry per app version, so the page is fetched once and then not again until the
    /// app updates. The key becomes a filename, so it may not carry a path.
    static func cacheKey(bundleId: String, version: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        func safe(_ value: String) -> String {
            String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
                .replacingOccurrences(of: "..", with: "-")
        }
        return "\(safe(bundleId))@\(safe(version))"
    }

    /// Markup to prose. Script and style bodies are the bulk of a modern page and none of
    /// it is what the vendor is saying about the product.
    static func readableText(fromHTML html: String) -> String {
        var text = html
        for tag in ["script", "style", "noscript", "svg", "head"] {
            text = text.replacingOccurrences(
                of: "<\(tag)[^>]*>.*?</\(tag)>",
                with: " ",
                options: [.regularExpression, .caseInsensitive])
        }
        // Block-level tags become breaks so sentences do not run together.
        text = text.replacingOccurrences(
            of: "</(p|div|li|h[1-6]|tr|section|article)>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(
            of: "<[^>]+>", with: " ", options: .regularExpression)

        let entities = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…",
        ]
        for (entity, character) in entities {
            text = text.replacingOccurrences(of: entity, with: character, options: .caseInsensitive)
        }

        text = text.replacingOccurrences(
            of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "\n{2,}", with: "\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return text.count > maximumCharacters
            ? String(text.prefix(maximumCharacters))
            : text
    }

    // MARK: - Fetch

    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Context-Dock/app-website-knowledge", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func cached(bundleId: String, version: String) -> String? {
        let url = cacheDirectory.appendingPathComponent(cacheKey(bundleId: bundleId, version: version))
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Fetch the product page, or return what was already fetched for this version.
    /// Returns nil when the feature is off, the address is unusable, or the fetch fails —
    /// a missing page is never an error worth interrupting the user for.
    static func knowledge(
        bundleId: String, version: String, website: String?
    ) async -> String? {
        if let cached = cached(bundleId: bundleId, version: version) { return cached }
        guard let website, let url = fetchableURL(from: website) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Context-Dock", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            let html = String(data: data, encoding: .utf8)
        else { return nil }

        let text = readableText(fromHTML: html)
        guard !text.isEmpty else { return nil }
        try? text.write(
            to: cacheDirectory.appendingPathComponent(cacheKey(bundleId: bundleId, version: version)),
            atomically: true, encoding: .utf8)
        return text
    }
}
