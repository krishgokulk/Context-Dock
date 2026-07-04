import AppKit
import CryptoKit
import Foundation

struct WebPageContextSnapshot: Codable {
    var url: String
    var title: String?
    var markdown: String
    var headings: [String]
    var links: [String]
    var images: [String]
    var source: String
    var extractedAt: Date
    var cacheKey: String
    var appName: String?
    var bundleIdentifier: String?
    var qualityScore: Double
    var wordCount: Int
    var codeBlockCount: Int

    var characterCount: Int { markdown.count }
}

final class WebContextEngine {
    static let shared = WebContextEngine()

    private let maxMarkdownCharacters = 12_000
    private let maxHeadings = 40
    private let maxLinks = 40
    private let maxImages = 20

    private init() {}

    func context(for axContext: AXContext) -> WebPageContextSnapshot? {
        guard AXWebReader.shared.isBrowser(bundleId: axContext.bundleId) else { return nil }
        guard let rawURL = axContext.currentURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty
        else { return nil }

        if let safari = SafariBrowserBridge.shared.currentContext(),
           urlsMatch(safari.url, rawURL),
           !safari.pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let snapshot = build(
                url: safari.url,
                title: safari.title.isEmpty ? axContext.windowTitle : safari.title,
                text: safari.pageText,
                selectedText: safari.selectedText,
                description: safari.description,
                source: "SafariExtension",
                appName: axContext.appName,
                bundleIdentifier: axContext.bundleId
            )
            save(snapshot)
            return snapshot
        }

        if let cached = cachedContext(for: rawURL) {
            return cached
        }

        if let page = AXWebReader.shared.cachedSnapshot(for: axContext.pid),
           urlsMatch(page.url, rawURL),
           !page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let snapshot = build(
                url: page.url,
                title: page.title.isEmpty ? axContext.windowTitle : page.title,
                text: page.text,
                selectedText: axContext.selectedText,
                description: nil,
                source: "AXWebReader",
                appName: axContext.appName,
                bundleIdentifier: axContext.bundleId
            )
            save(snapshot)
            return snapshot
        }

        return nil
    }

    func connectedRunningBrowserContexts(
        current axContext: AXContext,
        limit: Int = 4
    ) -> [WebPageContextSnapshot] {
        let currentKey = normalizedURL(axContext.currentURL ?? "")
        var seen = Set<String>()
        if let currentKey { seen.insert(currentKey) }

        let apps = NSWorkspace.shared.runningApplications
            .filter { app in
                guard !app.isTerminated, app.processIdentifier > 0,
                      let bundleId = app.bundleIdentifier,
                      AXWebReader.shared.isBrowser(bundleId: bundleId)
                else { return false }
                return app.processIdentifier != axContext.pid
            }
            .sorted { lhs, rhs in
                (lhs.activationPolicy == .regular ? 0 : 1, lhs.localizedName ?? "")
                    < (rhs.activationPolicy == .regular ? 0 : 1, rhs.localizedName ?? "")
            }

        var contexts: [WebPageContextSnapshot] = []
        for app in apps {
            guard contexts.count < limit,
                  let bundleId = app.bundleIdentifier,
                  let rawURL = AXContextReader.shared.liveCurrentURL(
                    pid: app.processIdentifier,
                    bundleId: bundleId
                  ),
                  let normalized = normalizedURL(rawURL),
                  seen.insert(normalized).inserted
            else { continue }

            if var cached = cachedContext(for: normalized) {
                cached.appName = app.localizedName ?? cached.appName
                cached.bundleIdentifier = bundleId
                contexts.append(cached)
                continue
            }

            if let page = AXWebReader.shared.cachedSnapshot(for: app.processIdentifier),
               urlsMatch(page.url, normalized),
               !page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                let snapshot = build(
                    url: page.url,
                    title: page.title,
                    text: page.text,
                    selectedText: nil,
                    description: nil,
                    source: "AXWebReader",
                    appName: app.localizedName,
                    bundleIdentifier: bundleId
                )
                save(snapshot)
                contexts.append(snapshot)
            } else {
                Task.detached(priority: .utility) {
                    AXWebReader.shared.refresh(pid: app.processIdentifier, currentURL: normalized)
                }
            }
        }
        return contexts
    }

    func cachedContext(for rawURL: String) -> WebPageContextSnapshot? {
        guard let normalized = normalizedURL(rawURL) else { return nil }
        return ContextDockStore.shared.read(
            WebPageContextSnapshot.self,
            from: cacheURL(forKey: cacheKey(for: normalized))
        )
    }

    private func build(
        url: String,
        title: String?,
        text: String,
        selectedText: String?,
        description: String?,
        source: String,
        appName: String?,
        bundleIdentifier: String?
    ) -> WebPageContextSnapshot {
        let normalized = normalizedURL(url) ?? url
        let cleanedLines = cleanLines(from: text)
        let headings = extractHeadings(from: cleanedLines, title: title)
        let markdown = markdownText(
            title: title,
            url: normalized,
            description: description,
            selectedText: selectedText,
            lines: cleanedLines
        )
        return WebPageContextSnapshot(
            url: normalized,
            title: title?.trimmingCharacters(in: .whitespacesAndNewlines),
            markdown: String(markdown.prefix(maxMarkdownCharacters)),
            headings: Array(headings.prefix(maxHeadings)),
            links: extractLinks(from: text, baseURL: normalized),
            images: extractImageDescriptions(from: text),
            source: source,
            extractedAt: Date(),
            cacheKey: cacheKey(for: normalized),
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            qualityScore: qualityScore(markdown: markdown, headings: headings, source: source),
            wordCount: markdown.split(whereSeparator: \.isWhitespace).count,
            codeBlockCount: markdown.components(separatedBy: "```").count / 2
        )
    }

    private func markdownText(
        title: String?,
        url: String,
        description: String?,
        selectedText: String?,
        lines: [String]
    ) -> String {
        var output: [String] = []
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            output.append("# \(sanitizeMarkdownHeading(title))")
        }
        output.append("Source: \(url)")
        if let description = description?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty
        {
            output.append("\n> \(description)")
        }
        if let selectedText = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selectedText.isEmpty
        {
            output.append("\n## Selected Text\n\(selectedText)")
        }

        output.append("\n## Page Content")
        var previousWasHeading = false
        for line in lines {
            if isLikelyHeading(line) {
                output.append("\n## \(sanitizeMarkdownHeading(line))")
                previousWasHeading = true
            } else {
                if previousWasHeading { output.append("") }
                output.append(line)
                previousWasHeading = false
            }
            if output.joined(separator: "\n").count >= maxMarkdownCharacters { break }
        }
        return output.joined(separator: "\n")
    }

    private func cleanLines(from text: String) -> [String] {
        let junk = [
            "cookie", "cookies", "accept all", "sign in", "log in", "subscribe",
            "advertisement", "skip to content", "privacy policy", "terms of use",
            "share this", "enable javascript", "all rights reserved",
        ]
        var seen = Set<String>()
        return text
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .components(separatedBy: .newlines)
            .map { collapseWhitespace($0) }
            .filter { line in
                guard line.count >= 3 else { return false }
                let lower = line.lowercased()
                guard !junk.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") }) else {
                    return false
                }
                guard seen.insert(lower).inserted else { return false }
                return true
            }
    }

    private func extractHeadings(from lines: [String], title: String?) -> [String] {
        var headings: [String] = []
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            headings.append(title)
        }
        headings += lines.filter(isLikelyHeading)
        var seen = Set<String>()
        return headings.filter { seen.insert($0.lowercased()).inserted }
    }

    private func extractLinks(from text: String, baseURL: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var links: [String] = []
        detector.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let url = match?.url?.absoluteString else { return }
            links.append(url)
        }
        var seen = Set<String>()
        return links.filter { seen.insert($0).inserted }.prefix(maxLinks).map(\.self)
    }

    private func extractImageDescriptions(from text: String) -> [String] {
        let lines = cleanLines(from: text)
        let imageLines = lines.filter { $0.hasPrefix("[Image:") || $0.lowercased().hasPrefix("image:") }
        return Array(imageLines.prefix(maxImages))
    }

    private func isLikelyHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...96).contains(trimmed.count) else { return false }
        guard !trimmed.hasSuffix(".") else { return false }
        let words = trimmed.split(separator: " ")
        guard words.count <= 12 else { return false }
        if trimmed.hasPrefix("#") { return true }
        let uppercase = trimmed.filter(\.isUppercase).count
        let letters = trimmed.filter(\.isLetter).count
        return letters > 0 && Double(uppercase) / Double(max(letters, 1)) > 0.35
    }

    private func collapseWhitespace(_ input: String) -> String {
        input
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sanitizeMarkdownHeading(_ input: String) -> String {
        input.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func urlsMatch(_ lhs: String, _ rhs: String) -> Bool {
        normalizedURL(lhs) == normalizedURL(rhs)
    }

    private func normalizedURL(_ raw: String) -> String? {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme != nil,
              components.host != nil
        else { return nil }
        components.fragment = nil
        components.queryItems = components.queryItems?
            .filter { item in
                let name = item.name.lowercased()
                return !name.hasPrefix("utm_") && name != "fbclid" && name != "gclid"
            }
            .sorted { $0.name < $1.name }
        return components.url?.absoluteString
    }

    private func cacheKey(for url: String) -> String {
        let digest = SHA256.hash(data: Data(url.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func cacheURL(forKey key: String) -> URL {
        ContextDockStore.globalDir
            .appendingPathComponent("web-context", isDirectory: true)
            .appendingPathComponent("\(key).json")
    }

    private func qualityScore(markdown: String, headings: [String], source: String) -> Double {
        var score = source == "SafariExtension" ? 0.72 : 0.58
        if markdown.count > 1_500 { score += 0.12 }
        if markdown.count > 6_000 { score += 0.06 }
        if headings.count >= 3 { score += 0.08 }
        if markdown.lowercased().contains("cookie") { score -= 0.08 }
        return min(max(score, 0.15), 0.98)
    }

    private func save(_ snapshot: WebPageContextSnapshot) {
        ContextDockStore.shared.write(snapshot, to: cacheURL(forKey: snapshot.cacheKey))
    }
}
