// FinderOpenFrequencyStore.swift
// Context-Dock
//
// Tracks how often the user opens each file/folder/app from Finder desktop-only
// mode, so the most-launched items (Downloads, Screenshots, Applications, hot
// files…) float to the top. Deliberately tiny + additive: a single UserDefaults
// dictionary [path: count], read/written in O(1), so it never touches the search
// hot path or the existing ranking performance.

import Foundation

final class FinderOpenFrequencyStore {
    static let shared = FinderOpenFrequencyStore()
    private init() { counts = Self.load() }

    private let storageKey = "finderOpenFrequency_v1"
    private let maxEntries = 400
    private var counts: [String: Int]

    /// Record one open of `path`. Cheap — mutates an in-memory dict and debounces
    /// the disk write.
    func recordOpen(path: String) {
        let key = path.lowercased()
        guard !key.isEmpty else { return }
        counts[key, default: 0] += 1
        if counts.count > maxEntries { prune() }
        scheduleSave()
    }

    /// Raw open count for a path (0 if never opened).
    func count(forPath path: String) -> Int {
        counts[path.lowercased()] ?? 0
    }

    /// A bounded ranking boost (0…1) from the open count — saturates at 8 opens so a
    /// single hot folder can't dwarf everything else.
    func frequencyBoost(forPath path: String) -> Double {
        min(1.0, Double(count(forPath: path)) / 8.0)
    }

    // MARK: - Persistence

    private var saveScheduled = false
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            let snapshot = self.counts
            if let data = try? JSONSerialization.data(withJSONObject: snapshot) {
                UserDefaults.standard.set(data, forKey: self.storageKey)
            }
        }
    }

    private func prune() {
        // Keep the top-`maxEntries` most-opened paths.
        counts = Dictionary(
            uniqueKeysWithValues:
                counts.sorted { $0.value > $1.value }.prefix(maxEntries).map { ($0.key, $0.value) })
    }

    private static func load() -> [String: Int] {
        guard let data = UserDefaults.standard.data(forKey: "finderOpenFrequency_v1"),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Int]
        else { return [:] }
        return dict
    }
}
