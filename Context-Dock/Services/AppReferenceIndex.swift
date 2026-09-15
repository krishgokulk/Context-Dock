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
        var etag: String?
        var lastModified: String?
        var converter: String?
    }

    struct PageSnapshot: Sendable {
        let text: String
        let syncedAt: Date
        let converter: String
        let sourceURL: String
    }

    /// Where an app points is stable; how long before we look again.
    private let discoveryLifetime: TimeInterval = 7 * 24 * 60 * 60

    /// How long a *failed* discovery is trusted.
    ///
    /// Finding nothing is not an answer, and caching it like one is how an app stays
    /// undocumented for a week. Tutorini was looked up before the App Store and bundle-scan
    /// sources existed, found nothing, and that emptiness was cached with the same seven-day
    /// lifetime as a real result — so when the new sources shipped they were never asked, and
    /// the app whose Info.plist plainly names its own site kept answering "no readable
    /// description available". Long enough not to re-scan a binary on every message; short
    /// enough that adding a source, or an app gaining a homepage, is picked up the same day.
    private let emptyDiscoveryLifetime: TimeInterval = 15 * 60
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

    /// Drops what was discovered for an app so the next question rediscovers it.
    ///
    /// Discovery is cached for a week, which is right for something that changes rarely and
    /// wrong the moment the user hands us a link: without this, pasting a documentation URL
    /// would have no visible effect for seven days, and the natural conclusion is that the
    /// field does not work.
    func forget(bundleId: String) {
        index.removeValue(forKey: bundleId)
        persistIndex()
    }

    func references(bundleId: String, appName: String) async -> [AppReference] {
        guard !bundleId.isEmpty else { return [] }
        if let entry = index[bundleId],
            Date().timeIntervalSince(entry.discoveredAt)
                < (entry.references.isEmpty ? emptyDiscoveryLifetime : discoveryLifetime)
        {
            let curated = Self.curatedOfficialReferences[bundleId] ?? []
            let merged = entry.references + curated.filter { official in
                !entry.references.contains(where: { $0.url == official.url })
            }
            if merged != entry.references {
                index[bundleId] = IndexEntry(references: merged, discoveredAt: entry.discoveredAt)
                persistIndex()
                persistMarkdownIndex(bundleId: bundleId)
            }
            return merged
        }
        let discovered = await discover(bundleId: bundleId, appName: appName)
        index[bundleId] = IndexEntry(references: discovered, discoveredAt: Date())
        // A failure is remembered in memory to avoid re-scanning on every message of the same
        // conversation, and deliberately not written to disk: a relaunch should try again
        // rather than inherit a week-old verdict that the app cannot be documented.
        if !discovered.isEmpty { persistIndex() }
        return discovered
    }

    /// Readable text of a reference page, cached. `nil` when it could not be fetched.
    func pageText(for reference: AppReference, limit: Int = 6_000) async -> String? {
        await pageSnapshot(for: reference, bundleId: "shared", limit: limit)?.text
    }

    /// Query-compacted Markdown plus freshness/provenance. The full Markdown remains on disk;
    /// only the relevant bounded excerpt enters an AI prompt.
    func pageSnapshot(
        for reference: AppReference,
        bundleId: String,
        query: String? = nil,
        limit: Int = 6_000,
        forceRefresh: Bool = false
    ) async -> PageSnapshot? {
        if let cached = pages[reference.url],
            !forceRefresh,
            Date().timeIntervalSince(cached.fetchedAt) < pageLifetime
        {
            return PageSnapshot(
                text: MarkItDownService.compact(cached.text, for: query, limit: limit),
                syncedAt: cached.fetchedAt,
                converter: cached.converter ?? "HTML fallback",
                sourceURL: reference.url)
        }
        let previous = pages[reference.url]
        guard let fetched = await fetchReadableContent(reference.url, previous: previous) else {
            guard let previous else { return nil }
            return PageSnapshot(
                text: MarkItDownService.compact(previous.text, for: query, limit: limit),
                syncedAt: previous.fetchedAt,
                converter: previous.converter ?? "HTML fallback",
                sourceURL: reference.url)
        }
        let syncedAt = Date()
        let entry = PageEntry(
            text: fetched.text,
            fetchedAt: syncedAt,
            etag: fetched.etag ?? previous?.etag,
            lastModified: fetched.lastModified ?? previous?.lastModified,
            converter: fetched.converter)
        pages[reference.url] = entry
        persistPages()
        persistMarkdown(entry, reference: reference, bundleId: bundleId)
        persistMarkdownIndex(bundleId: bundleId)
        return PageSnapshot(
            text: MarkItDownService.compact(entry.text, for: query, limit: limit),
            syncedAt: syncedAt,
            converter: fetched.converter,
            sourceURL: reference.url)
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

    /// True when the question is about the software itself — what it is, what it can do,
    /// whether it can do a particular thing.
    ///
    /// Separate from `looksLikeReferenceQuestion`, which asks whether a specific page is
    /// worth fetching ("what changed in 1.13", "how do I configure X"). This is the broader
    /// "what is this thing", and it is the question DoraX kept answering with a menu list:
    /// About, Check for Updates…, Hide Others — true of every Mac app, informative about
    /// none.
    nonisolated static func describesTheProduct(_ query: String) -> Bool {
        let q = query.lowercased()
        if looksLikeReferenceQuestion(q) { return true }
        let markers = [
            "what does", "what do", "what can", "what is", "what's", "whats",
            "tell me about", "explain", "capable", "used for", "good at", "purpose of",
            "overview", "how does it work", "help me with", "can it ", "does it ",
        ]
        return markers.contains(where: q.contains)
    }

    // MARK: - Discovery

    /// The app's documentation, read one link deeper than its homepage.
    ///
    /// A homepage is a poster: it says what the app is for and keeps the features, the
    /// shortcuts and the FAQ on the pages it links to. Reading only the homepage is why "what
    /// can this app do" still came back thin — and why, with nothing better in front of it,
    /// the model fell back to reciting the app's menu bar.
    ///
    /// Bounded hard. Same host, one level, a handful of pages, cached like any other page and
    /// labelled with when it was read.
    func documentationDigest(
        bundleId: String, appName: String, query: String, budget: Int = 6_000
    ) async -> PageSnapshot? {
        let references = await references(bundleId: bundleId, appName: appName)
        // The best entry point: real documentation if the app publishes any, else its
        // homepage, else its repository readme.
        let entry = references.first { $0.kind == .documentation }
            ?? references.first { $0.kind == .homepage }
            ?? references.first { $0.kind == .repository }
        guard let entry else { return nil }
        guard let root = await pageSnapshot(
            for: entry, bundleId: bundleId, query: query, limit: budget)
        else { return nil }

        var sections = ["## \(appName) — \(entry.title)\n\(root.text)"]
        var used = root.text.count
        var oldest = root.syncedAt

        let links = AppDocumentationCrawl.documentationLinks(
            in: root.text, from: entry.url)
        for link in links.prefix(AppDocumentationCrawl.maximumPages - 1) {
            guard used < budget * 2 else { break }
            let child = AppReference(
                kind: .documentation, title: URL(string: link)?.lastPathComponent ?? link,
                url: link)
            guard let snapshot = await pageSnapshot(
                for: child, bundleId: bundleId, query: query, limit: budget / 2)
            else { continue }
            // A page that came back as navigation and nothing else is not worth its share of
            // the budget, and reads to the model as though the product has no documentation.
            guard snapshot.text.count > 400 else { continue }
            sections.append("### \(child.title) (\(link))\n\(snapshot.text)")
            used += snapshot.text.count
            oldest = min(oldest, snapshot.syncedAt)
        }

        return PageSnapshot(
            text: sections.joined(separator: "\n\n"),
            syncedAt: oldest,
            converter: root.converter,
            sourceURL: entry.url)
    }

    private func discover(bundleId: String, appName: String) async -> [AppReference] {
        var found: [AppReference] = []
        var seen = Set<String>()

        func add(_ kind: AppReference.Kind, _ title: String, _ url: String) {
            let normalized = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.hasPrefix("http"), seen.insert(normalized.lowercased()).inserted
            else { return }
            found.append(AppReference(kind: kind, title: title, url: normalized))
        }

        // Built-in Apple apps do not carry Sparkle/Homebrew metadata. These are stable,
        // vendor-owned guide entry points verified against Apple Support.
        for reference in Self.curatedOfficialReferences[bundleId] ?? [] {
            add(reference.kind, reference.title, reference.url)
        }

        // 0. What the user told us. Highest authority there is: they read the app's Help
        //    menu, opened the page, and pasted where it went. Nothing DoraX can work out
        //    beats being told.
        for url in AppReferenceOverrides.urls(forBundleId: bundleId) {
            add(kind(forURL: url, title: appName), "\(appName) (added by you)", url)
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

        // 4. The App Store's listing for this bundle id names the developer's own site.
        //    This is the source that covers the apps the others miss: a sideloaded or
        //    Mac App Store app with no Sparkle feed and no Homebrew cask — which is exactly
        //    the case where the Help menu shows a homepage DoraX could see but not read.
        if found.isEmpty || !found.contains(where: { $0.kind == .homepage }) {
            for url in await AppBundleLinks.fromAppStore(bundleId: bundleId) {
                add(kind(forURL: url, title: appName), "\(appName) on the App Store", url)
            }
        }

        // 5. URL literals shipped inside the app itself, kept only when they name the app.
        //    Its Help menu knows the homepage; the string it opens is compiled into the
        //    binary, so that is where it is read from rather than guessed at.
        if !found.contains(where: { $0.kind == .homepage || $0.kind == .documentation }) {
            let links = await Task.detached(priority: .utility) {
                AppBundleLinks.fromBundle(bundleId: bundleId, appName: appName)
            }.value
            for url in links {
                add(kind(forURL: url, title: appName), "\(appName) link", url)
            }
        }

        // 6. A repository gives its own releases page for free.
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

    private struct FetchedContent {
        let text: String
        let etag: String?
        let lastModified: String?
        let converter: String
    }

    private func fetchReadableContent(
        _ urlString: String, previous: PageEntry?
    ) async -> FetchedContent? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = fetchTimeout
        request.setValue("Context-Dock/1.0", forHTTPHeaderField: "User-Agent")
        if let etag = previous?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let modified = previous?.lastModified {
            request.setValue(modified, forHTTPHeaderField: "If-Modified-Since")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse
        else { return nil }
        if http.statusCode == 304, let previous {
            return FetchedContent(
                text: previous.text, etag: previous.etag,
                lastModified: previous.lastModified,
                converter: previous.converter ?? "HTML fallback")
        }
        guard http.statusCode < 400,
            let html = String(data: data, encoding: .utf8)
        else { return nil }

        var text: String?
        var converter = "HTML fallback"
        if MarkItDownService.isAvailable {
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("context-dock-reference-\(UUID().uuidString).html")
            if (try? data.write(to: temporary, options: .atomic)) != nil {
                text = MarkItDownService.convert(temporary, characterBudget: 120_000)?.markdown
                try? FileManager.default.removeItem(at: temporary)
                if text != nil { converter = "MarkItDown" }
            }
        }
        let resolved = text ?? Self.readableText(fromHTML: html)
        guard !resolved.isEmpty else { return nil }
        return FetchedContent(
            text: resolved,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            converter: converter)
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
            group.addTask {
                let run = await TerminalCommandExecutor.shared.runPreApproved(command)
                return (run.success, run.output)
            }
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
        // Empty entries never reach disk. They exist only to stop one conversation
        // re-scanning the same app every message; a relaunch should ask again.
        write(index.filter { !$0.value.references.isEmpty },
              to: directory.appendingPathComponent("index.json"))
    }

    private func persistPages() {
        // Only the recent pages are worth keeping on disk.
        let cutoff = Date().addingTimeInterval(-pageLifetime)
        pages = pages.filter { $0.value.fetchedAt > cutoff }
        write(pages, to: directory.appendingPathComponent("pages.json"))
    }

    private func persistMarkdown(
        _ entry: PageEntry, reference: AppReference, bundleId: String
    ) {
        let appDirectory = markdownDirectory(bundleId: bundleId)
        try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        let fileName = markdownFileName(reference)
        let formatter = ISO8601DateFormatter()
        let header = """
            ---
            source_url: \(reference.url)
            source_title: \(reference.title)
            source_kind: \(reference.kind.rawValue)
            last_sync: \(formatter.string(from: entry.fetchedAt))
            freshness_hours: 24
            converter: \(entry.converter ?? "HTML fallback")
            etag: \(entry.etag ?? "")
            last_modified: \(entry.lastModified ?? "")
            ---

            """
        try? (header + entry.text).write(
            to: appDirectory.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
    }

    private func persistMarkdownIndex(bundleId: String) {
        guard let references = index[bundleId]?.references else { return }
        let appDirectory = markdownDirectory(bundleId: bundleId)
        try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        let rows = references.map { reference in
            "- [\(reference.title)](\(markdownFileName(reference))) — \(reference.kind.label) — \(reference.url)"
        }
        let markdown = (["# Official reference index", "", "App: `\(bundleId)`", ""] + rows)
            .joined(separator: "\n") + "\n"
        try? markdown.write(
            to: appDirectory.appendingPathComponent("INDEX.md"), atomically: true, encoding: .utf8)
    }

    private func markdownDirectory(bundleId: String) -> URL {
        let safe = bundleId
            .components(separatedBy: CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: "-._")).inverted)
            .joined(separator: "_")
        return directory.appendingPathComponent("apps/\(safe)", isDirectory: true)
    }

    private func markdownFileName(_ reference: AppReference) -> String {
        let base = reference.title.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return (base.isEmpty ? reference.kind.rawValue : base) + ".md"
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static let curatedOfficialReferences: [String: [AppReference]] = [
        "com.apple.Notes": [
            AppReference(
                kind: .documentation, title: "Notes User Guide",
                url: "https://support.apple.com/en-gb/guide/notes/welcome/mac")
        ],
        "com.apple.reminders": [
            AppReference(
                kind: .documentation, title: "Reminders User Guide",
                url: "https://support.apple.com/guide/reminders/welcome/mac")
        ],
        "com.apple.mail": [
            AppReference(
                kind: .documentation, title: "Mail User Guide",
                url: "https://support.apple.com/guide/mail/welcome-mlhlb072c8be/mac")
        ],
        "com.apple.Safari": [
            AppReference(
                kind: .documentation, title: "Safari User Guide",
                url: "https://support.apple.com/guide/safari/welcome/mac")
        ],
    ]
}
