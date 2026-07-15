import AppKit
import Foundation

struct GlobalContextSearchSnapshot {
    let query: String
    let documents: [GlobalSearchService.SearchDocument]
    let appDocuments: [GlobalSearchService.SearchDocument]
    let menuDocuments: [GlobalSearchService.SearchDocument]

    var isEmpty: Bool {
        appDocuments.isEmpty && menuDocuments.isEmpty
    }
}

final class GlobalContextSearchCoordinator {
    nonisolated static let shared = GlobalContextSearchCoordinator()
    private let lock = NSLock()
    nonisolated(unsafe) private var cachedKey: CacheKey?
    nonisolated(unsafe) private var cachedSnapshot: GlobalContextSearchSnapshot?

    nonisolated private init() {}

    nonisolated func snapshot(
        query rawQuery: String,
        limit: Int,
        includeCachedMenus: Bool = true,
        includeRunningCachedMenus: Bool = false
    ) -> GlobalContextSearchSnapshot {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty, limit > 0 else {
            return GlobalContextSearchSnapshot(query: query, documents: [], appDocuments: [], menuDocuments: [])
        }

        let revision = GlobalSearchService.shared.indexRevision
        let key = CacheKey(
            query: query,
            limit: limit,
            revision: revision,
            includeCachedMenus: includeCachedMenus,
            includeRunningCachedMenus: includeRunningCachedMenus
        )
        lock.lock()
        if cachedKey == key, let cachedSnapshot {
            lock.unlock()
            return cachedSnapshot
        }
        lock.unlock()

        let rankedLimit = max(limit * 3, 48)
        let docs = rankedDocuments(
            for: query,
            limit: rankedLimit,
            includeCachedMenus: includeCachedMenus,
            includeRunningCachedMenus: includeRunningCachedMenus
        )
        var appDocuments: [GlobalSearchService.SearchDocument] = []
        var menuDocuments: [GlobalSearchService.SearchDocument] = []
        appDocuments.reserveCapacity(limit)
        menuDocuments.reserveCapacity(limit)

        for doc in docs {
            switch doc.action {
            case .cachedMenu, .browserURL:
                if menuDocuments.count < limit {
                    menuDocuments.append(doc)
                }
            default:
                if appDocuments.count < limit {
                    appDocuments.append(doc)
                }
            }
            if appDocuments.count >= limit && menuDocuments.count >= limit { break }
        }

        let snapshot = GlobalContextSearchSnapshot(
            query: query,
            documents: docs,
            appDocuments: appDocuments,
            menuDocuments: menuDocuments
        )
        lock.lock()
        cachedKey = key
        cachedSnapshot = snapshot
        lock.unlock()
        return snapshot
    }

    nonisolated private func rankedDocuments(
        for query: String,
        limit: Int,
        includeCachedMenus: Bool,
        includeRunningCachedMenus: Bool
    ) -> [GlobalSearchService.SearchDocument] {
        var output: [GlobalSearchService.SearchDocument] = []
        var seen = Set<String>()
        for variant in queryVariants(for: query).prefix(4) {
            let remainingLimit = max(8, limit - output.count)
            let docs = GlobalSearchService.shared.query(
                variant,
                limit: remainingLimit,
                includeCachedMenus: includeCachedMenus,
                includeRunningCachedMenus: includeRunningCachedMenus
            )
            for doc in docs where seen.insert(doc.id).inserted {
                output.append(doc)
                if output.count >= limit { return output }
            }
        }
        return output
    }

    nonisolated private func queryVariants(for query: String) -> [String] {
        let normalized = AppMenuCapabilityCache.normalize(query)
        guard !normalized.isEmpty else { return [] }
        var variants: [String] = []
        func add(_ value: String) {
            let v = AppMenuCapabilityCache.normalize(value)
            guard !v.isEmpty, !variants.contains(v) else { return }
            variants.append(v)
        }

        add(normalized)
        let words = normalized.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return variants }

        let objectWords: Set<String> = [
            "file", "files", "message", "messages", "window", "tab", "note", "notes",
            "task", "tasks", "reminder", "reminders", "document", "documents"
        ]
        let actionWords: Set<String> = [
            "new", "open", "quit", "close", "search", "find", "send", "create",
            "make", "start", "stop", "pause", "play"
        ]

        if let first = words.first, actionWords.contains(first), words.count >= 2 {
            let tail = Array(words.dropFirst())
            add((tail + [first]).joined(separator: " "))
            let withoutObjects = tail.filter { !objectWords.contains($0) }
            if !withoutObjects.isEmpty {
                add(([first] + withoutObjects).joined(separator: " "))
                add((withoutObjects + [first]).joined(separator: " "))
            }
        }

        if let inIndex = words.firstIndex(of: "in"), inIndex > 0, inIndex + 1 < words.count {
            let before = words[..<inIndex].joined(separator: " ")
            let app = words[(inIndex + 1)...].joined(separator: " ")
            add("\(app) \(before)")
        }

        if let app = words.last, words.count >= 2 {
            let head = words.dropLast().filter { !objectWords.contains($0) }.joined(separator: " ")
            if !head.isEmpty { add("\(app) \(head)") }
        }

        return variants
    }

    nonisolated func resolveFastTopMatch(query rawQuery: String) -> GlobalContextTopMatch? {
        let started = Date()
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return nil }

        let docs = GlobalSearchService.shared.query(
            query,
            limit: 80,
            includeCachedMenus: true,
            includeRunningCachedMenus: true
        )
        guard !docs.isEmpty else {
            recordFastTopMatchTiming(started: started, query: query, matched: false)
            return nil
        }

        var installedExactPrefix: GlobalSearchService.SearchDocument?
        var runningExactPrefix: GlobalSearchService.SearchDocument?
        var commandExactPrefix: GlobalSearchService.SearchDocument?
        var installedFuzzy: GlobalSearchService.SearchDocument?
        var runningFuzzy: GlobalSearchService.SearchDocument?
        var commandFuzzy: GlobalSearchService.SearchDocument?
        var cachedMenuCounts: [String: (doc: GlobalSearchService.SearchDocument, count: Int)] = [:]

        func isPrefixMatch(_ doc: GlobalSearchService.SearchDocument) -> Bool {
            if doc.normalizedTitle.hasPrefix(query) { return true }
            if doc.titleWords.contains(where: { $0.hasPrefix(query) }) { return true }
            if doc.aliases.contains(where: { $0.hasPrefix(query) }) { return true }
            return !doc.acronym.isEmpty && doc.acronym.hasPrefix(query)
        }

        for doc in docs {
            switch doc.action {
            case .cachedMenu(let bundleId, _, _, _, _):
                guard !bundleId.isEmpty else { continue }
                let current = cachedMenuCounts[bundleId]
                cachedMenuCounts[bundleId] = (current?.doc ?? doc, (current?.count ?? 0) + 1)
            case .browserURL(_, let bundleId, _, _, _):
                guard !bundleId.isEmpty else { continue }
                let current = cachedMenuCounts[bundleId]
                cachedMenuCounts[bundleId] = (current?.doc ?? doc, (current?.count ?? 0) + 1)
            case .systemCommandScope:
                if isPrefixMatch(doc) {
                    if commandExactPrefix == nil { commandExactPrefix = doc }
                } else if commandFuzzy == nil {
                    commandFuzzy = doc
                }
            default:
                let running = doc.sourceKind == .running
                if running {
                    if isPrefixMatch(doc) {
                        if runningExactPrefix == nil { runningExactPrefix = doc }
                    } else if runningFuzzy == nil {
                        runningFuzzy = doc
                    }
                } else {
                    if isPrefixMatch(doc) {
                        if installedExactPrefix == nil { installedExactPrefix = doc }
                    } else if installedFuzzy == nil {
                        installedFuzzy = doc
                    }
                }
            }
        }

        func topMatch(
            from doc: GlobalSearchService.SearchDocument,
            kind: GlobalContextTopMatch.Kind,
            idPrefix: String? = nil
        ) -> GlobalContextTopMatch {
            let id: String
            if let idPrefix {
                id = "\(idPrefix):\(doc.id)"
            } else {
                id = doc.id
            }
            return GlobalContextTopMatch(
                id: id,
                kind: kind,
                title: doc.title,
                subtitle: doc.subtitle.isEmpty ? nil : doc.subtitle,
                bundleID: doc.bundleId.isEmpty ? nil : doc.bundleId,
                iconKey: doc.bundleId.isEmpty ? doc.filePath : doc.bundleId,
                query: query,
                cachedMenuMatchCount: 0,
                isExpandable: false
            )
        }

        let menuTop = cachedMenuCounts.values
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.doc.title.localizedCaseInsensitiveCompare($1.doc.title) == .orderedAscending
            }
            .first
            .map { entry -> GlobalContextTopMatch in
                let doc = entry.doc
                let subtitlePrefix = doc.sourceKind == .runningMenu ? "Running app" : "Cached menus"
                let suffix = entry.count == 1 ? "cached menu match" : "cached menu matches"
                return GlobalContextTopMatch(
                    id: "cached-menu-app:\(doc.bundleId):\(query)",
                    kind: .cachedMenuApp,
                    title: {
                        if case .cachedMenu(_, let appName, _, _, _) = doc.action {
                            return appName
                        }
                        if case .browserURL(_, _, let browserName, _, _) = doc.action {
                            return browserName
                        }
                        return doc.title
                    }(),
                    subtitle: "\(subtitlePrefix) · \(entry.count) \(suffix)",
                    bundleID: doc.bundleId.isEmpty ? nil : doc.bundleId,
                    iconKey: doc.bundleId.isEmpty ? nil : doc.bundleId,
                    query: query,
                    cachedMenuMatchCount: entry.count,
                    isExpandable: true
                )
            }

        let match: GlobalContextTopMatch?
        if let doc = installedExactPrefix {
            match = topMatch(from: doc, kind: .installedApp)
        } else if let doc = runningExactPrefix {
            match = topMatch(from: doc, kind: .runningApp)
        } else if let doc = commandExactPrefix {
            match = topMatch(from: doc, kind: .globalCommand, idPrefix: "global-command")
        } else if let menuTop {
            match = menuTop
        } else if let doc = installedFuzzy {
            match = topMatch(from: doc, kind: .installedApp)
        } else if let doc = runningFuzzy {
            match = topMatch(from: doc, kind: .runningApp)
        } else if let doc = commandFuzzy {
            match = topMatch(from: doc, kind: .globalCommand, idPrefix: "global-command")
        } else {
            match = nil
        }

        recordFastTopMatchTiming(started: started, query: query, matched: match != nil)
        return match
    }

    nonisolated func resolveFastMatchDockIcons(query rawQuery: String, limit: Int = 12) -> [MatchDockIcon] {
        let started = Date()
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty, limit > 0 else { return [] }

        let docs = GlobalSearchService.shared.query(
            query,
            limit: max(limit * 12, 48),
            includeCachedMenus: true,
            includeRunningCachedMenus: true
        )

        var menuCounts: [String: (doc: GlobalSearchService.SearchDocument, count: Int)] = [:]
        var appDocs: [GlobalSearchService.SearchDocument] = []
        var commandDocs: [GlobalSearchService.SearchDocument] = []
        var seenAppIDs = Set<String>()

        func isPrefixMatch(
            _ doc: GlobalSearchService.SearchDocument, against term: String? = nil
        ) -> Bool {
            let needle = term ?? query
            if doc.normalizedTitle.hasPrefix(needle) { return true }
            if doc.titleWords.contains(where: { $0.hasPrefix(needle) }) { return true }
            if doc.aliases.contains(where: { $0.hasPrefix(needle) }) { return true }
            return !doc.acronym.isEmpty && doc.acronym.hasPrefix(needle)
        }

        func score(for doc: GlobalSearchService.SearchDocument, menuCount: Int = 0) -> Double {
            let prefix = isPrefixMatch(doc)
            switch doc.action {
            case .cachedMenu:
                return 30_000 + Double(menuCount)
            case .systemCommandScope:
                return 20_000 + doc.rankingBoost
            default:
                if prefix, doc.sourceKind == .running {
                    return 40_000 + doc.rankingBoost
                }
                if prefix {
                    return 50_000 + doc.rankingBoost
                }
                return 10_000 + doc.rankingBoost + (doc.sourceKind == .running ? 100 : 0)
            }
        }

        for doc in docs {
            switch doc.action {
            case .cachedMenu(let bundleId, _, _, _, _):
                guard !bundleId.isEmpty else { continue }
                let current = menuCounts[bundleId]
                menuCounts[bundleId] = (current?.doc ?? doc, (current?.count ?? 0) + 1)
            case .browserURL(_, let bundleId, _, _, _):
                guard !bundleId.isEmpty else { continue }
                let current = menuCounts[bundleId]
                menuCounts[bundleId] = (current?.doc ?? doc, (current?.count ?? 0) + 1)
            case .systemCommandScope:
                if commandDocs.count < limit {
                    commandDocs.append(doc)
                }
            default:
                let key = doc.bundleId.isEmpty ? doc.id : doc.bundleId
                guard seenAppIDs.insert(key).inserted else { continue }
                if appDocs.count < limit {
                    appDocs.append(doc)
                }
            }
        }

        // Multi-word queries ("new text messages") rarely match one full title —
        // fall back to per-word prefix matching so the dock icons show the apps
        // the user is actually naming (Messages, TextEdit …), one per word.
        if appDocs.isEmpty, menuCounts.isEmpty, query.contains(" ") {
            for token in query.split(separator: " ").map(String.init) where token.count >= 3 {
                let tokenDocs = GlobalSearchService.shared.query(
                    token,
                    limit: 8,
                    includeCachedMenus: false,
                    includeRunningCachedMenus: false
                )
                for doc in tokenDocs {
                    switch doc.action {
                    case .cachedMenu, .systemCommandScope:
                        continue
                    default:
                        guard isPrefixMatch(doc, against: token) else { continue }
                        let key = doc.bundleId.isEmpty ? doc.id : doc.bundleId
                        guard seenAppIDs.insert(key).inserted else { continue }
                        appDocs.append(doc)
                    }
                    break  // best prefix match per word only
                }
                if appDocs.count >= 5 { break }
            }
        }

        var itemsByID: [String: MatchDockIcon] = [:]
        var orderedIDs: [String] = []

        func append(_ item: MatchDockIcon) {
            if let existing = itemsByID[item.id] {
                itemsByID[item.id] = MatchDockIcon(
                    id: existing.id,
                    bundleID: existing.bundleID ?? item.bundleID,
                    title: existing.title,
                    icon: existing.icon,
                    isRunning: existing.isRunning || item.isRunning,
                    isExpandable: existing.isExpandable || item.isExpandable,
                    score: max(existing.score, item.score),
                    isExactAppPrefix: existing.isExactAppPrefix || item.isExactAppPrefix
                )
                return
            }
            itemsByID[item.id] = item
            orderedIDs.append(item.id)
        }

        let runningBundleIDs = Set(
            NSWorkspace.shared.runningApplications
                .compactMap(\.bundleIdentifier)
                .map { $0.lowercased() }
        )

        for doc in appDocs {
            let itemID = doc.bundleId.isEmpty ? doc.id : "match-dock:\(doc.bundleId)"
            append(MatchDockIcon(
                id: itemID,
                bundleID: doc.bundleId.isEmpty ? nil : doc.bundleId,
                title: doc.title,
                icon: doc.icon ?? NSWorkspace.shared.icon(forFileType: "app"),
                isRunning: doc.sourceKind == .running,
                isExpandable: false,
                score: score(for: doc),
                isExactAppPrefix: isPrefixMatch(doc)
            ))
        }

        for entry in menuCounts.values.sorted(by: { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.doc.title.localizedCaseInsensitiveCompare(rhs.doc.title) == .orderedAscending
        }) {
            let doc = entry.doc
            let appName: String
            if case .cachedMenu(_, let name, _, _, _) = doc.action {
                appName = name
            } else if case .browserURL(_, _, let name, _, _) = doc.action {
                appName = name
            } else {
                appName = doc.title
            }
            append(MatchDockIcon(
                id: doc.bundleId.isEmpty ? "cached-menu-app:\(appName):\(query)" : "match-dock:\(doc.bundleId)",
                bundleID: doc.bundleId.isEmpty ? nil : doc.bundleId,
                title: appName,
                icon: doc.icon ?? NSWorkspace.shared.icon(forFileType: "app"),
                isRunning: doc.sourceKind == .runningMenu,
                isExpandable: true,
                score: score(for: doc, menuCount: entry.count),
                isExactAppPrefix: false
            ))
        }

        let fallbackMenuOwners = cachedMenuOwnerMatches(
            query: query,
            excludingBundleIDs: Set(menuCounts.keys.map { $0.lowercased() }),
            limit: limit
        )
        for owner in fallbackMenuOwners {
            append(MatchDockIcon(
                id: "match-dock:\(owner.bundleID)",
                bundleID: owner.bundleID,
                title: owner.appName,
                icon: owner.icon,
                isRunning: runningBundleIDs.contains(owner.bundleID.lowercased()),
                isExpandable: true,
                score: 30_000 + Double(owner.matchCount),
                isExactAppPrefix: false
            ))
        }

        for doc in commandDocs {
            append(MatchDockIcon(
                id: "global-command:\(doc.id)",
                bundleID: doc.bundleId.isEmpty ? nil : doc.bundleId,
                title: doc.title,
                icon: doc.icon ?? NSWorkspace.shared.icon(forFileType: "app"),
                isRunning: false,
                isExpandable: false,
                score: score(for: doc),
                isExactAppPrefix: false
            ))
        }

        let items = orderedIDs.compactMap { itemsByID[$0] }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            .prefix(limit)
        let output = Array(items)
        let elapsedMS = Date().timeIntervalSince(started) * 1_000
        if elapsedMS >= 4 {
            SearchPerformanceLog.shared.record(
                label: "global.resolveFastMatchDockIcons",
                elapsedMS: elapsedMS,
                query: query,
                pills: output.count
            )
        }
        return output
    }

    nonisolated private func cachedMenuOwnerMatches(
        query: String,
        excludingBundleIDs: Set<String>,
        limit: Int
    ) -> [(bundleID: String, appName: String, icon: NSImage, matchCount: Int)] {
        guard !query.isEmpty, limit > 0 else { return [] }
        var owners: [(bundleID: String, appName: String, icon: NSImage, matchCount: Int)] = []
        var seen = excludingBundleIDs
        for summary in AppMenuCapabilityCache.shared.summaries() {
            let bundleID = summary.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleID.isEmpty, seen.insert(bundleID.lowercased()).inserted else { continue }
            let items = GlobalContextEngine.shared.cachedMenuItems(
                bundleIdentifier: bundleID,
                appName: summary.appName,
                query: query,
                maxResults: 3
            )
            guard !items.isEmpty else { continue }
            let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSWorkspace.shared.icon(forFileType: "app")
            owners.append((bundleID, summary.appName, icon, items.count))
            if owners.count >= limit { break }
        }
        return owners
    }

    nonisolated func prepareExpandedResults(query rawQuery: String) async -> GlobalContextPreparedResults {
        let started = Date()
        let snapshot = self.snapshot(
            query: rawQuery,
            limit: 48,
            includeCachedMenus: false,
            includeRunningCachedMenus: true
        )
        let elapsedMS = Date().timeIntervalSince(started) * 1_000
        if elapsedMS >= 8 {
            SearchPerformanceLog.shared.record(
                label: "global.prepareExpandedResults",
                elapsedMS: elapsedMS,
                query: snapshot.query,
                pills: snapshot.appDocuments.count + snapshot.menuDocuments.count
            )
        }
        return GlobalContextPreparedResults(
            query: snapshot.query,
            appDocumentIDs: snapshot.appDocuments.map(\.id),
            menuDocumentIDs: snapshot.menuDocuments.map(\.id)
        )
    }

    nonisolated private func recordFastTopMatchTiming(
        started: Date,
        query: String,
        matched: Bool
    ) {
        let elapsedMS = Date().timeIntervalSince(started) * 1_000
        if elapsedMS >= 4 {
            SearchPerformanceLog.shared.record(
                label: "global.resolveFastTopMatch matched=\(matched)",
                elapsedMS: elapsedMS,
                query: query,
                pills: matched ? 1 : 0
            )
        }
    }
}

private struct CacheKey: Equatable {
    let query: String
    let limit: Int
    let revision: Int
    let includeCachedMenus: Bool
    let includeRunningCachedMenus: Bool
}
