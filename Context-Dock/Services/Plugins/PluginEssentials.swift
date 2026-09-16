// Context-Dock
//
// The plugins the app ships with. These are AUTHORED — written as manifests the way a plugin
// author would write them — not converted from the old Global Commands. That is the point of
// them: they are the first honest test of whether the format is pleasant to write in, and
// whatever is awkward here will be awkward for everybody else.
//
// They are seeded onto disk rather than bundled as a resource folder, so they live in the same
// place every other plugin does and can be read, edited or deleted by hand. Seeding never
// overwrites an edit: a pack that rewrites itself at every launch is a pack nobody can change.

import Foundation

enum PluginEssentials {
    static let packID = "essentials"
    static let packName = "Essentials"

    /// Put the Mac to sleep.
    ///
    /// The whole plugin, and worth reading as a measure of the format: eleven lines of JSON
    /// for something that needed a `SystemCommand` record, a registry entry and a row in the
    /// dock's own switch before.
    ///
    /// No `views`. A plugin with a `primaryAction` and no panel is a one-shot: ⏎ runs it.
    /// `risk: medium` because it interrupts whatever the machine is doing — `read` would run
    /// it the moment a fuzzy match put it under the cursor and somebody pressed return.
    static let sleepJSON = """
    {
      "id": "sleep",
      "name": "Sleep",
      "icon": "moon.fill",
      "description": "Put this Mac to sleep.",
      "keywords": ["sleep", "suspend"],
      "inputs": [],
      "actions": {
        "sleep": {
          "type": "bash",
          "script": "pmset sleepnow",
          "title": "Sleep now",
          "risk": "medium",
          "success": { "title": "Sleeping", "message": "" }
        }
      },
      "primaryAction": "sleep"
    }
    """

    static var all: [PluginManifest] { [decode(sleepJSON)].compactMap { $0 } }

    /// Write the shipped plugins where the registry reads them, skipping any whose manifest
    /// is already on disk — an edited one stays edited, and a deleted one stays deleted until
    /// the app is reinstalled.
    static func seed(into root: URL) throws {
        let folder = root.appendingPathComponent(packID, isDirectory: true)
        let pluginsDir = folder.appendingPathComponent("plugins", isDirectory: true)
        let missing = all.filter { manifest in
            !FileManager.default.fileExists(
                atPath: pluginsDir
                    .appendingPathComponent("\(manifest.id)/manifest.json").path)
        }
        guard !missing.isEmpty else { return }
        try PluginInstaller.install(missing, into: root, packID: packID, packName: packName)
    }

    @MainActor
    static func seedIfNeeded() {
        do {
            try seed(into: PluginInstaller.userRoot)
        } catch {
            // A failure here costs the shipped plugins, not the app. The Plugins page shows
            // what actually loaded, which is the honest place to notice.
            NSLog("Context-Dock: could not seed the Essentials plugins — \(error)")
        }
    }

    private static func decode(_ json: String) -> PluginManifest? {
        try? JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    }
}

/// What choosing a plugin does.
enum PluginLaunchBehaviour: Equatable {
    /// Show its panel — the richer surface, and it contains the actions anyway.
    case openPanel
    /// Run this action. A plugin with no panel is a one-shot; opening an empty window for it
    /// would be a worse answer than doing the thing.
    case run(String)
    /// Neither: an agent-only plugin, or one whose author declared nothing to show or do.
    case nothing
}

enum PluginLaunch {
    static func behaviour(for manifest: PluginManifest) -> PluginLaunchBehaviour {
        if manifest.views.panel != nil || manifest.views.window != nil { return .openPanel }
        if let primary = manifest.primaryAction, manifest.actions[primary] != nil {
            return .run(primary)
        }
        return .nothing
    }
}
