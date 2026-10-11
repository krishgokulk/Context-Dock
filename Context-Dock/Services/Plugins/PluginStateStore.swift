// Context-Dock
//
// What a plugin remembers between runs.
//
// A converter's currencies, a timer's target, a board's chosen branch: things the person set
// by tapping, that a data script needs on its next run and a view needs before the script
// has answered. The manifest declares the keys and their starting values under `state`;
// this keeps the current values, one file per plugin, and merges the defaults underneath so
// a key the author added later is never missing.
//
// Two ways in: the `set` built-in action (`{ "type": "set", "key": "from" }` — the tapped
// value lands in that key) and a script action whose JSON output carries a `"state"`
// object, which is merged. Both are followed by a data refresh, so the row that shows the
// result is never a tap behind.

import Combine
import Foundation

@MainActor
final class PluginStateStore: ObservableObject {
    static let shared = PluginStateStore(root: PluginInstaller.userRoot.appendingPathComponent("state"))

    @Published private(set) var states: [String: [String: PluginValue]] = [:]
    private let root: URL

    init(root: URL) {
        self.root = root
    }

    /// The plugin's current state with the manifest's defaults underneath. The defaults are
    /// the floor: a key the person never touched reads as declared.
    func state(for manifest: PluginManifest) -> [String: PluginValue] {
        Self.merged(defaults: manifest.state, current: load(manifest.id))
    }

    /// Pure: what `state(for:)` answers, kept separate so the rule can be held without a disk.
    nonisolated static func merged(
        defaults: [String: PluginValue], current: [String: PluginValue]
    ) -> [String: PluginValue] {
        defaults.merging(current) { _, stored in stored }
    }

    func set(_ key: String, to value: PluginValue, for manifest: PluginManifest) {
        var current = load(manifest.id)
        current[key] = value
        save(current, for: manifest.id)
    }

    func merge(_ patch: [String: PluginValue], for manifest: PluginManifest) {
        guard !patch.isEmpty else { return }
        var current = load(manifest.id)
        for (key, value) in patch { current[key] = value }
        save(current, for: manifest.id)
    }

    func reset(for manifest: PluginManifest) {
        states[manifest.id] = nil
        try? FileManager.default.removeItem(at: file(for: manifest.id))
    }

    // MARK: Disk

    private func file(for pluginID: String) -> URL {
        root.appendingPathComponent("\(pluginID).json")
    }

    private func load(_ pluginID: String) -> [String: PluginValue] {
        if let cached = states[pluginID] { return cached }
        let url = file(for: pluginID)
        guard let data = try? Data(contentsOf: url),
            let stored = try? JSONDecoder().decode([String: PluginValue].self, from: data)
        else {
            states[pluginID] = [:]
            return [:]
        }
        states[pluginID] = stored
        return stored
    }

    private func save(_ state: [String: PluginValue], for pluginID: String) {
        states[pluginID] = state
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: file(for: pluginID), options: .atomic)
        } catch {
            // The in-memory value still stands for this session; only the relaunch loses it.
            NSLog("Context-Dock: could not save state for plugin \(pluginID) — \(error)")
        }
    }
}
