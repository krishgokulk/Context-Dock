// Context-Dock
//
// Which legacy item an installed plugin stands in for.
//
// Migration converts a Global Command or Global Extension into a plugin, but installing one
// does not delete the original — the old path keeps working until the Phase 8 cut-over. Both
// would then answer to the same name in search, and one of the two rows would quietly be the
// old implementation. So an installed plugin records what it replaces, and the launcher hides
// that original for exactly as long as the plugin is installed. Uninstall it and the original
// is back: nothing was ever deleted.
//
// The stamp rides in `keywords` because that is already part of the manifest and survives the
// JSON a plugin is written as. It is filtered out of anything a person reads.

import Foundation

enum PluginSupersession {
    static let prefix = "migrated-from:"

    static func keyword(forLegacyID id: String) -> String { prefix + id }

    /// Every legacy id covered by these plugins.
    static func legacyIDs(in manifests: [PluginManifest]) -> Set<String> {
        Set(manifests.flatMap { manifest in
            manifest.keywords.compactMap { keyword in
                keyword.hasPrefix(prefix) ? String(keyword.dropFirst(prefix.count)) : nil
            }
        })
    }

    static func supersedes(legacyID: String, covered: Set<String>) -> Bool {
        covered.contains(legacyID)
    }

    /// The keywords a person wrote, without the bookkeeping.
    static func userVisibleKeywords(of manifest: PluginManifest) -> [String] {
        manifest.keywords.filter { !$0.hasPrefix(prefix) }
    }
}
