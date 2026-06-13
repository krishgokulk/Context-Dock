import Foundation

struct GlobalContextSearchSnapshot {
    let query: String
    let appDocuments: [GlobalSearchService.SearchDocument]
    let menuDocuments: [GlobalSearchService.SearchDocument]

    var isEmpty: Bool {
        appDocuments.isEmpty && menuDocuments.isEmpty
    }
}

final class GlobalContextSearchCoordinator {
    nonisolated static let shared = GlobalContextSearchCoordinator()
    private let lock = NSLock()
    private var cachedKey: CacheKey?
    private var cachedSnapshot: GlobalContextSearchSnapshot?

    nonisolated private init() {}

    nonisolated func snapshot(
        query rawQuery: String,
        limit: Int,
        includeCachedMenus: Bool = true,
        includeRunningCachedMenus: Bool = false
    ) -> GlobalContextSearchSnapshot {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty, limit > 0 else {
            return GlobalContextSearchSnapshot(query: query, appDocuments: [], menuDocuments: [])
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

        let docs = GlobalSearchService.shared.query(
            query,
            limit: max(limit * 8, 80),
            includeCachedMenus: includeCachedMenus,
            includeRunningCachedMenus: includeRunningCachedMenus
        )
        var appDocuments: [GlobalSearchService.SearchDocument] = []
        var menuDocuments: [GlobalSearchService.SearchDocument] = []
        appDocuments.reserveCapacity(limit)
        menuDocuments.reserveCapacity(limit)

        for doc in docs {
            switch doc.action {
            case .cachedMenu:
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
            appDocuments: appDocuments,
            menuDocuments: menuDocuments
        )
        lock.lock()
        cachedKey = key
        cachedSnapshot = snapshot
        lock.unlock()
        return snapshot
    }
}

private struct CacheKey: Equatable {
    let query: String
    let limit: Int
    let revision: Int
    let includeCachedMenus: Bool
    let includeRunningCachedMenus: Bool
}
