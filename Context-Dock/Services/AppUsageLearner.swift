//
//  AppUsageLearner.swift
//  Context-Dock
//
//  On-device usage learner. Records app launches, dock pill actions, and search queries,
//  then provides ranked suggestions using a time-decayed frequency score.
//  All data stays on-device in UserDefaults — no network, no external model.
//

import Foundation

// MARK: - AppUsageLearner

final class AppUsageLearner {
    static let shared = AppUsageLearner()

    // ── Storage keys ──────────────────────────────────────────────────
    private let globalAppScoresKey  = "cdock.learn.globalAppScores"    // [bundleID: score]
    private let perAppActionKey     = "cdock.learn.perAppActions"       // [bundleID: [action: score]]
    private let globalQueryKey      = "cdock.learn.globalQueries"       // [query: score]
    private let queryIntentKey      = "cdock.learn.queryIntent"         // [query: score] +ve=menu, -ve=app
    private let lastSaveKey         = "cdock.learn.lastSave"

    // In-memory working copies (written through to UserDefaults periodically)
    private var globalAppScores: [String: Double] = [:]     // bundleID → score
    private var perAppActions:   [String: [String: Double]] = [:] // bundleID → [action → score]
    private var globalQueries:   [String: Double] = [:]     // query → score
    private var queryIntent:     [String: Double] = [:]     // query → intent bias

    // Decay half-life: score halves every 7 days
    private let halfLifeSeconds: Double = 7 * 24 * 3600

    private init() {
        load()
    }

    // MARK: - Recording

    /// Call whenever the user activates or launches an app.
    func recordApp(bundleID: String, appName: String) {
        guard !bundleID.isEmpty else { return }
        let key = bundleID
        globalAppScores[key] = (globalAppScores[key] ?? 0) + 1.0
        scheduleSave()
    }

    /// Call whenever the user runs a dock pill / menu action in a given app context.
    func recordAction(_ action: String, inBundleID: String?) {
        guard !action.isEmpty else { return }
        let ctx = inBundleID ?? "_global"
        var map = perAppActions[ctx] ?? [:]
        map[action] = (map[action] ?? 0) + 1.0
        perAppActions[ctx] = map
        scheduleSave()
    }

    /// Records whether the user picked a menu action or an app for a given query.
    /// After ≥2 consistent picks the preference overrides heuristics.
    func recordQueryIntent(query: String, wasMenu: Bool) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.count >= 2 else { return }
        let delta = wasMenu ? 1.0 : -1.0
        queryIntent[q] = (queryIntent[q] ?? 0) + delta
        scheduleSave()
    }

    /// Returns positive if menu is preferred, negative if app is preferred.
    /// Returns nil if fewer than 2 consistent picks exist (not enough signal).
    func intentPreference(for query: String) -> Double? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let score = queryIntent[q], abs(score) >= 2.0 else { return nil }
        return score
    }

    /// Call whenever the user executes a non-trivial search query (≥2 chars, not pure whitespace).
    func recordQuery(_ query: String, inBundleID: String?) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.count >= 2 else { return }
        globalQueries[q] = (globalQueries[q] ?? 0) + 1.0
        if let bid = inBundleID {
            recordAction("query:\(q)", inBundleID: bid)
        }
        scheduleSave()
    }

    // MARK: - Ranked Suggestions

    /// Sorted bundle IDs by global usage score (highest first).
    func rankedAppBundleIDs(limit: Int = 20) -> [String] {
        Array(
            globalAppScores
                .sorted { $0.value > $1.value }
                .prefix(limit)
                .map { $0.key }
        )
    }

    /// Score for a single bundle ID (0 if never recorded).
    func score(forBundleID bundleID: String) -> Double {
        globalAppScores[bundleID] ?? 0
    }

    /// Learned score for a concrete action key. Blends global habit with app-local habit.
    func actionScore(_ action: String, inBundleID bundleID: String?) -> Double {
        let key = action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return 0 }
        var score = perAppActions["_global"]?[key] ?? 0
        if let bid = bundleID, let local = perAppActions[bid]?[key] {
            score += local * 2.5
        }
        return score
    }

    /// Menu-like rows have both a stable tracking key and a visible title.
    func blendedActionScore(
        trackingKey: String,
        visibleAction: String,
        inBundleID bundleID: String?
    ) -> Double {
        let visible = visibleAction.trimmingCharacters(in: .whitespacesAndNewlines)
        var score = actionScore(trackingKey, inBundleID: bundleID)
        if !visible.isEmpty, visible != trackingKey {
            score += actionScore(visible, inBundleID: bundleID) * 1.5
            score += actionScore(visible, inBundleID: nil) * 0.75
        }
        return score
    }

    /// Top actions for a given app context, blended with global actions.
    func rankedActions(inBundleID bundleID: String?, limit: Int = 12) -> [String] {
        var merged: [String: Double] = perAppActions["_global"] ?? [:]
        if let bid = bundleID, let appMap = perAppActions[bid] {
            for (k, v) in appMap { merged[k] = (merged[k] ?? 0) + v * 2 } // app-specific weighted higher
        }
        return Array(
            merged
                .filter { !$0.key.hasPrefix("query:") }
                .sorted { $0.value > $1.value }
                .prefix(limit)
                .map { $0.key }
        )
    }

    /// Top search queries, globally or filtered to a context.
    func rankedQueries(inBundleID bundleID: String? = nil, limit: Int = 8) -> [String] {
        var merged = globalQueries
        if let bid = bundleID, let appMap = perAppActions[bid] {
            for (k, v) in appMap where k.hasPrefix("query:") {
                let q = String(k.dropFirst("query:".count))
                merged[q] = (merged[q] ?? 0) + v * 2
            }
        }
        return Array(
            merged
                .sorted { $0.value > $1.value }
                .prefix(limit)
                .map { $0.key }
        )
    }

    // MARK: - Persistence

    private var saveWorkItem: DispatchWorkItem?

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.persist() }
        saveWorkItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: item)
    }

    private func persist() {
        UserDefaults.standard.set(globalAppScores, forKey: globalAppScoresKey)
        UserDefaults.standard.set(perAppActions,   forKey: perAppActionKey)
        UserDefaults.standard.set(globalQueries,   forKey: globalQueryKey)
        UserDefaults.standard.set(queryIntent,     forKey: queryIntentKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastSaveKey)
    }

    private func load() {
        globalAppScores = UserDefaults.standard.dictionary(forKey: globalAppScoresKey) as? [String: Double] ?? [:]
        perAppActions   = (UserDefaults.standard.dictionary(forKey: perAppActionKey) as? [String: [String: Double]]) ?? [:]
        globalQueries   = UserDefaults.standard.dictionary(forKey: globalQueryKey)   as? [String: Double] ?? [:]
        queryIntent     = UserDefaults.standard.dictionary(forKey: queryIntentKey)   as? [String: Double] ?? [:]
        applyTimeDecay()
    }

    /// Decays all scores by how much time has passed since last save.
    private func applyTimeDecay() {
        let lastSave = UserDefaults.standard.double(forKey: lastSaveKey)
        guard lastSave > 0 else { return }
        let elapsed = Date().timeIntervalSince1970 - lastSave
        guard elapsed > 3600 else { return } // skip if less than 1 hour
        let decayFactor = pow(0.5, elapsed / halfLifeSeconds)
        globalAppScores = globalAppScores.mapValues { $0 * decayFactor }
        perAppActions   = perAppActions.mapValues { $0.mapValues { $0 * decayFactor } }
        globalQueries   = globalQueries.mapValues { $0 * decayFactor }
        // Prune near-zero entries to keep storage lean
        let threshold = 0.01
        globalAppScores = globalAppScores.filter { $0.value > threshold }
        perAppActions   = perAppActions.mapValues { $0.filter { $0.value > threshold } }
        globalQueries   = globalQueries.filter { $0.value > threshold }
        // Intent scores decay but keep sign — remove only truly negligible entries
        queryIntent     = queryIntent.filter { abs($0.value) > threshold }
    }
}
