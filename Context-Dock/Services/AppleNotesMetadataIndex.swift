import Foundation

// MARK: - Note metadata model (title, folder, snippet — never full body)

struct NoteMetadata: Codable, Identifiable {
    let id: String
    let title: String
    let folder: String
    let modifiedDate: Date
    let createdDate: Date
    let snippet: String  // first ~200 chars, HTML-stripped
}

// MARK: - In-memory cached index with lazy background refresh

actor AppleNotesMetadataIndex {
    static let shared = AppleNotesMetadataIndex()

    private var index: [String: NoteMetadata] = [:]
    private var lastRefresh: Date?
    private var isRefreshing = false
    private let cacheURL: URL
    private let staleInterval: TimeInterval = 300  // 5 minutes

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Context-Dock", isDirectory: true)
        cacheURL = dir.appendingPathComponent("notes-metadata-cache.json")
        loadFromDisk()
    }

    // MARK: - Queries

    func search(query: String, maxResults: Int = 20) -> [NoteMetadata] {
        guard !query.isEmpty else {
            return index.values
                .sorted { $0.modifiedDate > $1.modifiedDate }
                .prefix(maxResults)
                .map { $0 }
        }
        let lower = query.lowercased()
        return index.values
            .filter {
                $0.title.lowercased().contains(lower)
                    || $0.snippet.lowercased().contains(lower)
                    || $0.folder.lowercased().contains(lower)
            }
            .sorted { $0.modifiedDate > $1.modifiedDate }
            .prefix(maxResults)
            .map { $0 }
    }

    func note(id: String) -> NoteMetadata? { index[id] }

    var cachedCount: Int { index.count }
    var lastRefreshDate: Date? { lastRefresh }

    // MARK: - Refresh

    func refreshIfNeeded() async throws {
        if let last = lastRefresh, Date().timeIntervalSince(last) < staleInterval { return }
        if isRefreshing { return }
        try await performRefresh()
    }

    func forceRefresh() async throws {
        if isRefreshing { return }
        try await performRefresh()
    }

    private func performRefresh() async throws {
        isRefreshing = true
        defer { isRefreshing = false }
        // await suspends the actor — background Process runs on its own queue
        let notes = try await AppleNotesExecutionService.shared.fetchAllMetadata()
        index = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        lastRefresh = Date()
        saveToDisk()
    }

    // MARK: - Disk cache

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([NoteMetadata].self, from: data)
        else { return }
        index = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
    }

    private func saveToDisk() {
        let notes = Array(index.values)
        if let data = try? JSONEncoder().encode(notes) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}
