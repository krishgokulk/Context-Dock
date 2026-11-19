// Context-Dock/Services/Plugins/DoraxPackV2.swift
// Context-Dock
//
// The canonical .doraxpack v2 folder format. A .doraxpack is a directory:
//
//   MyPack.doraxpack/
//   ├── pack.json          — metadata, capabilities, cli_tools, mcp_servers, extension_hooks
//   ├── AGENT.md           — persona, rules, domain knowledge (optional)
//   ├── modes.json         — declarative operating modes (optional)
//   ├── skills/
//   │   └── skill-name/
//   │       └── SKILL.md   — reusable skill instructions
//   ├── scripts/           — executable AppleScript, JXA, bash
//   └── page_scripts/      — browser extension hooks for Safari tabs
//
// DoraxPackV2Loader reads the folder and produces a DoraxPackV2.
// DoraxPackV2.toPluginManifest() converts to the existing PluginManifest
// so StorePackInstaller can bind it without duplicating registration logic.

import Foundation

// MARK: - pack.json schema

struct DoraxPackMetadata: Codable, Equatable {
    var formatVersion: Int
    var id: String
    var name: String
    var version: String
    var icon: String
    var description: String
    var bundleId: String?
    var keywords: [String]
    var capabilities: [PluginPackCapability]
    var cliTools: [DoraxCLITool]?
    var mcpServers: [DoraxMCPServer]?
    var extensionHooks: [DoraxExtensionHook]?

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case id, name, version, icon, description
        case bundleId = "bundle_id"
        case keywords, capabilities
        case cliTools = "cli_tools"
        case mcpServers = "mcp_servers"
        case extensionHooks = "extension_hooks"
    }

    init(
        formatVersion: Int = 2,
        id: String,
        name: String,
        version: String = "2.0.0",
        icon: String = "puzzlepiece.extension",
        description: String = "",
        bundleId: String? = nil,
        keywords: [String] = [],
        capabilities: [PluginPackCapability] = [],
        cliTools: [DoraxCLITool]? = nil,
        mcpServers: [DoraxMCPServer]? = nil,
        extensionHooks: [DoraxExtensionHook]? = nil
    ) {
        self.formatVersion = formatVersion
        self.id = id; self.name = name; self.version = version
        self.icon = icon; self.description = description
        self.bundleId = bundleId; self.keywords = keywords
        self.capabilities = capabilities
        self.cliTools = cliTools; self.mcpServers = mcpServers
        self.extensionHooks = extensionHooks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "1.0.0"
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "puzzlepiece.extension"
        let desc = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        description = desc.isEmpty ? name : desc
        bundleId = try c.decodeIfPresent(String.self, forKey: .bundleId)
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        capabilities = try c.decodeIfPresent([PluginPackCapability].self, forKey: .capabilities) ?? []
        cliTools = try c.decodeIfPresent([DoraxCLITool].self, forKey: .cliTools)
        mcpServers = try c.decodeIfPresent([DoraxMCPServer].self, forKey: .mcpServers)
        extensionHooks = try c.decodeIfPresent([DoraxExtensionHook].self, forKey: .extensionHooks)
    }
}

struct DoraxCLITool: Codable, Equatable {
    var name: String
    var binary: String
    var description: String

    init(name: String, binary: String, description: String = "") {
        self.name = name; self.binary = binary; self.description = description
    }
}

struct DoraxMCPServer: Codable, Equatable {
    var name: String
    var transport: String
    var command: String?
    var url: String?
    var description: String

    init(name: String, transport: String = "stdio", command: String? = nil,
         url: String? = nil, description: String = "") {
        self.name = name; self.transport = transport
        self.command = command; self.url = url; self.description = description
    }
}

struct DoraxExtensionHook: Codable, Equatable {
    var id: String
    var name: String
    var urlPattern: String
    var scriptFile: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case urlPattern = "url_pattern"
        case scriptFile = "script_file"
    }

    init(id: String, name: String, urlPattern: String, scriptFile: String) {
        self.id = id; self.name = name
        self.urlPattern = urlPattern; self.scriptFile = scriptFile
    }
}

// MARK: - Operating modes

struct DoraxPackMode: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var description: String
    var systemPromptAppend: String?
    var toolFilter: [String]?
    var isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case systemPromptAppend = "system_prompt_append"
        case toolFilter = "tool_filter"
        case isDefault = "is_default"
    }

    init(id: String, name: String, description: String = "",
         systemPromptAppend: String? = nil, toolFilter: [String]? = nil,
         isDefault: Bool = false) {
        self.id = id; self.name = name; self.description = description
        self.systemPromptAppend = systemPromptAppend
        self.toolFilter = toolFilter; self.isDefault = isDefault
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        systemPromptAppend = try c.decodeIfPresent(String.self, forKey: .systemPromptAppend)
        toolFilter = try c.decodeIfPresent([String].self, forKey: .toolFilter)
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }
}

// MARK: - Loaded pack entries

struct DoraxPackSkillEntry: Equatable {
    var id: String
    var content: String
}

struct DoraxPackScriptEntry: Equatable {
    var filename: String
    var content: String
}

// MARK: - The loaded pack

struct DoraxPackV2: Equatable {
    let metadata: DoraxPackMetadata
    let agentInstructions: String?
    let modes: [DoraxPackMode]
    let skills: [DoraxPackSkillEntry]
    let scripts: [DoraxPackScriptEntry]
    let pageScripts: [DoraxPackScriptEntry]
    let folderURL: URL

    var id: String { metadata.id }
    var name: String { metadata.name }
}

// MARK: - Error

enum DoraxPackError: Error, LocalizedError {
    case unsupportedVersion(Int)
    case missingPackJSON(URL)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v): return "Unsupported .doraxpack format version \(v); expected 2"
        case .missingPackJSON(let url): return "Missing pack.json in \(url.lastPathComponent)"
        }
    }
}

// MARK: - Loader

enum DoraxPackV2Loader {

    static func load(from folderURL: URL) throws -> DoraxPackV2 {
        let fm = FileManager.default
        let decoder = JSONDecoder()

        let packJSONURL = folderURL.appendingPathComponent("pack.json")
        guard fm.fileExists(atPath: packJSONURL.path) else {
            throw DoraxPackError.missingPackJSON(folderURL)
        }
        let data = try Data(contentsOf: packJSONURL)
        let metadata = try decoder.decode(DoraxPackMetadata.self, from: data)
        guard metadata.formatVersion == 2 else {
            throw DoraxPackError.unsupportedVersion(metadata.formatVersion)
        }

        let agentURL = folderURL.appendingPathComponent("AGENT.md")
        let agentMD = try? String(contentsOf: agentURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var modes: [DoraxPackMode] = []
        let modesURL = folderURL.appendingPathComponent("modes.json")
        if let modesData = try? Data(contentsOf: modesURL) {
            modes = (try? decoder.decode([DoraxPackMode].self, from: modesData)) ?? []
        }

        var skills: [DoraxPackSkillEntry] = []
        let skillsDir = folderURL.appendingPathComponent("skills")
        if let items = try? fm.contentsOfDirectory(
            at: skillsDir, includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) {
            for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let skillFile = item.appendingPathComponent("SKILL.md")
                if let content = try? String(contentsOf: skillFile, encoding: .utf8) {
                    skills.append(DoraxPackSkillEntry(id: item.lastPathComponent, content: content))
                }
            }
        }

        let scripts = loadScripts(from: folderURL.appendingPathComponent("scripts"))
        let pageScripts = loadScripts(from: folderURL.appendingPathComponent("page_scripts"))

        return DoraxPackV2(
            metadata: metadata,
            agentInstructions: agentMD?.isEmpty == true ? nil : agentMD,
            modes: modes, skills: skills,
            scripts: scripts, pageScripts: pageScripts,
            folderURL: folderURL)
    }

    static func discoverPacks(in directory: URL) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }
        return items
            .filter { $0.pathExtension == "doraxpack" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func loadScripts(from dir: URL) -> [DoraxPackScriptEntry] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return [] }
        return items
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return DoraxPackScriptEntry(filename: url.lastPathComponent, content: content)
            }
    }
}

// MARK: - Conversion to PluginManifest (backward compat with StorePackInstaller)

extension DoraxPackV2 {

    func toPluginManifest() -> PluginManifest {
        let m = metadata

        var agent: PluginAgent?
        if let instructions = agentInstructions, !instructions.isEmpty {
            agent = PluginAgent(
                instructions: instructions,
                skills: skills.map(\.id),
                tools: (m.cliTools ?? []).map(\.name))
        }

        let targetApp: PluginTargetApp? = {
            guard let bid = m.bundleId,
                  !bid.isEmpty, bid.lowercased() != "global" else { return nil }
            return PluginTargetApp(bundleId: bid, name: m.name)
        }()

        let packSkills: [PluginPackSkill] = skills.map { entry in
            let displayName = entry.id
                .replacingOccurrences(of: "-", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
            return PluginPackSkill(
                id: entry.id, name: displayName,
                summary: "", instructions: entry.content)
        }

        return PluginManifest(
            id: m.id, name: m.name, version: m.version,
            icon: m.icon, description: m.description,
            keywords: m.keywords, agent: agent,
            targetApp: targetApp,
            capabilities: m.capabilities.isEmpty ? nil : m.capabilities,
            skills: packSkills.isEmpty ? nil : packSkills)
    }
}

// MARK: - Legacy migration: PluginManifest → .doraxpack v2 folder

enum DoraxPackV2Migration {

    private static let migrationKey = "doraxpack_v2_migration_done"

    @MainActor
    static func migrateInstalledPacksIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: migrationKey) }

        let userRoot = PluginInstaller.userRoot
        let fm = FileManager.default
        guard let packDirs = try? fm.contentsOfDirectory(
            at: userRoot, includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return }

        let v2Dir = userRoot.appendingPathComponent("v2", isDirectory: true)
        for packDir in packDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: packDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            // Skip directories that are already .doraxpack bundles or the v2 output dir
            if packDir.pathExtension == "doraxpack" || packDir.lastPathComponent == "v2" { continue }

            let pluginsDir = packDir.appendingPathComponent("plugins", isDirectory: true)
            guard let plugins = try? fm.contentsOfDirectory(
                at: pluginsDir, includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            ) else { continue }

            for pluginDir in plugins {
                let manifestFile = pluginDir.appendingPathComponent("manifest.json")
                guard let data = try? Data(contentsOf: manifestFile),
                      let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data)
                else { continue }
                _ = try? migrate(manifest, to: v2Dir)
            }
        }
        if fm.fileExists(atPath: v2Dir.path) {
            NSLog("Context-Dock: legacy packs migrated to v2 at \(v2Dir.path)")
        }
    }

    static func migrate(_ manifest: PluginManifest, to parentDir: URL) throws -> URL {
        let packDir = parentDir
            .appendingPathComponent("\(manifest.id).doraxpack", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: packDir, withIntermediateDirectories: true)

        let metadata = DoraxPackMetadata(
            formatVersion: 2,
            id: manifest.id,
            name: manifest.name,
            version: manifest.version ?? "1.0.0",
            icon: manifest.icon,
            description: manifest.description,
            bundleId: manifest.targetApp?.bundleId,
            keywords: manifest.keywords,
            capabilities: manifest.capabilities ?? [])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let packData = try encoder.encode(metadata)
        try packData.write(to: packDir.appendingPathComponent("pack.json"))

        if let instructions = manifest.agent?.instructions.trimmingCharacters(in: .whitespacesAndNewlines),
           !instructions.isEmpty {
            try instructions.write(
                to: packDir.appendingPathComponent("AGENT.md"),
                atomically: true, encoding: .utf8)
        }

        for skill in manifest.skills ?? [] {
            let skillDir = packDir
                .appendingPathComponent("skills", isDirectory: true)
                .appendingPathComponent(skill.id, isDirectory: true)
            try fm.createDirectory(at: skillDir, withIntermediateDirectories: true)
            try skill.instructions.write(
                to: skillDir.appendingPathComponent("SKILL.md"),
                atomically: true, encoding: .utf8)
        }

        return packDir
    }
}
