import AppKit
import Foundation

// Hot in-memory search index for global context.
// Pre-computes normalized text, acronyms, and aliases at index-build time so the
// query path does only string comparisons — no normalization, no alias set building.
final class GlobalSearchService {

    nonisolated static let shared = GlobalSearchService()
    nonisolated private init() {}

    // MARK: - Document

    enum SourceKind: Double {
        case running = 3_000
        case pinned = 2_000
        case builtIn = 1_500
        case recent = 1_200
        case cli = 900
        case runningMenu = 850
        case systemCommand = 700
        case installed = 400
    }

    enum ActionSpec {
        case launchPath(String)
        case launchBundleId(String, path: String)
        case activatePID(pid_t, bundleId: String, path: String?)
        case cliScope(command: String, displayName: String)
        case systemCommandScope(commandKey: String)
        case cachedMenu(bundleId: String, appName: String, path: [String], shortcutChar: String?, shortcutModifiers: Int)
    }

    struct SearchDocument {
        let id: String                   // bundleId or "cli://…" or path for dedup
        let title: String
        let subtitle: String
        let bundleId: String
        let filePath: String?
        let normalizedTitle: String      // pre-computed once
        let titleWords: [String]         // normalizedTitle split on space
        let acronym: String              // "vsc" from "visual studio code"
        let aliases: [String]            // pre-computed, normalized
        let aliasWords: [[String]]       // aliases split once; query path must not allocate
        let sourceKind: SourceKind
        let rankingBoost: Double
        let icon: NSImage?
        let usageTrackingKey: String
        let action: ActionSpec
    }

    // MARK: - Storage

    private let lock = NSLock()
    nonisolated(unsafe) private var documents: [SearchDocument] = []
    nonisolated(unsafe) private var revision: Int = 0
    // n-gram (1- and 2-char) → document indices. Any occurrence of a query (prefix OR
    // substring) contains the query's first gram, so `gramIndex[q.prefix(2)]` is a
    // superset of all matchable docs — we score only those, never the full array.
    nonisolated(unsafe) private var gramIndex: [String: [Int]] = [:]
    nonisolated(unsafe) private var bundleIndex: [String: [Int]] = [:]

    /// Grams (1- and 2-char) of a normalized string, for building/querying the index.
    nonisolated private static func grams(_ s: String) -> Set<String> {
        guard !s.isEmpty else { return [] }
        let chars = Array(s)
        var out = Set<String>()
        for i in chars.indices {
            out.insert(String(chars[i]))
            if i + 1 < chars.count { out.insert(String(chars[i...(i + 1)])) }
        }
        return out
    }

    // MARK: - Build

    func rebuild(with docs: [SearchDocument]) {
        var grams: [String: [Int]] = [:]
        var bundle: [String: [Int]] = [:]
        for (i, doc) in docs.enumerated() {
            var keys = Set<String>()
            keys.formUnion(Self.grams(doc.normalizedTitle))
            if !doc.acronym.isEmpty { keys.formUnion(Self.grams(doc.acronym)) }
            for alias in doc.aliases { keys.formUnion(Self.grams(alias)) }
            for key in keys { grams[key, default: []].append(i) }
            if !doc.bundleId.isEmpty { bundle[doc.bundleId, default: []].append(i) }
        }

        lock.lock()
        documents = docs
        gramIndex = grams
        bundleIndex = bundle
        revision &+= 1
        lock.unlock()
    }

    // MARK: - Query (nonisolated — runs off MainActor)

    nonisolated func query(
        _ text: String,
        limit: Int = 20,
        includeCachedMenus: Bool = true,
        includeRunningCachedMenus: Bool = false
    ) -> [SearchDocument] {
        let q = AppMenuCapabilityCache.normalize(text)
        guard !q.isEmpty else { return [] }
        let started = Date()

        lock.lock()
        let docs = documents
        // Candidate doc indices from the n-gram index — only docs whose text contains
        // the query's first gram can match (prefix OR substring). Score just those.
        let key = String(q.prefix(2))
        let candidates = gramIndex[key] ?? []
        lock.unlock()

        var results: [(doc: SearchDocument, score: Double)] = []
        results.reserveCapacity(min(candidates.count, max(limit, 1)))

        for index in candidates {
            guard index < docs.count else { continue }
            let doc = docs[index]
            if !includeCachedMenus, case .cachedMenu = doc.action {
                guard includeRunningCachedMenus, doc.sourceKind == .runningMenu else { continue }
            }
            guard let score = matchScore(query: q, doc: doc) else { continue }
            insertRanked((doc, score), into: &results, limit: limit)
        }

        let output = results.map(\.doc)
        let elapsedMS = Date().timeIntervalSince(started) * 1_000
        if elapsedMS >= 8 {
            SearchPerformanceLog.shared.record(
                label: "GlobalSearchService.query cand=\(candidates.count)/\(docs.count) limit=\(limit) menus=\(includeCachedMenus) runningMenus=\(includeRunningCachedMenus)",
                elapsedMS: elapsedMS,
                query: q,
                pills: output.count
            )
        }
        return output
    }

    nonisolated var documentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return documents.count
    }

    nonisolated var indexRevision: Int {
        lock.lock()
        defer { lock.unlock() }
        return revision
    }

    nonisolated func documents(forBundleId bundleId: String, limit: Int = 80) -> [SearchDocument] {
        let wanted = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return [] }
        lock.lock()
        let docs = documents
        let indices = bundleIndex[wanted] ?? []
        lock.unlock()
        var results: [SearchDocument] = []
        results.reserveCapacity(min(limit, 24))
        for index in indices where index < docs.count {
            results.append(docs[index])
            if results.count >= limit { break }
        }
        return results
    }

    nonisolated func query(_ text: String, bundleId: String, limit: Int = 20) -> [SearchDocument] {
        let q = AppMenuCapabilityCache.normalize(text)
        let wanted = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return [] }
        let started = Date()

        lock.lock()
        let docs = documents
        // Only this app's documents (bundle index) — never the whole array.
        let bundleDocIndices = bundleIndex[wanted] ?? []
        let gramCandidates: Set<Int> =
            q.isEmpty ? [] : Set(gramIndex[String(q.prefix(2))] ?? [])
        lock.unlock()

        if q.isEmpty {
            var output: [SearchDocument] = []
            output.reserveCapacity(min(limit, 24))
            for index in bundleDocIndices where index < docs.count {
                let doc = docs[index]
                if case .cachedMenu = doc.action { output.append(doc) }
                if output.count >= limit { break }
            }
            let elapsedMS = Date().timeIntervalSince(started) * 1_000
            if elapsedMS >= 8 {
                SearchPerformanceLog.shared.record(
                    label: "GlobalSearchService.bundleEmpty docs=\(docs.count) limit=\(limit)",
                    elapsedMS: elapsedMS,
                    query: wanted,
                    pills: output.count
                )
            }
            return output
        }

        var results: [(doc: SearchDocument, score: Double)] = []
        results.reserveCapacity(min(bundleDocIndices.count, max(limit, 1)))
        for index in bundleDocIndices where gramCandidates.contains(index) && index < docs.count {
            let doc = docs[index]
            guard case .cachedMenu = doc.action else { continue }
            guard let score = matchScore(query: q, doc: doc) else { continue }
            insertRanked((doc, score), into: &results, limit: limit)
        }
        let output = results.map(\.doc)
        let elapsedMS = Date().timeIntervalSince(started) * 1_000
        if elapsedMS >= 8 {
            SearchPerformanceLog.shared.record(
                label: "GlobalSearchService.bundleQuery docs=\(docs.count) limit=\(limit)",
                elapsedMS: elapsedMS,
                query: "\(wanted):\(q)",
                pills: output.count
            )
        }
        return output
    }

    nonisolated func appScopeCandidates(
        for text: String,
        excludingBundleIds: Set<String> = [],
        limit: Int = 6
    ) -> [SearchDocument] {
        let q = AppMenuCapabilityCache.normalize(text)
        guard !q.isEmpty else { return [] }
        let started = Date()

        lock.lock()
        let docs = documents
        lock.unlock()

        var results: [(doc: SearchDocument, score: Double)] = []
        results.reserveCapacity(min(docs.count, max(limit, 1)))
        for doc in docs {
            guard !excludingBundleIds.contains(doc.bundleId) else { continue }
            switch doc.action {
            case .activatePID, .launchBundleId, .launchPath:
                break
            default:
                continue
            }
            guard let score = appScopeMatchScore(query: q, doc: doc) else { continue }
            insertRanked((doc, score), into: &results, limit: limit)
        }

        let output = results.map(\.doc)
        let elapsedMS = Date().timeIntervalSince(started) * 1_000
        if elapsedMS >= 8 {
            SearchPerformanceLog.shared.record(
                label: "GlobalSearchService.appScope docs=\(docs.count) limit=\(limit)",
                elapsedMS: elapsedMS,
                query: q,
                pills: output.count
            )
        }
        return output
    }

    // MARK: - Scoring (pure string ops, no MainActor access)

    nonisolated private func matchScore(query q: String, doc: SearchDocument) -> Double? {
        let base = doc.sourceKind.rawValue + doc.rankingBoost
        var best: Double?

        func keep(_ s: Double) {
            if let prev = best { if s > prev { best = s } } else { best = s }
        }

        let t = doc.normalizedTitle

        // Exact
        if t == q { keep(12_000 + base); return best }
        // Full prefix
        if t.hasPrefix(q) {
            keep(9_600 + base + Double(q.count * 20) - min(Double(t.count), 48))
        }

        // Word prefix (any word in title)
        for (i, word) in doc.titleWords.enumerated() {
            if word == q { keep(10_600 + base) }
            else if word.hasPrefix(q) {
                keep(8_900 + base + Double(q.count * 12) - Double(i * 34))
            }
        }

        // Acronym match
        if !doc.acronym.isEmpty {
            if doc.acronym == q { keep(8_000 + base) }
            else if doc.acronym.hasPrefix(q) { keep(7_500 + base) }
        }

        // Aliases
        for (aliasIndex, alias) in doc.aliases.enumerated() {
            if alias == q { keep(10_600 + base); break }
            if alias.hasPrefix(q) {
                keep(8_250 + base + Double(q.count * 14) - min(Double(alias.count), 48))
            }
            // Word prefix inside alias
            let aliasWords = aliasIndex < doc.aliasWords.count ? doc.aliasWords[aliasIndex] : []
            for (i, word) in aliasWords.enumerated() {
                if word == q { keep(9_000 + base) }
                else if word.hasPrefix(q) {
                    keep(7_700 + base + Double(q.count * 10) - Double(i * 34))
                }
            }
        }

        // Substring (only for queries >= 2 chars)
        if q.count >= 2 {
            if let range = t.range(of: q) {
                let offset = t.distance(from: t.startIndex, to: range.lowerBound)
                keep(4_900 + base - Double(offset * 72) - min(Double(t.count), 48))
            }
            for alias in doc.aliases {
                if let range = alias.range(of: q) {
                    let offset = alias.distance(from: alias.startIndex, to: range.lowerBound)
                    keep(4_250 + base - Double(offset * 58) - min(Double(alias.count), 48))
                }
            }
        }

        return best
    }

    nonisolated private func insertRanked(
        _ candidate: (doc: SearchDocument, score: Double),
        into results: inout [(doc: SearchDocument, score: Double)],
        limit: Int
    ) {
        guard limit > 0 else { return }
        if results.isEmpty {
            results.append(candidate)
            return
        }

        var insertAt = results.count
        for index in results.indices where candidate.score > results[index].score {
            insertAt = index
            break
        }

        if insertAt < results.count {
            results.insert(candidate, at: insertAt)
        } else if results.count < limit {
            results.append(candidate)
        } else {
            return
        }

        if results.count > limit {
            results.removeLast()
        }
    }

    nonisolated private func appScopeMatchScore(query q: String, doc: SearchDocument) -> Double? {
        let candidates = [doc.normalizedTitle] + doc.aliases
        var best: Double?
        for alias in candidates where alias.count >= 2 {
            if q == alias { best = max(best ?? 0, 20_000 + doc.sourceKind.rawValue + Double(alias.count)) }
            if q.hasPrefix(alias + " ") {
                best = max(best ?? 0, 18_000 + doc.sourceKind.rawValue + Double(alias.count))
            }
            if alias.hasPrefix(q), q.count >= 3 {
                best = max(best ?? 0, 10_000 + doc.sourceKind.rawValue + Double(q.count))
            }
        }
        return best
    }
}

// MARK: - Document Builders (call on @MainActor)

extension GlobalSearchService.SearchDocument {

    init(
        runningApp app: NSRunningApplication,
        icon: NSImage?,
        usageScore: Double = 0
    ) {
        let name = app.localizedName ?? ""
        let bundleId = app.bundleIdentifier ?? ""
        let path = app.bundleURL?.path
        let norm = AppMenuCapabilityCache.normalize(name)
        let aliases = Self.aliases(appName: name, bundleId: bundleId)
        self.init(
            id: bundleId.isEmpty ? (path ?? name) : "bundle:\(bundleId)",
            title: name,
            subtitle: "Running",
            bundleId: bundleId,
            filePath: path,
            normalizedTitle: norm,
            titleWords: norm.split(separator: " ").map(String.init),
            acronym: Self.acronym(from: norm),
            aliases: aliases,
            aliasWords: Self.words(fromAliases: aliases),
            sourceKind: .running,
            rankingBoost: Self.appRankingBoost(usageScore: usageScore),
            icon: icon,
            usageTrackingKey: "app:\(bundleId)",
            action: .activatePID(app.processIdentifier, bundleId: bundleId, path: path)
        )
    }

    init(
        pinnedApp app: PinnedApp,
        icon: NSImage?,
        usageScore: Double = 0
    ) {
        let bundleId = app.bundleIdentifier ?? ""
        let norm = AppMenuCapabilityCache.normalize(app.name)
        let aliases = Self.aliases(appName: app.name, bundleId: bundleId)
        self.init(
            id: bundleId.isEmpty ? "path:\(app.path)" : "bundle:\(bundleId)",
            title: app.name,
            subtitle: app.path,
            bundleId: bundleId,
            filePath: app.path,
            normalizedTitle: norm,
            titleWords: norm.split(separator: " ").map(String.init),
            acronym: Self.acronym(from: norm),
            aliases: aliases,
            aliasWords: Self.words(fromAliases: aliases),
            sourceKind: .pinned,
            rankingBoost: Self.appRankingBoost(usageScore: usageScore),
            icon: icon,
            usageTrackingKey: "app:\(bundleId.isEmpty ? app.path : bundleId)",
            action: .launchPath(app.path)
        )
    }

    init(
        installedApp result: SearchResult,
        bundleId: String,
        sourceKind: GlobalSearchService.SourceKind = .installed,
        usageScore: Double = 0
    ) {
        let name = result.title
        let path = result.filePath ?? result.subtitle
        let norm = AppMenuCapabilityCache.normalize(name)
        let aliases = Self.aliases(appName: name, bundleId: bundleId)
        self.init(
            id: bundleId.isEmpty ? "path:\(path)" : "bundle:\(bundleId)",
            title: name,
            subtitle: path,
            bundleId: bundleId,
            filePath: path,
            normalizedTitle: norm,
            titleWords: norm.split(separator: " ").map(String.init),
            acronym: Self.acronym(from: norm),
            aliases: aliases,
            aliasWords: Self.words(fromAliases: aliases),
            sourceKind: sourceKind,
            rankingBoost: Self.appRankingBoost(usageScore: usageScore),
            icon: result.icon,
            usageTrackingKey: "app:\(bundleId.isEmpty ? path : bundleId)",
            action: .launchPath(path)
        )
    }

    init(
        cliPackage pkg: TerminalPackage,
        icon: NSImage?
    ) {
        let norm = AppMenuCapabilityCache.normalize(pkg.command)
        let nameNorm = AppMenuCapabilityCache.normalize(pkg.name)
        var aliases: [String] = []
        if !nameNorm.isEmpty, nameNorm != norm { aliases.append(nameNorm) }
        for kw in pkg.keywords {
            let k = AppMenuCapabilityCache.normalize(kw)
            if !k.isEmpty { aliases.append(k) }
        }
        self.init(
            id: "cli://\(pkg.command)",
            title: pkg.command,
            subtitle: "cli://\(pkg.command)",
            bundleId: "cli://\(pkg.command)",
            filePath: nil,
            normalizedTitle: norm,
            titleWords: norm.split(separator: " ").map(String.init),
            acronym: Self.acronym(from: norm),
            aliases: aliases,
            aliasWords: Self.words(fromAliases: aliases),
            sourceKind: .cli,
            rankingBoost: 0,
            icon: icon,
            usageTrackingKey: "cli:\(pkg.command)",
            action: .cliScope(command: pkg.command, displayName: pkg.name.isEmpty ? pkg.command : pkg.name)
        )
    }

    init?(
        menuItem item: AXMenuItem,
        appName: String,
        bundleId: String,
        processIdentifier: pid_t,
        icon: NSImage?
    ) {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = item.path
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "-" }
        guard !title.isEmpty, path.count > 1, item.children.isEmpty else { return nil }

        let norm = AppMenuCapabilityCache.normalize(title)
        let appNorm = AppMenuCapabilityCache.normalize(appName)
        let pathNorm = AppMenuCapabilityCache.normalize(path.joined(separator: " "))
        let contextNorm = AppMenuCapabilityCache.normalize(path.dropLast().last ?? "")
        guard AppMenuCapabilityCache.shouldExposeInGlobalContext(title: title, path: path) else {
            return nil
        }
        var aliases = Self.aliases(appName: appName, bundleId: bundleId)
        aliases.append(appNorm + " " + norm)
        aliases.append(pathNorm)
        if !contextNorm.isEmpty { aliases.append(contextNorm + " " + norm) }
        aliases = Array(Set(aliases.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }))

        self.init(
            id: "menu:\(bundleId):\(path.joined(separator: ">"))",
            title: title,
            subtitle: appName,
            bundleId: bundleId,
            filePath: nil,
            normalizedTitle: norm,
            titleWords: norm.split(separator: " ").map(String.init),
            acronym: Self.acronym(from: norm),
            aliases: aliases,
            aliasWords: Self.words(fromAliases: aliases),
            sourceKind: .runningMenu,
            rankingBoost: 0,
            icon: icon,
            usageTrackingKey: "menu:\(bundleId):\(path.joined(separator: ">"))",
            action: .cachedMenu(
                bundleId: bundleId,
                appName: appName,
                path: path,
                shortcutChar: item.shortcutChar,
                shortcutModifiers: item.shortcutModifiers
            )
        )
    }

    // MARK: - Helpers

    static func acronym(from normalizedTitle: String) -> String {
        normalizedTitle
            .split(separator: " ")
            .compactMap(\.first)
            .map(String.init)
            .joined()
    }

    static func words(fromAliases aliases: [String]) -> [[String]] {
        aliases.map { $0.split(separator: " ").map(String.init) }
    }

    static func appRankingBoost(usageScore: Double) -> Double {
        min(max(usageScore, 0) * 650, 3_800)
    }

    static func aliases(appName: String, bundleId: String) -> [String] {
        var set = Set<String>()
        let norm = AppMenuCapabilityCache.normalize(appName)
        if !norm.isEmpty { set.insert(norm) }

        // First word of title (e.g. "safari" from "safari technology preview")
        if let first = norm.split(separator: " ").first.map(String.init), !first.isEmpty {
            set.insert(first)
        }

        // Singular form (strip trailing "s")
        if norm.hasSuffix("s"), norm.count > 3 {
            set.insert(String(norm.dropLast()))
        }

        // Bundle tail (e.g. "vscode" from "com.microsoft.VSCode")
        if let tail = bundleId.split(separator: ".").last {
            let t = AppMenuCapabilityCache.normalize(String(tail))
            if !t.isEmpty, t != "app" { set.insert(t) }
        }

        // Well-known overrides
        switch bundleId {
        case "com.apple.MobileSMS":
            set.formUnion(["messages", "message", "imessage", "texts", "sms"])
        case "com.apple.mail":
            set.formUnion(["mail", "email"])
        case "com.apple.systempreferences":
            set.formUnion(["settings", "preferences", "system settings", "system preferences"])
        case "com.apple.Safari":
            set.insert("safari")
        case "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders":
            set.formUnion(["code", "vscode", "vs code", "visual studio code"])
        case "com.apple.Terminal":
            set.formUnion(["terminal", "term", "console"])
        case "com.apple.Spotlight":
            set.insert("spotlight")
        case "com.apple.finder":
            set.formUnion(["finder", "files", "file manager"])
        default:
            break
        }

        set.remove(norm)  // already the primary, keep aliases distinct
        return set.filter { !$0.isEmpty }
    }
}
