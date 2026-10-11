// Context-Dock/Services/Plugins/PluginPack.swift
// Context-Dock
//
// A pack is a folder:
//   <pack>/pack.json
//   <pack>/plugins/<id>/manifest.json   (+ scripts, skills beside it)
// Loading never throws for one bad plugin — that plugin is reported and the rest load.
// Only a missing or unreadable pack.json makes the folder not a pack.

import Foundation

struct PluginPackInfo: Codable, Equatable {
    var id: String
    var name: String
    var author: String
    var version: String
    var icon: String
    var description: String
    var permissions: [String]
    var minAppVersion: String?

    enum CodingKeys: String, CodingKey { case id, name, author, version, icon, description, permissions, minAppVersion }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? PluginManifest.defaultIcon
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        permissions = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
        minAppVersion = try c.decodeIfPresent(String.self, forKey: .minAppVersion)
    }
}

enum PluginPackError: Error, Equatable {
    case missingPackJSON(URL)
    case badPackJSON(URL, String)
}

struct PluginPack: Equatable {
    let info: PluginPackInfo
    let folder: URL
    let plugins: [PluginManifest]
    let diagnostics: [String: [PluginDiagnostic]]
    let loadErrors: [String]
    /// Plugin id → the directory that held its manifest.json. The directory name is not
    /// guaranteed to match the id (see `PluginPackTests.loadsPlugins`, `now-playing` holding
    /// `sonos-now-playing`), so this is recorded while walking rather than assumed later.
    let folders: [String: URL]

    static func load(from folder: URL) throws -> PluginPack {
        let packURL = folder.appendingPathComponent("pack.json")
        guard FileManager.default.fileExists(atPath: packURL.path) else {
            throw PluginPackError.missingPackJSON(folder)
        }
        let info: PluginPackInfo
        do {
            info = try JSONDecoder().decode(PluginPackInfo.self, from: Data(contentsOf: packURL))
        } catch {
            throw PluginPackError.badPackJSON(packURL, String(describing: error))
        }

        var plugins: [PluginManifest] = []
        var diagnostics: [String: [PluginDiagnostic]] = [:]
        var loadErrors: [String] = []
        var folders: [String: URL] = [:]
        var seenIds = Set<String>()

        let pluginsDir = folder.appendingPathComponent("plugins")
        let pluginsDirExists = FileManager.default.fileExists(atPath: pluginsDir.path)
        let entries: [URL]
        if pluginsDirExists {
            do {
                entries = try FileManager.default.contentsOfDirectory(at: pluginsDir, includingPropertiesForKeys: nil)
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            } catch {
                loadErrors.append("plugins/: \(error.localizedDescription)")
                entries = []
            }
        } else {
            entries = []
        }

        for dir in entries {
            let manifestURL = dir.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }
            do {
                let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: manifestURL))
                if seenIds.contains(manifest.id) {
                    loadErrors.append("Duplicate plugin id '\(manifest.id)' in \(dir.lastPathComponent), skipped")
                } else {
                    seenIds.insert(manifest.id)
                    plugins.append(manifest)
                    diagnostics[manifest.id] = PluginSchema.validate(manifest)
                    folders[manifest.id] = dir
                }
            } catch {
                loadErrors.append("\(dir.lastPathComponent)/manifest.json: \(error.localizedDescription)")
            }
        }

        return PluginPack(info: info, folder: folder, plugins: plugins, diagnostics: diagnostics, loadErrors: loadErrors, folders: folders)
    }

    func isNewer(than other: PluginPack) -> Bool {
        Self.compareVersions(info.version, other.info.version) == .orderedDescending
    }

    /// "1.10.0" > "1.9.0"; "1.0" == "1.0.0"; missing components read as 0.
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        var x = parts(a), y = parts(b)
        let n = max(x.count, y.count)
        x += Array(repeating: 0, count: n - x.count)
        y += Array(repeating: 0, count: n - y.count)
        for (p, q) in zip(x, y) where p != q { return p < q ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }
}
