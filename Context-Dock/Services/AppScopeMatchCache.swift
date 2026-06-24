// AppScopeMatchCache.swift
// Context-Dock
//
// Memoizes per-app data needed by installed-app scope matching.
//
// `installedAppMenuTarget` runs on the search hot path — every keystroke in
// Global Context. Resolving a bundle identifier via `Bundle(url:)` reads
// Info.plist from disk, and alias building re-normalizes the same strings on
// every call. Neither result ever changes for an installed app while the app
// is running, so resolve once per app and reuse.

import AppKit
import Foundation

@MainActor
final class AppScopeMatchCache {
    static let shared = AppScopeMatchCache()

    struct AliasEntry {
        let normalizedName: String
        let aliases: [String]
    }

    /// Empty string marks a path that resolved before but has no usable bundle id,
    /// so missing apps don't re-hit the disk on every keystroke.
    private var bundleIdByPath: [String: String] = [:]
    private var aliasEntryByKey: [String: AliasEntry] = [:]

    private init() {}

    func bundleId(forAppPath path: String) -> String? {
        if let cached = bundleIdByPath[path] {
            return cached.isEmpty ? nil : cached
        }
        let resolved = Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier ?? ""
        bundleIdByPath[path] = resolved
        return resolved.isEmpty ? nil : resolved
    }

    func aliasEntry(
        bundleId: String,
        appName: String,
        build: () -> AliasEntry
    ) -> AliasEntry {
        let key = "\(bundleId)|\(appName)"
        if let cached = aliasEntryByKey[key] { return cached }
        let entry = build()
        aliasEntryByKey[key] = entry
        return entry
    }

    /// Resolve bundle ids off the main thread so the first keystroke after the
    /// app list loads doesn't pay hundreds of Info.plist reads.
    func prewarm(appPaths: [String]) {
        let missing = appPaths.filter { bundleIdByPath[$0] == nil }
        guard !missing.isEmpty else { return }
        Task.detached(priority: .utility) {
            let resolved = missing.map { path in
                (path, Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier ?? "")
            }
            await MainActor.run {
                for (path, bundleId) in resolved where self.bundleIdByPath[path] == nil {
                    self.bundleIdByPath[path] = bundleId
                }
            }
        }
    }
}
