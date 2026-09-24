// Context-Dock
//
// Writing a manifest to disk is what makes it a plugin. Until then PluginRegistry cannot see
// it, so no host can show it and nothing can run it — which is the whole gap between "this
// converts cleanly" and "this is installed".
//
// The layout is PluginPack's, not a new one: <root>/<pack>/pack.json plus
// plugins/<id>/manifest.json. A plugin written any other way would load nowhere.

import Foundation

enum PluginInstallError: Error, Equatable {
    /// Named plugins do not validate. Installing them would produce a plugin that cannot
    /// work, discovered later as a registry flag rather than here where someone is looking.
    case doesNotValidate([String])
    case write(String)
}

enum PluginInstaller {
    /// Where the user's own plugins live. The registry already reads this root.
    static var userRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Context-Dock/plugins", isDirectory: true)
    }

    @discardableResult
    static func install(_ manifests: [PluginManifest], into root: URL,
                        packID: String, packName: String) throws -> URL
    {
        // Validate everything before writing anything: a half-written pack is worse than a
        // refusal, because it loads and misbehaves.
        let broken = manifests.filter {
            !PluginSchema.validate($0).filter { $0.severity == .error }.isEmpty
        }
        guard broken.isEmpty else {
            throw PluginInstallError.doesNotValidate(broken.map(\.id))
        }

        let folder = root.appendingPathComponent(packID, isDirectory: true)
        let pluginsDir = folder.appendingPathComponent("plugins", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)

            let info: [String: Any] = [
                "id": packID, "name": packName, "author": "You", "version": "1.0.0",
                "icon": "puzzlepiece.extension",
                "description": "Plugins installed from this Mac.",
            ]
            try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("pack.json"))

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            for manifest in manifests {
                // One folder per id. Re-installing replaces that folder's manifest rather
                // than adding a second copy — PluginPack keeps the first plugin it sees for
                // an id and silently drops the rest, so a duplicate is an invisible loss.
                let dir = pluginsDir.appendingPathComponent(manifest.id, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try encoder.encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
            }
        } catch let error as PluginInstallError {
            throw error
        } catch {
            throw PluginInstallError.write(error.localizedDescription)
        }
        return folder
    }

    static func remove(pluginID: String, from packFolder: URL) throws {
        let dir = packFolder.appendingPathComponent("plugins/\(pluginID)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        do {
            try FileManager.default.removeItem(at: dir)
        } catch {
            throw PluginInstallError.write(error.localizedDescription)
        }
    }
}
