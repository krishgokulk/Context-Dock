// Context-Dock
//
// Telling "the app wrote this" from "somebody has edited this".
//
// A shipped plugin has to be able to change in a later build — a fixed script, a better icon —
// without stepping on a plugin the person has since edited in the Creator. Those two pull
// against each other, and a version number cannot settle it: the question is not which text is
// newer but whether the text on disk is still the app's own.
//
// So a seeded manifest carries a stamp of its own content. On the next launch: stamp matches
// the file → the app wrote this and nobody has touched it, safe to replace. Stamp missing or
// disagreeing with the file → somebody edited it, leave it alone and offer a reset instead.
//
// The stamp rides in `keywords` for the same reason supersession does: it is part of the
// manifest, survives the JSON a plugin is written as, and is filtered out of anything shown.

import Foundation

enum PluginShipped {
    static let prefix = "shipped:"

    /// A stamp of everything that makes this manifest what it is — the manifest minus its own
    /// stamp, so stamping is not itself a change that invalidates the stamp.
    static func stamp(for manifest: PluginManifest) -> String {
        var bare = manifest
        bare.keywords = manifest.keywords.filter { !$0.hasPrefix(prefix) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(bare) else { return "" }
        return String(format: "%08x", stableHash(data))
    }

    /// The stamp a manifest is carrying, if any.
    static func stamp(of manifest: PluginManifest) -> String? {
        manifest.keywords.first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    static func stamped(_ keywords: [String], with stamp: String) -> [String] {
        keywords.filter { !$0.hasPrefix(prefix) } + ["\(prefix)\(stamp)"]
    }

    /// The manifest as it will be written: its own stamp attached.
    static func stamping(_ manifest: PluginManifest) -> PluginManifest {
        var out = manifest
        out.keywords = stamped(manifest.keywords, with: stamp(for: manifest))
        return out
    }

    static func userVisibleKeywords(of manifest: PluginManifest) -> [String] {
        manifest.keywords.filter { !$0.hasPrefix(prefix) }
    }

    /// True when this file is still exactly what some build of the app wrote.
    static func isUntouched(_ installed: PluginManifest) -> Bool {
        guard let carried = stamp(of: installed) else { return false }
        return carried == stamp(for: installed)
    }

    /// Shipped plugins on disk that someone has edited. These are never overwritten; Settings
    /// offers a reset instead, which is the only way an edit is ever lost — by asking.
    static func editedShippedPlugins(installedIn root: URL) -> [String] {
        let shippedIDs = Set(PluginEssentials.all.map(\.id))
        return installedShipped(in: root)
            .filter { shippedIDs.contains($0.id) && !isUntouched($0) }
            .map(\.id)
            .sorted()
    }

    static func installedShipped(in root: URL) -> [PluginManifest] {
        let pluginsDir = root
            .appendingPathComponent("\(PluginEssentials.packID)/plugins", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: pluginsDir, includingPropertiesForKeys: nil)
        else { return [] }
        return entries.compactMap { dir in
            let url = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(PluginManifest.self, from: data)
        }
    }

    /// FNV-1a. `Hasher` is seeded per process, so its value differs between launches — which
    /// would make every plugin look edited on the next start.
    private static func stableHash(_ data: Data) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in data {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }
}
