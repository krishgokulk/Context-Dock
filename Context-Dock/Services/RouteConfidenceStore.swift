//  RouteConfidenceStore.swift
//  Context-Dock
//
//  Local-only route-confidence learning for DoraX Action Chat. When a General AI Chat
//  route verifies successfully, we remember (intent → app → route → capability) so future
//  AMBIGUOUS requests can rank the user's proven route higher. Failures demote a route.
//
//  Privacy: on-disk JSON in Application Support only. Never sent to any AI provider.
//
//  Safety: the learned adjustment is CLAMPED to ±`maxAdjustment` (40), far smaller than the
//  hard tier gap (100) the resolver uses between route classes. So learning can reorder
//  routes WITHIN a tier but can never make a weaker class (e.g. AX) outrank a safer one
//  (adapter/MCP). Hard safety ranking always wins.

import Foundation

struct RouteConfidenceRecord: Codable {
    var intentKey: String
    var bundleID: String
    var route: String
    var capabilityID: String
    var successCount: Int
    var failureCount: Int
    var lastSuccess: Date?
}

@MainActor
final class RouteConfidenceStore {
    static let shared = RouteConfidenceStore()

    /// Max absolute rank adjustment. Must stay < the resolver's 100-per-tier gap so learning
    /// never crosses route-class boundaries.
    static let maxAdjustment = 40

    private var records: [String: RouteConfidenceRecord] = [:]

    private let fileURL: URL = {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("DoraX/RouteConfidence.json", isDirectory: false)
    }()

    private init() { load() }

    private func compositeKey(
        intentKey: String, bundleID: String, route: String, capabilityID: String
    ) -> String {
        "\(intentKey)|\(bundleID)|\(route)|\(capabilityID)"
    }

    /// Record the outcome of a chosen route. Called after verify (success) or on failure.
    func record(
        intentKey: String, bundleID: String, route: String, capabilityID: String, success: Bool
    ) {
        guard !intentKey.isEmpty else { return }
        let key = compositeKey(
            intentKey: intentKey, bundleID: bundleID, route: route, capabilityID: capabilityID)
        var record =
            records[key]
            ?? RouteConfidenceRecord(
                intentKey: intentKey, bundleID: bundleID, route: route,
                capabilityID: capabilityID, successCount: 0, failureCount: 0, lastSuccess: nil)
        if success {
            record.successCount += 1
            record.lastSuccess = Date()
        } else {
            record.failureCount += 1
        }
        records[key] = record
        save()
    }

    func stats(
        intentKey: String, bundleID: String, route: String, capabilityID: String
    ) -> (success: Int, failure: Int)? {
        let key = compositeKey(
            intentKey: intentKey, bundleID: bundleID, route: route, capabilityID: capabilityID)
        guard let r = records[key] else { return nil }
        return (r.successCount, r.failureCount)
    }

    /// Learned rank delta: negative boosts (ranks lower = better), positive demotes. Repeated
    /// failures push it positive; proven successes push it negative. Clamped to ±maxAdjustment.
    func adjustment(
        intentKey: String, bundleID: String, route: String, capabilityID: String
    ) -> Int {
        guard let s = stats(
            intentKey: intentKey, bundleID: bundleID, route: route, capabilityID: capabilityID)
        else { return 0 }
        let raw = s.failure * 12 - s.success * 8
        return max(-Self.maxAdjustment, min(Self.maxAdjustment, raw))
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([String: RouteConfidenceRecord].self, from: data)
        else { return }
        records = decoded
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
