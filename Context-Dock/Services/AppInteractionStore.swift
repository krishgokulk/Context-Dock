// AppInteractionStore.swift
// Context Dock
//
// Records every user query + action per app in isolated JSON files.
// Each app gets its own file so stores never bleed across apps.
// Used to surface frequently-used actions as ranked pills.

import Foundation

// MARK: - Model

struct AppInteraction: Codable {
    enum ActionKind: String, Codable {
        case menuItem       // AX menu traversal
        case adapterAction  // adapter JSON action
        case pageJS         // browser userscript
        case chat           // freeform AI chat
        case shortcut       // keyboard shortcut
    }

    let query: String       // raw user input
    let kind: ActionKind
    let actionId: String    // menu path string, adapter action id, or "chat"
    let appName: String
    let timestamp: Date
}

// MARK: - Store

final class AppInteractionStore {
    static let shared = AppInteractionStore()
    private init() {}

    private let maxPerApp = 200
    private let queue = DispatchQueue(label: "com.contextdock.interactionstore", qos: .utility)

    // MARK: Record

    func record(
        bundleId: String,
        appName: String,
        query: String,
        kind: AppInteraction.ActionKind,
        actionId: String
    ) {
        let entry = AppInteraction(
            query: query,
            kind: kind,
            actionId: actionId,
            appName: appName,
            timestamp: Date()
        )
        queue.async { [weak self] in
            guard let self else { return }
            var list = self.load(bundleId: bundleId)
            list.append(entry)
            if list.count > self.maxPerApp {
                list = Array(list.suffix(self.maxPerApp))
            }
            self.save(list, bundleId: bundleId)
        }
    }

    // MARK: Query

    /// Most-used action IDs for this app, ordered by frequency.
    func topActionIds(for bundleId: String, limit: Int = 8) -> [(id: String, count: Int)] {
        var counts: [String: Int] = [:]
        for item in load(bundleId: bundleId) {
            counts[item.actionId, default: 0] += 1
        }
        return counts
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (id: $0.key, count: $0.value) }
    }

    /// Recent unique queries for this app (newest first).
    func recentQueries(for bundleId: String, limit: Int = 20) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in load(bundleId: bundleId).reversed() {
            let q = item.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !q.isEmpty, seen.insert(q).inserted else { continue }
            result.append(item.query)
            if result.count >= limit { break }
        }
        return result
    }

    /// Frequency boost (0–1) for a given actionId in this app — used for pill ranking.
    func frequencyBoost(bundleId: String, actionId: String) -> Double {
        let list = load(bundleId: bundleId)
        guard !list.isEmpty else { return 0 }
        let count = list.filter { $0.actionId == actionId }.count
        return min(1.0, Double(count) / 10.0)
    }

    // MARK: - Persistence

    private func fileURL(for bundleId: String) -> URL {
        let safe = bundleId
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("ILauncher/AppInteractions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(safe).json")
    }

    private func load(bundleId: String) -> [AppInteraction] {
        let url = fileURL(for: bundleId)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([AppInteraction].self, from: data)) ?? []
    }

    private func save(_ list: [AppInteraction], bundleId: String) {
        let url = fileURL(for: bundleId)
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
