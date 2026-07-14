//  RoutePreferenceStore.swift
//  Context-Dock
//
//  Explicit, user-stated route preferences for DoraX Action Chat ("always use TextEdit
//  for new text files", "avoid AX for Safari"). Distinct from RouteConfidenceStore, which
//  LEARNS silently from outcomes — this is what the user DIRECTLY asked for.
//
//  Local-only JSON. Never sent to any AI provider. Preferences only reorder candidates
//  WITHIN a hard safety tier (the resolver clamps the combined adjustment below the tier
//  gap) and never bypass approval — a preferred write action still asks first.

import Foundation

struct RoutePreference: Codable {
    enum Strength: String, Codable { case preferred, avoid }

    /// Empty string = applies to every intent for the given app/route (app-wide rule).
    var intentKey: String
    var bundleID: String?
    var route: String?
    var strength: Strength
    var created: Date
    var updated: Date
}

@MainActor
final class RoutePreferenceStore {
    static let shared = RoutePreferenceStore()

    private var prefs: [RoutePreference] = []

    private let fileURL: URL = {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("DoraX/RoutePreferences.json", isDirectory: false)
    }()

    private init() { load() }

    /// Upsert a preference by its (intentKey, bundleID, route) identity.
    func set(intentKey: String, bundleID: String?, route: String?, strength: RoutePreference.Strength) {
        let now = Date()
        if let idx = prefs.firstIndex(where: {
            $0.intentKey == intentKey && $0.bundleID == bundleID && $0.route == route
        }) {
            prefs[idx].strength = strength
            prefs[idx].updated = now
        } else {
            prefs.append(
                RoutePreference(
                    intentKey: intentKey, bundleID: bundleID, route: route,
                    strength: strength, created: now, updated: now))
        }
        save()
    }

    /// Strength for a candidate: an `avoid` rule wins over `preferred` if both match (safer
    /// to honor a "don't"). A rule matches when its non-nil fields all match the candidate,
    /// and its intentKey is empty (app-wide) or equal to the candidate's intent.
    func strength(intentKey: String, bundleID: String, route: String) -> RoutePreference.Strength? {
        // The stated preference is usually worded differently from the live query, so match
        // on token SUBSET ("text-file" pref applies to a "create-file-text" query) rather
        // than exact equality. Empty pref intentKey = app-wide.
        let candTokens = Self.tokens(intentKey)
        let matches = prefs.filter { pref in
            (pref.intentKey.isEmpty || Self.tokens(pref.intentKey).isSubset(of: candTokens))
                && (pref.bundleID == nil || pref.bundleID == bundleID)
                && (pref.route == nil || pref.route == route)
        }
        if matches.contains(where: { $0.strength == .avoid }) { return .avoid }
        if matches.contains(where: { $0.strength == .preferred }) { return .preferred }
        return nil
    }

    private static func tokens(_ key: String) -> Set<String> {
        Set(key.split(separator: "-").map(String.init))
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([RoutePreference].self, from: data)
        else { return }
        prefs = decoded
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(prefs) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
