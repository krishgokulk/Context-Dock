// SearchPresetMerge.swift
// Context-Dock
//
// Global Commands answer to their keywords through a path that bypasses the scorer. That path
// used to *replace* the result list: match one preset on "screenshot" and every app, file and
// menu for that query disappeared, which is the second defect in #15.
//
// A preset is a strong match, not the only match. It leads, and everything else keeps its
// place behind it.

import Foundation

enum SearchPresetMerge {

    /// Presets first, then everything the scorer found, with nothing listed twice.
    ///
    /// Identity is the row's `id` — the same key the result list is rebuilt from — so a
    /// preset and a scored row for the same command collapse into one, and the preset wins
    /// because it is the one that matched by keyword.
    static func merge(
        presets: [SearchResult],
        scored: [SearchResult],
        limit: Int? = nil
    ) -> [SearchResult] {
        guard !presets.isEmpty else {
            guard let limit else { return scored }
            return Array(scored.prefix(limit))
        }

        var seen = Set(presets.map(\.id))
        var merged = presets
        for result in scored where !seen.contains(result.id) {
            seen.insert(result.id)
            merged.append(result)
        }
        guard let limit else { return merged }
        return Array(merged.prefix(limit))
    }
}
