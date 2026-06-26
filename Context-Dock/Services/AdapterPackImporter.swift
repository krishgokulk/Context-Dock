//  AdapterPackImporter.swift
//  Context-Dock
//
//  Imports App Adapter Packs — a folder / .adapterpack / .zip / .json that
//  installs support for an app (System Settings, Finder, Safari, VSCode…) with
//  hundreds of actions in one shot. A pack is metadata (adapter.json) + actions
//  (actions.json); a single .json file (an exported AppAdapter or a combined
//  pack) is also accepted. Parsing happens once at import; the dock then searches
//  the in-memory index, never the JSON.

import AppKit
import Foundation

// MARK: - Pack schema (decode only)

struct AdapterPackManifest: Decodable {
    var schemaVersion: Int?
    var name: String
    var bundleId: String
    var icon: String?
    var version: String?
    var author: String?
    var description: String?
}

/// Lenient action DTO — accepts the pack schema (title/keywords/deepLink/url/
/// fallbackSearch) and the native AdapterAction schema (name/triggers/urlScheme).
struct AdapterPackActionDTO: Decodable {
    var id: String
    var title: String?
    var name: String?
    var category: String?
    var icon: String?
    var keywords: [String]?
    var triggers: [String]?
    var type: String?
    var url: String?
    var urlScheme: String?
    var fallbackSearch: String?
    var description: String?
    var menuPath: [String]?
    var script: String?
    var scriptFile: String?
    var shortcutName: String?
    var aiPromptTemplate: String?
    var cliToolCommand: String?
    var requiresApproval: Bool?
    var isDestructive: Bool?
    var accentColor: String?
}

private struct ActionsWrapper: Decodable { var actions: [AdapterPackActionDTO] }

private struct CombinedPack: Decodable {
    var name: String
    var bundleId: String
    var icon: String?
    var version: String?
    var author: String?
    var description: String?
    var schemaVersion: Int?
    var actions: [AdapterPackActionDTO]
}

// MARK: - Preview

struct AdapterPackPreview: Identifiable {
    let id = UUID()
    let manifest: AdapterPackManifest
    let adapter: AppAdapter
    let sourceURL: URL

    var actionCount: Int { adapter.actions.count }
    var categories: [String] {
        Array(Set(adapter.actions.compactMap { $0.category?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })).sorted()
    }
}

enum AdapterPackImportError: LocalizedError {
    case unreadable
    case invalidSchema(String)
    case noActions

    var errorDescription: String? {
        switch self {
        case .unreadable: return "Couldn't read the adapter pack."
        case .invalidSchema(let why): return "Invalid adapter pack: \(why)"
        case .noActions: return "The adapter pack contains no actions."
        }
    }
}

// MARK: - Importer

@MainActor
final class AdapterPackImporter {
    static let shared = AdapterPackImporter()
    private init() {}

    /// NSOpenPanel for an adapter pack. Accepts a .adapterpack folder, a .zip, or
    /// a .json (adapter.json / combined export). No allowedFileTypes filter — it
    /// makes plain `.adapterpack` folders un-selectable (the panel descends into
    /// them); selection is validated in loadPreview instead.
    func pickPack() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Import Adapter Pack"
        panel.message = "Choose a .adapterpack folder, a .zip, or an adapter.json"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    func loadPreview(from url: URL) throws -> AdapterPackPreview {
        let (manifest, actions) = try parse(url)
        guard !actions.isEmpty else { throw AdapterPackImportError.noActions }
        guard !manifest.bundleId.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AdapterPackImportError.invalidSchema("missing bundleId")
        }
        let adapter = AppAdapter(
            id: manifest.bundleId,
            appName: manifest.name,
            bundleId: manifest.bundleId,
            icon: manifest.icon ?? "app.dashed",
            isEnabled: true,
            isBuiltIn: false,
            actions: actions)
        return AdapterPackPreview(manifest: manifest, adapter: adapter, sourceURL: url)
    }

    @discardableResult
    func install(_ preview: AdapterPackPreview) async -> Bool {
        await AppAdapterManager.shared.installImportedAdapter(preview.adapter)
    }

    // MARK: - Parse

    private func parse(_ url: URL) throws -> (AdapterPackManifest, [AdapterAction]) {
        let fm = FileManager.default
        var location = url
        if url.pathExtension.lowercased() == "zip" {
            location = try extractZip(url)
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: location.path, isDirectory: &isDir) else {
            throw AdapterPackImportError.unreadable
        }

        if isDir.boolValue {
            let root = try packRoot(location)
            let manData = try Data(contentsOf: root.appendingPathComponent("adapter.json"))
            let manifest = try JSONDecoder().decode(AdapterPackManifest.self, from: manData)
            let actData = try Data(contentsOf: root.appendingPathComponent("actions.json"))
            return (manifest, try decodeActions(actData))
        }

        // Picked adapter.json or actions.json directly → treat the parent as the pack.
        let pickedName = location.lastPathComponent.lowercased()
        if pickedName == "adapter.json" || pickedName == "actions.json" {
            let parent = location.deletingLastPathComponent()
            if fm.fileExists(atPath: parent.appendingPathComponent("adapter.json").path),
                fm.fileExists(atPath: parent.appendingPathComponent("actions.json").path) {
                let manData = try Data(contentsOf: parent.appendingPathComponent("adapter.json"))
                let manifest = try JSONDecoder().decode(AdapterPackManifest.self, from: manData)
                let actData = try Data(contentsOf: parent.appendingPathComponent("actions.json"))
                return (manifest, try decodeActions(actData))
            }
        }

        // Single .json — an exported AppAdapter, a combined pack, or bare actions.
        let data = try Data(contentsOf: location)
        if let appAdapter = try? JSONDecoder().decode(AppAdapter.self, from: data),
            !appAdapter.bundleId.isEmpty, !appAdapter.actions.isEmpty {
            let manifest = AdapterPackManifest(
                schemaVersion: 1, name: appAdapter.appName, bundleId: appAdapter.bundleId,
                icon: appAdapter.icon, version: nil, author: nil, description: nil)
            return (manifest, appAdapter.actions)
        }
        if let combined = try? JSONDecoder().decode(CombinedPack.self, from: data) {
            let manifest = AdapterPackManifest(
                schemaVersion: combined.schemaVersion, name: combined.name,
                bundleId: combined.bundleId, icon: combined.icon, version: combined.version,
                author: combined.author, description: combined.description)
            return (manifest, combined.actions.compactMap(mapAction))
        }
        throw AdapterPackImportError.invalidSchema("not an adapter or pack JSON")
    }

    private func decodeActions(_ data: Data) throws -> [AdapterAction] {
        if let arr = try? JSONDecoder().decode([AdapterPackActionDTO].self, from: data) {
            return arr.compactMap(mapAction)
        }
        if let wrap = try? JSONDecoder().decode(ActionsWrapper.self, from: data) {
            return wrap.actions.compactMap(mapAction)
        }
        throw AdapterPackImportError.invalidSchema("actions.json is not an action array")
    }

    private func mapAction(_ dto: AdapterPackActionDTO) -> AdapterAction? {
        let name = (dto.title ?? dto.name ?? dto.id).trimmingCharacters(in: .whitespaces)
        guard !dto.id.isEmpty, !name.isEmpty else { return nil }
        var triggers = dto.keywords ?? dto.triggers ?? []
        if let fb = dto.fallbackSearch, !fb.isEmpty { triggers.append(fb) }
        return AdapterAction(
            id: dto.id, name: name, icon: dto.icon ?? "bolt",
            description: dto.description ?? "", triggers: triggers, category: dto.category,
            type: mapType(dto.type), menuPath: dto.menuPath, script: dto.script,
            scriptFile: dto.scriptFile, urlScheme: dto.url ?? dto.urlScheme,
            cliToolCommand: dto.cliToolCommand, shortcutName: dto.shortcutName,
            aiPromptTemplate: dto.aiPromptTemplate,
            requiresApproval: dto.requiresApproval ?? false,
            isDestructive: dto.isDestructive ?? false, accentColor: dto.accentColor)
    }

    private func mapType(_ raw: String?) -> AdapterActionType {
        switch (raw ?? "deepLink").lowercased() {
        case "deeplink", "urlscheme", "url": return .urlScheme
        case "openitem", "openfile", "open": return .openItem
        case "shell", "bash": return .shell
        case "applescript": return .applescript
        case "jxa": return .jxa
        case "menubar", "menu": return .menubar
        case "shortcut": return .shortcut
        case "aiprompt": return .aiPrompt
        case "scriptfile": return .scriptFile
        case "pagejs", "userscript": return .pageJS
        case "clitool": return .cliTool
        default: return .urlScheme
        }
    }

    private func extractZip(_ zipURL: URL) throws -> URL {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DoraXAdapterPack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-o", "-q", zipURL.path, "-d", temp.path]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw AdapterPackImportError.unreadable }
        return temp
    }

    /// Find the directory that actually holds adapter.json (zips often wrap the
    /// pack in a subfolder).
    private func packRoot(_ dir: URL) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent("adapter.json").path) { return dir }
        let kids = (try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        for kid in kids
        where (try? kid.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if fm.fileExists(atPath: kid.appendingPathComponent("adapter.json").path) { return kid }
        }
        throw AdapterPackImportError.invalidSchema("adapter.json not found in pack")
    }
}
