// Context-Dock/AI/PluginAuthoring/AgenticAIPackBuilder.swift
// Context-Dock
//
// 4-Stage Agentic AI Pack Builder (Task U4).
// Generates, dry-runs, and safely stages a canonical .doraxpack v2 bundle
// for owner approval and atomic installation via StorePackInstaller.
//
// Stage 1 — Deep Local Introspection: offline, <500 ms, 0 tokens.
//   Reads Info.plist, scans embedded CLIs, PATH, sdef, menus, IPC sockets.
// Stage 2 — Authorized Online Knowledge Research: cached per (bundleID, appVersion).
// Stage 3 — Deterministic Channel & Mechanism Selection: priority-ranked.
// Stage 4 — Synthesis + Read-Only Dry-Run + Owner Review Card.

import AppKit
import Foundation

// MARK: - Stage 1 Types

struct EmbeddedCLIBinary: Equatable {
    let name: String
    let path: String
    let helpText: String?
}

struct Stage1IntrospectionResult: Equatable {
    let bundleID: String
    let appName: String
    let appVersion: String
    let isInstalled: Bool
    let urlSchemes: [String]
    let documentTypes: [String]
    let sdefClasses: [String]
    let sdefCommands: [String]
    let menuPaths: [String]
    let embeddedCLIs: [EmbeddedCLIBinary]
    let pathCLIs: [String]
    let cliHelpTexts: [String: String]
    let ipcSocketPaths: [String]
}

// MARK: - Stage 2 Types

struct Stage2ResearchResult: Equatable {
    let bundleID: String
    let appVersion: String
    let openAPITools: [UTCPToolDefinition]
    let openAPIBaseURL: String?
    let documentationSnippet: String?
    let isCached: Bool

    struct CacheKey: Hashable {
        let bundleID: String
        let appVersion: String
    }
}

// MARK: - Stage 3 Types

/// Capability execution channels, ordered from cleanest-headless (1) to UI-lane fallback (8).
enum CapabilityChannel: Int, CaseIterable, Comparable {
    case extensionHook = 1   // Browser/App Extension Hook
    case embeddedCLI = 2     // Embedded or installed CLI (argv-only)
    case localIPC = 3        // Local IPC / UNIX Socket / SQLite
    case utcpHTTP = 4        // Zero-daemon UTCP HTTP endpoint
    case mcpServer = 5       // MCP Server (lazy stdio)
    case appleScript = 6     // Typed AppleScript / JXA (sdef)
    case urlScheme = 7       // URL Deep Links
    case menuCommand = 8     // Verified Menu Command (UI-lane fallback)

    static func < (lhs: CapabilityChannel, rhs: CapabilityChannel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var packType: String {
        switch self {
        case .extensionHook: return "extensionHook"
        case .embeddedCLI:   return "shellCommand"
        case .localIPC:      return "shellCommand"
        case .utcpHTTP:      return "httpEndpoint"
        case .mcpServer:     return "mcp"
        case .appleScript:   return "appleScript"
        case .urlScheme:     return "urlScheme"
        case .menuCommand:   return "menubar"
        }
    }
}

struct RankedCapability: Equatable {
    let name: String
    let channel: CapabilityChannel
    let detail: String
    let isReadOnly: Bool
}

struct Stage3ChannelPlan: Equatable {
    let rankedCapabilities: [RankedCapability]
    let primaryChannel: CapabilityChannel?
}

// MARK: - Stage 4 Types

struct DryRunProbeResult: Equatable {
    let channel: CapabilityChannel
    let succeeded: Bool
    let detail: String
}

struct OwnerReviewCard: Equatable {
    let packID: String
    let appName: String
    let capabilities: [RankedCapability]
    let requestedPermissions: [String]
    let scriptFiles: [String]
    let dryRunResults: [DryRunProbeResult]
    let stagedPackURL: URL
}

struct PackSynthesisResult {
    let pack: DoraxPackV2
    let reviewCard: OwnerReviewCard
    let isApproved: Bool

    static func == (lhs: PackSynthesisResult, rhs: PackSynthesisResult) -> Bool {
        lhs.isApproved == rhs.isApproved
            && lhs.reviewCard == rhs.reviewCard
            && lhs.pack.id == rhs.pack.id
    }
}

// MARK: - AgenticAIPackBuilder

/// 4-Stage Agentic AI Pack Builder. All public entry points are @MainActor;
/// subprocess and filesystem helpers are nonisolated to hop off the main thread.
@MainActor
enum AgenticAIPackBuilder {

    // MARK: - Stage 2 Cache (per session, keyed by bundleID + appVersion)

    private static var researchCache: [Stage2ResearchResult.CacheKey: Stage2ResearchResult] = [:]

    // MARK: - Stage 1: Deep Local Introspection

    static func stage1(
        bundleID: String,
        appName: String,
        bundleURLResolver: ((String) -> URL?)? = nil,
        ipcSocketChecker: ((String) -> Bool)? = nil,
        isExecutable: ((String) -> Bool)? = nil,
        helpTextProvider: ((String) async -> String?)? = nil
    ) async -> Stage1IntrospectionResult {
        let resolver = bundleURLResolver
            ?? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        let appURL = resolver(bundleID)

        let infoPlist = appURL.flatMap { Bundle(url: $0)?.infoDictionary }
        let appVersion = (infoPlist?["CFBundleShortVersionString"] as? String)
            ?? (infoPlist?["CFBundleVersion"] as? String) ?? "1.0"
        let urlSchemes = extractURLSchemes(from: infoPlist)
        let documentTypes = extractDocumentTypes(from: infoPlist)

        let embeddedCLIs = await Self.scanEmbeddedCLIs(
            appURL: appURL, helpTextProvider: helpTextProvider)

        let pathCLIs = AutonomousAppDiscoveryEngine.discoverCLITools(
            bundleId: bundleID, appName: appName,
            isExecutable: isExecutable
        ).map(\.command)

        var cliHelpTexts: [String: String] = [:]
        for cli in embeddedCLIs {
            if let h = cli.helpText { cliHelpTexts[cli.name] = h }
        }
        let provider = helpTextProvider ?? { await Self.helpText(for: $0) }
        for cmd in pathCLIs where cliHelpTexts[cmd] == nil {
            if let h = await provider(cmd) { cliHelpTexts[cmd] = h }
        }

        let baseReport = await AIPackIntrospector.introspect(bundleID: bundleID, appName: appName)

        let ipcPaths = discoverIPCSockets(
            bundleID: bundleID, appName: appName,
            socketChecker: ipcSocketChecker)

        return Stage1IntrospectionResult(
            bundleID: bundleID,
            appName: appName,
            appVersion: appVersion,
            isInstalled: appURL != nil,
            urlSchemes: urlSchemes,
            documentTypes: documentTypes,
            sdefClasses: baseReport.sdefClasses,
            sdefCommands: baseReport.sdefCommands,
            menuPaths: baseReport.menuPaths,
            embeddedCLIs: embeddedCLIs,
            pathCLIs: pathCLIs,
            cliHelpTexts: cliHelpTexts,
            ipcSocketPaths: ipcPaths
        )
    }

    // MARK: - Stage 2: Authorized Online Knowledge Research

    static func stage2(
        bundleID: String,
        appVersion: String,
        websiteDocsProvider: ((String, String, String?) async -> String?)? = nil
    ) async -> Stage2ResearchResult {
        let key = Stage2ResearchResult.CacheKey(bundleID: bundleID, appVersion: appVersion)
        if let cached = researchCache[key] {
            return Stage2ResearchResult(
                bundleID: cached.bundleID, appVersion: cached.appVersion,
                openAPITools: cached.openAPITools, openAPIBaseURL: cached.openAPIBaseURL,
                documentationSnippet: cached.documentationSnippet, isCached: true)
        }

        let adapter = AppAdapterManager.shared.adapters
            .first { $0.bundleId == bundleID }
        var docText: String? = nil

        if let docsProvider = websiteDocsProvider {
            docText = await docsProvider(bundleID, appVersion, adapter?.website)
        } else if let site = adapter?.website,
                  AppWebsiteKnowledge.fetchableURL(from: site) != nil {
            docText = await AppWebsiteKnowledge.knowledge(
                bundleId: bundleID, version: appVersion, website: site)
        }

        let result = Stage2ResearchResult(
            bundleID: bundleID,
            appVersion: appVersion,
            openAPITools: [],
            openAPIBaseURL: nil,
            documentationSnippet: docText.map { String($0.prefix(1000)) },
            isCached: false
        )
        researchCache[key] = result
        return result
    }

    // MARK: - Stage 3: Deterministic Channel Selection

    /// Ranks all discovered capability signals by channel priority, deduplicates by name.
    static func stage3(
        stage1: Stage1IntrospectionResult,
        stage2: Stage2ResearchResult
    ) -> Stage3ChannelPlan {
        var capabilities: [RankedCapability] = []

        // Priority 2: Embedded CLIs (discovered inside .app bundle)
        for cli in stage1.embeddedCLIs {
            capabilities.append(RankedCapability(
                name: cli.name, channel: .embeddedCLI,
                detail: cli.path, isReadOnly: false))
        }
        // Priority 2: PATH CLIs (also embeddedCLI channel — same execution model)
        for cmd in stage1.pathCLIs {
            capabilities.append(RankedCapability(
                name: cmd, channel: .embeddedCLI,
                detail: "path:\(cmd)", isReadOnly: false))
        }

        // Priority 3: Local IPC sockets
        for sock in stage1.ipcSocketPaths {
            let name = String(sock.split(separator: "/").last ?? Substring(sock))
            capabilities.append(RankedCapability(
                name: name, channel: .localIPC, detail: sock, isReadOnly: false))
        }

        // Priority 4: UTCP HTTP endpoints (from online research)
        for tool in stage2.openAPITools {
            if case .http(let http) = tool.execution {
                capabilities.append(RankedCapability(
                    name: tool.name, channel: .utcpHTTP,
                    detail: "\(http.method) \(http.path)", isReadOnly: false))
            }
        }

        // Priority 6: AppleScript sdef commands (top 10)
        for cmd in stage1.sdefCommands.prefix(10) {
            capabilities.append(RankedCapability(
                name: cmd, channel: .appleScript, detail: "sdef", isReadOnly: false))
        }

        // Priority 7: URL Deep Links
        for scheme in stage1.urlSchemes {
            capabilities.append(RankedCapability(
                name: "\(scheme)://", channel: .urlScheme, detail: scheme, isReadOnly: true))
        }

        // Priority 8: Menu commands (top 5, UI-lane fallback only)
        for path in stage1.menuPaths.prefix(5) {
            let name = path.split(separator: "▸").last
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? path
            capabilities.append(RankedCapability(
                name: name, channel: .menuCommand, detail: path, isReadOnly: false))
        }

        var seen = Set<String>()
        let ranked = capabilities
            .sorted { $0.channel < $1.channel }
            .filter { seen.insert($0.name.lowercased()).inserted }

        return Stage3ChannelPlan(rankedCapabilities: ranked, primaryChannel: ranked.first?.channel)
    }

    // MARK: - Stage 4: Synthesis + Dry-Run + Owner Review Card

    /// Synthesizes a staged .doraxpack v2 (0644 permissions), runs read-only
    /// dry-run probes, and returns an OwnerReviewCard before any installation.
    static func stage4(
        stage1: Stage1IntrospectionResult,
        stage2: Stage2ResearchResult,
        stage3: Stage3ChannelPlan,
        tempDirectory: URL? = nil
    ) async -> PackSynthesisResult {
        let tempDir = tempDirectory
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("doraxpack-staged-\(UUID().uuidString)", isDirectory: true)

        let packID = stage1.bundleID
            .replacingOccurrences(of: ".", with: "-")
            .lowercased()
        let packDir = tempDir.appendingPathComponent("\(packID).doraxpack", isDirectory: true)

        let synthesizedURL: URL?
        do {
            synthesizedURL = try synthesizePack(
                stage1: stage1, stage2: stage2, stage3: stage3,
                packID: packID, packDir: packDir)
        } catch {
            synthesizedURL = nil
        }

        let dryRunResults = await runDryRunProbes(stage1: stage1, stage3: stage3)

        let reviewCard = OwnerReviewCard(
            packID: packID,
            appName: stage1.appName,
            capabilities: stage3.rankedCapabilities,
            requestedPermissions: buildRequestedPermissions(stage1: stage1, stage3: stage3),
            scriptFiles: listScriptFiles(in: synthesizedURL ?? packDir),
            dryRunResults: dryRunResults,
            stagedPackURL: synthesizedURL ?? packDir
        )

        let pack: DoraxPackV2
        if let url = synthesizedURL, let loaded = try? DoraxPackV2Loader.load(from: url) {
            pack = loaded
        } else {
            pack = makeMinimalPack(stage1: stage1, packID: packID)
        }

        return PackSynthesisResult(pack: pack, reviewCard: reviewCard, isApproved: false)
    }

    // MARK: - Main Entry Point

    /// Runs all 4 stages; returns a staged PackSynthesisResult pending owner approval.
    static func build(
        bundleID: String,
        appName: String,
        websiteDocsProvider: ((String, String, String?) async -> String?)? = nil,
        tempDirectory: URL? = nil,
        bundleURLResolver: ((String) -> URL?)? = nil
    ) async -> PackSynthesisResult {
        let s1 = await stage1(bundleID: bundleID, appName: appName,
                               bundleURLResolver: bundleURLResolver)
        let s2 = await stage2(bundleID: bundleID, appVersion: s1.appVersion,
                               websiteDocsProvider: websiteDocsProvider)
        let s3 = stage3(stage1: s1, stage2: s2)
        return await stage4(stage1: s1, stage2: s2, stage3: s3, tempDirectory: tempDirectory)
    }

    /// Atomically binds the staged (approved) pack via StorePackInstaller.installV2.
    @discardableResult
    static func approveAndInstall(_ result: PackSynthesisResult) throws -> StorePackBindResult {
        try StorePackInstaller.installV2(result.pack)
    }

    // MARK: - Embedded Binary Scanner

    /// Scans `Contents/MacOS/` and `Contents/Resources/` for embedded CLI binaries.
    /// Skips the main app binary, dylibs, and framework bundles.
    nonisolated static func scanEmbeddedCLIs(
        appURL: URL?,
        helpTextProvider: ((String) async -> String?)? = nil
    ) async -> [EmbeddedCLIBinary] {
        guard let appURL else { return [] }
        let mainBinaryName = appURL.deletingPathExtension().lastPathComponent
        let provider = helpTextProvider ?? { await Self.helpText(for: $0) }
        var found: [EmbeddedCLIBinary] = []

        for subpath in ["Contents/MacOS", "Contents/Resources"] {
            let dir = appURL.appendingPathComponent(subpath)
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: .skipsHiddenFiles
            ) else { continue }

            for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                // Directories have the POSIX +x traverse bit so `isExecutableFile` returns true
                // for folders like `Safari.app/Contents/Resources/Background Images`.
                let isRegularFile = (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                guard isRegularFile else { continue }
                guard FileManager.default.isExecutableFile(atPath: item.path) else { continue }
                let ext = item.pathExtension
                // Skip non-CLI file types
                guard ext.isEmpty || ext == "sh" || ext == "py" else { continue }
                guard item.lastPathComponent != mainBinaryName else { continue }

                let help = await provider(item.path)
                found.append(EmbeddedCLIBinary(
                    name: item.lastPathComponent,
                    path: item.path,
                    helpText: help))
            }
        }
        return found
    }

    /// Runs `<executable> --help` with null stdin, 5-second timeout. Strictly read-only.
    nonisolated static func helpText(for executable: String) async -> String? {
        guard let result = await ShellProcess.run(
            executable, arguments: ["--help"], timeout: 5
        ) else { return nil }
        let combined = (result.stdout + "\n" + result.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return combined.isEmpty ? nil : String(combined.prefix(2000))
    }

    // MARK: - IPC Socket Discovery

    nonisolated static func discoverIPCSockets(
        bundleID: String,
        appName: String,
        socketChecker: ((String) -> Bool)? = nil
    ) -> [String] {
        let check = socketChecker ?? { FileManager.default.fileExists(atPath: $0) }
        let lowerName = appName.lowercased()
        let lowerBundle = bundleID.lowercased()
        var candidates: [String] = []

        if lowerBundle.contains("iina") || lowerName.contains("iina") {
            candidates.append("/tmp/iina-ipc.sock")
        }
        if lowerBundle.contains(".mpv") || lowerName == "mpv" {
            candidates.append(contentsOf: ["/tmp/mpvsocket", "/tmp/mpv.sock"])
        }
        if lowerBundle.contains("hammerspoon") || lowerName.contains("hammerspoon") {
            candidates.append("/tmp/hammerspoon-ipc")
        }
        let slug = lowerName.replacingOccurrences(of: " ", with: "-")
        if !slug.isEmpty {
            candidates.append("/tmp/\(slug)-ipc.sock")
            candidates.append("/tmp/\(slug).sock")
        }

        return candidates.filter(check)
    }

    // MARK: - Private: Stage 4 Helpers

    @discardableResult
    private static func synthesizePack(
        stage1: Stage1IntrospectionResult,
        stage2: Stage2ResearchResult,
        stage3: Stage3ChannelPlan,
        packID: String,
        packDir: URL
    ) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: packDir, withIntermediateDirectories: true)

        let capabilities = stage3.rankedCapabilities.prefix(12).map { cap -> PluginPackCapability in
            let safeCapName = cap.name
                .lowercased()
                .filter { $0.isLetter || $0.isNumber }
                .prefix(20)
            let capID = "\(packID).\(safeCapName)"
            return PluginPackCapability(
                id: String(capID),
                name: cap.name,
                intent: cap.detail,
                triggers: [cap.name.lowercased()],
                type: cap.channel.packType,
                script: cap.channel == .embeddedCLI ? cap.detail : nil,
                menuPath: cap.channel == .menuCommand
                    ? cap.detail.components(separatedBy: " ▸ ") : nil,
                urlScheme: cap.channel == .urlScheme ? cap.detail : nil,
                safety: cap.isReadOnly ? "read" : "write"
            )
        }

        let cliTools: [DoraxCLITool]? = {
            var tools = stage1.embeddedCLIs.map { DoraxCLITool(name: $0.name, binary: $0.path) }
            tools += stage1.pathCLIs.map { DoraxCLITool(name: $0, binary: $0) }
            return tools.isEmpty ? nil : tools
        }()

        let metadata = DoraxPackMetadata(
            formatVersion: 2,
            id: packID,
            name: "\(stage1.appName) Pack",
            version: "1.0.0",
            icon: "puzzlepiece.extension.fill",
            description: "AI pack for \(stage1.appName) — generated by AgenticAIPackBuilder",
            bundleId: stage1.bundleID,
            keywords: [stage1.appName.lowercased()],
            capabilities: Array(capabilities),
            cliTools: cliTools
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let packJSONURL = packDir.appendingPathComponent("pack.json")
        try encoder.encode(metadata).write(to: packJSONURL)
        // Stage as non-executable (0644) until owner approves
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: packJSONURL.path)

        let agentMD = buildAgentMD(stage1: stage1, stage2: stage2)
        let agentURL = packDir.appendingPathComponent("AGENT.md")
        try agentMD.write(to: agentURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: agentURL.path)

        return packDir
    }

    private static func runDryRunProbes(
        stage1: Stage1IntrospectionResult,
        stage3: Stage3ChannelPlan
    ) async -> [DryRunProbeResult] {
        // Probe each unique channel once (top 5 capabilities only)
        var channelsSeen = Set<CapabilityChannel>()
        var results: [DryRunProbeResult] = []

        for cap in stage3.rankedCapabilities.prefix(5) {
            guard channelsSeen.insert(cap.channel).inserted else { continue }

            let result: DryRunProbeResult
            switch cap.channel {
            case .embeddedCLI, .extensionHook:
                // --help is strictly read-only; never executes a write operation
                let path = cap.detail.hasPrefix("path:")
                    ? String(cap.detail.dropFirst(5)) : cap.detail
                let ok = await ShellProcess.run(path, arguments: ["--help"], timeout: 5) != nil
                result = DryRunProbeResult(channel: cap.channel, succeeded: ok, detail: "--help probe")

            case .localIPC:
                let exists = FileManager.default.fileExists(atPath: cap.detail)
                result = DryRunProbeResult(channel: .localIPC, succeeded: exists, detail: "socket exists")

            case .appleScript:
                // Schema verification only — no live execution
                let ok = !stage1.sdefClasses.isEmpty
                result = DryRunProbeResult(channel: .appleScript, succeeded: ok, detail: "sdef schema check")

            case .urlScheme:
                result = DryRunProbeResult(channel: .urlScheme, succeeded: true, detail: "scheme registered")

            case .menuCommand:
                result = DryRunProbeResult(
                    channel: .menuCommand,
                    succeeded: !stage1.menuPaths.isEmpty,
                    detail: "menu cache check")

            default:
                result = DryRunProbeResult(channel: cap.channel, succeeded: false, detail: "no probe available")
            }
            results.append(result)
        }
        return results
    }

    private static func buildRequestedPermissions(
        stage1: Stage1IntrospectionResult,
        stage3: Stage3ChannelPlan
    ) -> [String] {
        let channels = Set(stage3.rankedCapabilities.map(\.channel))
        var perms: [String] = []
        if channels.contains(.appleScript) {
            perms.append("AppleScript/JXA execution for \(stage1.appName)")
        }
        if channels.contains(.menuCommand) {
            perms.append("UI-lane menu commands for \(stage1.appName)")
        }
        if channels.contains(.embeddedCLI) {
            perms.append("Shell execution of discovered CLI tools")
        }
        if channels.contains(.localIPC) {
            perms.append("Local IPC socket communication")
        }
        return perms
    }

    private static func listScriptFiles(in packDir: URL) -> [String] {
        let scriptsDir = packDir.appendingPathComponent("scripts")
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: scriptsDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return [] }
        return items.map(\.lastPathComponent).sorted()
    }

    private static func buildAgentMD(
        stage1: Stage1IntrospectionResult,
        stage2: Stage2ResearchResult
    ) -> String {
        var lines = [
            "# \(stage1.appName) Agent Instructions",
            "",
            "You are an AI agent for **\(stage1.appName)** (`\(stage1.bundleID)`).",
            "App version: \(stage1.appVersion)",
            ""
        ]
        if !stage1.urlSchemes.isEmpty {
            lines += ["## URL Schemes", ""]
            lines += stage1.urlSchemes.map { "- `\($0)://`" }
            lines.append("")
        }
        if !stage1.sdefCommands.isEmpty {
            lines += ["## AppleScript Commands", ""]
            lines += stage1.sdefCommands.prefix(10).map { "- `\($0)`" }
            lines.append("")
        }
        if let doc = stage2.documentationSnippet {
            lines += ["## Documentation", "", doc, ""]
        }
        lines += [
            "## Rules",
            "",
            "- Never delete files or quit the app without explicit user confirmation.",
            "- Never execute destructive commands.",
            "- Prefer read-only operations unless the user explicitly requests a change."
        ]
        return lines.joined(separator: "\n")
    }

    private static func makeMinimalPack(
        stage1: Stage1IntrospectionResult,
        packID: String
    ) -> DoraxPackV2 {
        let metadata = DoraxPackMetadata(
            formatVersion: 2,
            id: packID,
            name: "\(stage1.appName) Pack",
            version: "1.0.0",
            bundleId: stage1.bundleID)
        return DoraxPackV2(
            metadata: metadata,
            agentInstructions: nil,
            modes: [], skills: [], scripts: [], pageScripts: [],
            folderURL: FileManager.default.temporaryDirectory)
    }

    // MARK: - Private: Info.plist Helpers

    private static func extractURLSchemes(from infoPlist: [String: Any]?) -> [String] {
        guard let urlTypes = infoPlist?["CFBundleURLTypes"] as? [[String: Any]] else { return [] }
        var schemes: [String] = []
        for type in urlTypes {
            if let typeSchemes = type["CFBundleURLSchemes"] as? [String] {
                schemes.append(contentsOf: typeSchemes)
            }
        }
        var seen = Set<String>()
        return schemes.filter { seen.insert($0.lowercased()).inserted }.sorted()
    }

    private static func extractDocumentTypes(from infoPlist: [String: Any]?) -> [String] {
        guard let docTypes = infoPlist?["CFBundleDocumentTypes"] as? [[String: Any]] else { return [] }
        return docTypes.compactMap { $0["CFBundleTypeName"] as? String }
    }
}
