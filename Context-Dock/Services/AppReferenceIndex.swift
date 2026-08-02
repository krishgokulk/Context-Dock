import AppKit
import Foundation

/// Where an app documents itself: homepage, docs, repository, changelog.
///
/// A scope could describe the tools it owns but had no idea what the app's own documentation
/// says, so anything version-specific ("what changed in 1.13?", "how do I configure X?") was
/// answered from whatever the model happened to remember. This indexes each app's real
/// references and reads them on demand, so answers come from the vendor's current page.
///
/// Discovery never guesses a URL: every reference comes from something authoritative on this
/// Mac — the adapter's own seeded links, the app bundle's Sparkle feed, or Homebrew's
/// recorded homepage — or from a repository those point at.
struct AppReference: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case homepage
        case documentation
        case repository
        case releases
        case changelog

        var label: String {
            switch self {
            case .homepage: return "Homepage"
            case .documentation: return "Documentation"
            case .repository: return "Source repository"
            case .releases: return "Releases"
            case .changelog: return "Changelog"
            }
        }
    }

    var id: String { url }
    let kind: Kind
    let title: String
    let url: String
}

actor AppReferenceIndex {
    static let shared = AppReferenceIndex()

    private struct IndexEntry: Codable {
        let references: [AppReference]
        let discoveredAt: Date
    }

    private struct PageEntry: Codable {
        let text: String
        let fetchedAt: Date
    }

    /// Where an app points is stable; how long before we look again.
    private let discoveryLifetime: TimeInterval = 7 * 24 * 60 * 60
    /// Page content changes with releases — a day is current enough and keeps the network quiet.
    private let pageLifetime: TimeInterval = 24 * 60 * 60
    private let fetchTimeout: TimeInterval = 6

    private var index: [String: IndexEntry] = [:]
    private var pages: [String: PageEntry] = [:]
    private let directory: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        directory = support.appendingPathComponent("Context-Dock/references", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        index = Self.load([String: IndexEntry].self, from: directory.appendingPathComponent("index.json")) ?? [:]
        pages = Self.load([String: PageEntry].self, from: directory.appendingPathComponent("pages.json")) ?? [:]
    }

    // MARK: - References

    func references(bundleId: String, appName: String) async -> [AppReference] {
        guard !bundleId.isEmpty else { return [] }
        if let entry = index[bundleId],
            Date().timeIntervalSince(entry.discoveredAt) < discoveryLifetime
        {
            return entry.references
        }
        let discovered = await discover(bundleId: bundleId, appName: appName)
        index[bundleId] = IndexEntry(references: discovered, discoveredAt: Date())
        persistIndex()
        return discovered
    }

    /// Readable text of a reference page, cached. `nil` when it could not be fetched.
    func pageText(for reference: AppReference, limit: Int = 6_000) async -> String? {
        if let cached = pages[reference.url],
            Date().timeIntervalSince(cached.fetchedAt) < pageLifetime
        {
            return String(cached.text.prefix(limit))
        }
        guard let text = await fetchReadableText(reference.url) else { return nil }
        pages[reference.url] = PageEntry(text: text, fetchedAt: Date())
        persistPages()
        return String(text.prefix(limit))
    }

    /// The reference a question is about, if any — matched on the question's own words so a
    /// changelog question does not pull the homepage.
    nonisolated static func bestReference(
        for query: String, in references: [AppReference]
    ) -> AppReference? {
        let q = query.lowercased()
        let wants: [(AppReference.Kind, [String])] = [
            (.changelog, ["changelog", "what changed", "release note", "new in", "version"]),
            (.releases, ["release", "latest version", "update", "download"]),
            (.documentation, ["docs", "documentation", "how do i", "how to", "configure",
                              "config", "setting", "api", "cli", "command", "guide", "reference"]),
            (.repository, ["repo", "repository", "source", "issue", "github"]),
        ]
        for (kind, keywords) in wants where keywords.contains(where: q.contains) {
            if let match = references.first(where: { $0.kind == kind }) { return match }
        }
        return nil
    }

    /// True when a question is asking about the product rather than the local machine.
    nonisolated static func looksLikeReferenceQuestion(_ query: String) -> Bool {
        let q = query.lowercased()
        let markers = [
            "how do i", "how to", "docs", "documentation", "changelog", "what changed",
            "new in", "release", "version", "configure", "config", "setting", "api",
            "supported", "feature", "shortcut for", "guide", "reference",
        ]
        return markers.contains(where: q.contains)
    }

    // MARK: - Discovery

    private func discover(bundleId: String, appName: String) async -> [AppReference] {
        var found: [AppReference] = []
        var seen = Set<String>()

        func add(_ kind: AppReference.Kind, _ title: String, _ url: String) {
            let normalized = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.hasPrefix("http"), seen.insert(normalized.lowercased()).inserted
            else { return }
            found.append(AppReference(kind: kind, title: title, url: normalized))
        }

        // 1. The adapter's own links — seeded starter actions already point at the vendor's
        //    docs, and a user-added action is the strongest signal of all.
        for action in await MainActor.run(body: {
            AppAdapterManager.shared.adapter(for: bundleId)?.actions ?? []
        }) {
            guard let url = action.urlScheme, url.hasPrefix("http") else { continue }
            add(kind(forURL: url, title: action.name), action.name, url)
        }

        // 2. The app bundle: a Sparkle feed names the vendor's own update host.
        if let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
            let info = Bundle(url: bundleURL)?.infoDictionary
        {
            if let feed = info["SUFeedURL"] as? String, let host = URL(string: feed)?.host {
                add(.changelog, "\(appName) update feed", feed)
                add(.homepage, "\(appName) site", "https://\(host)")
            }
        }

        // 3. Homebrew records the homepage — and usually the repository — for anything it
        //    packages, which covers most developer apps without a single guessed URL.
        if let brew = await homebrewMetadata(appName: appName, bundleId: bundleId) {
            if let homepage = brew.homepage { add(kind(forURL: homepage, title: appName), "\(appName) homepage", homepage) }
        }

        // 4. A repository gives its own releases page for free.
        if let repo = found.first(where: { $0.kind == .repository }),
            let url = URL(string: repo.url), url.host?.contains("github.com") == true
        {
            let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
            if parts.count >= 2 {
                add(.releases, "\(appName) releases", "https://github.com/\(parts[0])/\(parts[1])/releases")
            }
        }
        return found
    }

    private func kind(forURL url: String, title: String) -> AppReference.Kind {
        let lowered = url.lowercased()
        let name = title.lowercased()
        if lowered.contains("github.com") || lowered.contains("gitlab.com") { return .repository }
        if lowered.contains("/changelog") || name.contains("changelog") { return .changelog }
        if lowered.contains("/releases") { return .releases }
        if lowered.contains("docs.") || lowered.contains("/docs") || lowered.contains("/documentation")
            || name.contains("doc") || name.contains("reference") || name.contains("guide")
        {
            return .documentation
        }
        return .homepage
    }

    private func homebrewMetadata(appName: String, bundleId: String) async -> (homepage: String?, repo: String?)? {
        guard FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew")
            || FileManager.default.fileExists(atPath: "/usr/local/bin/brew")
        else { return nil }
        let token = appName.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        guard !token.isEmpty else { return nil }
        let command = "brew info --json=v2 --cask \(token) 2>/dev/null || brew info --json=v2 --formula \(token) 2>/dev/null"
        guard let output = await runShell(command), let data = output.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let entries = ((root["casks"] as? [[String: Any]]) ?? []) + ((root["formulae"] as? [[String: Any]]) ?? [])
        guard let first = entries.first else { return nil }
        return (homepage: first["homepage"] as? String, repo: nil)
    }

    // MARK: - Fetch

    private func fetchReadableText(_ urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = fetchTimeout
        request.setValue("Context-Dock/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode ?? 500 < 400,
            let html = String(data: data, encoding: .utf8)
        else { return nil }
        return Self.readableText(fromHTML: html)
    }

    /// Strips markup to plain text. Deliberately simple: the point is to hand a model the
    /// page's words, not to render it.
    nonisolated static func readableText(fromHTML html: String) -> String {
        var text = html
        for pattern in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<!--[\\s\\S]*?-->"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&mdash;": "—", "&ndash;": "–",
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "( ?\\n ?){2,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runShell(_ command: String) async -> String? {
        let result: (success: Bool, output: String)? = await withTaskGroup(
            of: (success: Bool, output: String)?.self
        ) { group in
            group.addTask { await TerminalCommandExecutor.shared.runPreApproved(command) }
            group.addTask {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let result, result.success else { return nil }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Disk

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    private func persistIndex() {
        write(index, to: directory.appendingPathComponent("index.json"))
    }

    private func persistPages() {
        // Only the recent pages are worth keeping on disk.
        let cutoff = Date().addingTimeInterval(-pageLifetime)
        pages = pages.filter { $0.value.fetchedAt > cutoff }
        write(pages, to: directory.appendingPathComponent("pages.json"))
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
