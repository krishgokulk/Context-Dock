// Context-Dock/Services/Plugins/PluginRegistry.swift
// Context-Dock
//
// Every installed plugin, from every pack root, in one list. Roots are searched in order
// and a later root's newer pack replaces an earlier one's plugin of the same id — that is
// how a user-installed update shadows the bundled Essentials copy. Enabled is the default;
// the state file remembers only what the user turned off.

import Foundation
import Combine

struct InstalledPlugin: Identifiable, Equatable {
    let manifest: PluginManifest
    let packID: String
    let folder: URL
    var isEnabled: Bool
    var hasErrors: Bool

    var id: String { manifest.id }
}

@MainActor
final class PluginRegistry: ObservableObject {
    static let shared: PluginRegistry = {
        var roots: [URL] = []
        if let bundled = Bundle.main.url(forResource: "Essentials", withExtension: nil, subdirectory: "Plugins") {
            roots.append(bundled.deletingLastPathComponent())
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Context-Dock/plugins", isDirectory: true)
        roots.append(support)
        return PluginRegistry(roots: roots, stateFile: support.appendingPathComponent("state.json"))
    }()

    private struct State: Codable { var disabled: Set<String> = [] }

    let roots: [URL]
    let stateFile: URL
    private var state = State()

    @Published private(set) var packs: [PluginPack] = []
    @Published private(set) var plugins: [InstalledPlugin] = []

    init(roots: [URL], stateFile: URL) {
        self.roots = roots
        self.stateFile = stateFile
        reload()
    }

    var enabledPlugins: [InstalledPlugin] {
        plugins.filter { $0.isEnabled && !$0.hasErrors }
    }

    func plugin(id: String) -> InstalledPlugin? {
        plugins.first { $0.id == id }
    }

    func folder(forPlugin id: String) -> URL? {
        plugin(id: id)?.folder
    }

    func reload() {
        // A missing or corrupt state file degrades to "nothing disabled" rather than
        // crashing or wiping the user's choices on a transient read failure.
        state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: stateFile))) ?? State()

        var packsByID: [String: PluginPack] = [:]
        var order: [String] = []
        for root in roots {
            let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]))?
                .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
            for folder in folders {
                guard let pack = try? PluginPack.load(from: folder) else { continue }
                if let existing = packsByID[pack.info.id], !pack.isNewer(than: existing) { continue }
                if packsByID[pack.info.id] == nil { order.append(pack.info.id) }
                packsByID[pack.info.id] = pack
            }
        }
        packs = order.compactMap { packsByID[$0] }

        var seen: Set<String> = []
        var installed: [InstalledPlugin] = []
        for pack in packs {
            for manifest in pack.plugins where !seen.contains(manifest.id) {
                seen.insert(manifest.id)
                // The plugin's directory is not guaranteed to be named after its id (see
                // PluginPackTests: `sonos-now-playing` lives in a directory named
                // `now-playing`), so this uses what PluginPack itself recorded while
                // walking the pack rather than re-deriving or re-reading anything here.
                // `pack.folders` and `pack.plugins` are populated together for every kept
                // manifest, so the lookup always hits; the fallback is unreachable in
                // practice and only avoids force-unwrapping a dictionary lookup.
                let folder = pack.folders[manifest.id] ?? pack.folder
                let errors = PluginSchema.hasErrors(pack.diagnostics[manifest.id] ?? [])
                installed.append(InstalledPlugin(
                    manifest: manifest, packID: pack.info.id, folder: folder,
                    isEnabled: !state.disabled.contains(manifest.id), hasErrors: errors))
            }
        }
        plugins = installed
    }

    func setEnabled(_ enabled: Bool, pluginID: String) {
        if enabled { state.disabled.remove(pluginID) } else { state.disabled.insert(pluginID) }
        if let idx = plugins.firstIndex(where: { $0.id == pluginID }) {
            plugins[idx].isEnabled = enabled
        }
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateFile, options: .atomic)
        }
    }
}
