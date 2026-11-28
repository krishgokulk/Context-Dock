// Context-Dock/AI/PluginAuthoring/DoraxPackV3Authoring.swift
// Context-Dock
//
// Step 6: Context-Aware `.doraxpack` v3 Authoring ("Create for <Frontmost App / Website>"),
// Starter Templates, Schema & Diagnostic Check, Read-Only Live Dry Run, Permission & Hook
// Review Card, and One-Click Install into `DoraxPackV3Registry`.

import AppKit
import Foundation

// MARK: - Starter Templates

enum DoraxPackV3Template: String, CaseIterable, Identifiable {
    case appCompanion = "app-companion"
    case webAppCompanion = "webapp-companion"
    case cliWrapper = "cli-wrapper"
    case notchTimer = "notch-timer"
    case nativeSourceBoard = "native-source"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appCompanion: return "App Companion Pack"
        case .webAppCompanion: return "Web-App Pack (YouTube / GitHub)"
        case .cliWrapper: return "CLI Wrapper (argv-only)"
        case .notchTimer: return "Notch Live Activity"
        case .nativeSourceBoard: return "Zero-Script dorax.* Board"
        }
    }

    var icon: String {
        switch self {
        case .appCompanion: return "app.badge.checkmark"
        case .webAppCompanion: return "globe"
        case .cliWrapper: return "terminal"
        case .notchTimer: return "waveform.path.ecg"
        case .nativeSourceBoard: return "bolt.fill"
        }
    }

    func generateMetadata(
        appName: String = "Workspace",
        bundleID: String? = nil,
        domain: String? = nil
    ) -> DoraxPackMetadata {
        let slugBase = (domain ?? appName)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let safeID = slugBase.isEmpty ? "custom-pack" : slugBase

        switch self {
        case .appCompanion:
            let bid = bundleID ?? "com.apple.Notes"
            return DoraxPackMetadata(
                formatVersion: 2,
                schemaVersion: 3,
                id: "\(safeID)-pack",
                name: "\(appName) Pack",
                version: "3.0.0",
                icon: "sparkles.rectangle.stack",
                description: "Context-aware commands, AI skills, and frontmost menus for \(appName).",
                bundleId: bid,
                keywords: [appName.lowercased(), "menus", "actions"],
                capabilities: [
                    PluginPackCapability(
                        id: "\(safeID).inspect",
                        name: "Inspect \(appName)",
                        intent: "Inspect active context and menus in \(appName).",
                        triggers: ["inspect \(appName.lowercased())"],
                        type: "aiPrompt",
                        script: "Inspect the frontmost \(appName) window and suggest next actions.",
                        safety: "read")
                ],
                scope: DoraxPackScope(surfaces: ["global", "appPet", "notch"], apps: [bid], domains: []),
                appearance: DoraxPackAppearance(tint: "#38BDF8", glow: .soft),
                permissions: ["context:frontmost", "hook:frontmost"],
                commands: [
                    DoraxPackCommand(
                        id: "menus",
                        title: "\(appName) Menu Commands",
                        subtitle: "Live cached menus for \(appName)",
                        icon: "command",
                        mode: .list,
                        keywords: [appName.lowercased(), "menu", "commands"],
                        source: "dorax.frontmost.menus",
                        safety: "read")
                ])

        case .webAppCompanion:
            let host = DoraxPackScope.normalizedHost(from: domain ?? "youtube.com")
            let label = host.split(separator: ".").first.map { String($0).capitalized } ?? "WebApp"
            return DoraxPackMetadata(
                formatVersion: 2,
                schemaVersion: 3,
                id: "\(safeID)-web-pack",
                name: "\(label) Web Pack",
                version: "3.0.0",
                icon: "globe",
                description: "URL-scoped commands and reactive Notch suggestions for \(host).",
                keywords: [label.lowercased(), host, "web", "tabs"],
                capabilities: [
                    PluginPackCapability(
                        id: "\(safeID).summarize",
                        name: "Summarize \(label) Page",
                        intent: "Summarize the active \(host) page.",
                        triggers: ["summarize \(label.lowercased())"],
                        type: "aiPrompt",
                        script: "Read the active \(host) tab and summarize key takeaways.",
                        safety: "read")
                ],
                scope: DoraxPackScope(surfaces: ["global", "appPet", "notch"], apps: [], domains: [host]),
                appearance: DoraxPackAppearance(tint: "#F43F5E", glow: .soft),
                permissions: ["context:frontmost", "context:url", "browser:tabs", "hook:url"],
                commands: [
                    DoraxPackCommand(
                        id: "active-tabs",
                        title: "\(label) Active Tab",
                        subtitle: "Inspect open \(host) pages via WebContextEngine",
                        icon: "safari.fill",
                        mode: .list,
                        keywords: [label.lowercased(), host, "tab"],
                        source: "dorax.browser.tabs",
                        safety: "read")
                ],
                hooks: [
                    DoraxPackHook(
                        id: "on-domain-open",
                        on: .urlChange,
                        script: "hooks/on-url.py",
                        filter: DoraxPackHookFilter(domains: [host]))
                ])

        case .cliWrapper:
            return DoraxPackMetadata(
                formatVersion: 2,
                schemaVersion: 3,
                id: "\(safeID)-cli-pack",
                name: "\(appName) CLI Pack",
                version: "3.0.0",
                icon: "terminal.fill",
                description: "Safe argv-only CLI command output inside the 680 × 440 Result Sheet.",
                keywords: [safeID, "cli", "git", "status"],
                capabilities: [
                    PluginPackCapability(
                        id: "\(safeID).cli",
                        name: "Run CLI Check",
                        intent: "Run read-only CLI check.",
                        triggers: ["cli check"],
                        type: "shell",
                        script: "uname -a",
                        safety: "read")
                ],
                scope: DoraxPackScope(surfaces: ["global"], apps: [], domains: []),
                appearance: DoraxPackAppearance(tint: "#818CF8", glow: .soft),
                permissions: ["cli:execute"],
                commands: [
                    DoraxPackCommand(
                        id: "sys-info",
                        title: "System Info (CLI)",
                        subtitle: "Runs /usr/bin/uname -a via strict argv-only execution",
                        icon: "terminal",
                        mode: .cli,
                        keywords: ["uname", "system", "cli"],
                        binary: "/usr/bin/uname",
                        args: ["-a"],
                        safety: "read")
                ])

        case .notchTimer:
            return DoraxPackMetadata(
                formatVersion: 2,
                schemaVersion: 3,
                id: "focus-timer-pack",
                name: "Focus Timer",
                version: "3.0.0",
                icon: "timer",
                description: "Start a 25-minute Focus Live Activity right inside the Dynamic Island Notch.",
                keywords: ["focus", "pomodoro", "timer", "notch"],
                capabilities: [
                    PluginPackCapability(
                        id: "focus.start",
                        name: "Start 25m Focus Session",
                        intent: "Start a 25 minute focus session in the Notch.",
                        triggers: ["focus timer", "pomodoro"],
                        type: "aiPrompt",
                        script: "Start a 25 minute focus session.",
                        safety: "read")
                ],
                scope: DoraxPackScope(surfaces: ["global", "notch"], apps: [], domains: []),
                appearance: DoraxPackAppearance(tint: "#F59E0B", glow: .breathe),
                permissions: ["notch:activity"],
                commands: [
                    DoraxPackCommand(
                        id: "start-focus",
                        title: "Start 25m Focus",
                        subtitle: "Pins a countdown wing to the Dynamic Island Notch",
                        icon: "timer",
                        mode: .notch,
                        keywords: ["focus", "pomodoro", "timer", "25m"],
                        script: "commands/focus-notch.py",
                        safety: "read")
                ])

        case .nativeSourceBoard:
            return DoraxPackMetadata(
                formatVersion: 2,
                schemaVersion: 3,
                id: "clipboard-glance-pack",
                name: "Clipboard Glance",
                version: "3.0.0",
                icon: "doc.on.clipboard",
                description: "Zero-script pack powered directly by dorax.clipboard native data source.",
                keywords: ["clipboard", "clips", "colors", "links"],
                capabilities: [
                    PluginPackCapability(
                        id: "clipboard.glance",
                        name: "Recent Clips",
                        intent: "View recent clipboard items via dorax.clipboard.",
                        triggers: ["recent clips"],
                        type: "aiPrompt",
                        script: "List recent clipboard entries.",
                        safety: "read")
                ],
                scope: DoraxPackScope(surfaces: ["global"], apps: [], domains: []),
                appearance: DoraxPackAppearance(tint: "#34D399", glow: .soft),
                permissions: ["context:clipboard"],
                commands: [
                    DoraxPackCommand(
                        id: "recent-clips",
                        title: "Recent Clipboard Items",
                        subtitle: "Zero-script view backed by dorax.clipboard",
                        icon: "doc.on.clipboard",
                        mode: .list,
                        keywords: ["clips", "clipboard", "paste"],
                        source: "dorax.clipboard",
                        filterOptions: ["All", "Text", "Url", "Color"],
                        safety: "read")
                ])
        }
    }
}

// MARK: - V3 Synthesis Result & Permission/Hook Review

struct DoraxPackV3ReviewSummary: Equatable {
    let packID: String
    let packName: String
    let targetLabel: String
    let domains: [String]
    let contextFieldsRead: [String]
    let networkHosts: [String]
    let hookSummaries: [String]
    let diagnostics: [PluginDiagnostic]
    let dryRunOutput: DoraxCommandOutput?
    let dryRunError: String?
    let stagedFolderURL: URL

    var hasBlockingErrors: Bool {
        diagnostics.contains { $0.severity == .error }
    }
}

struct DoraxPackV3SynthesisResult {
    let pack: DoraxPackV2
    let review: DoraxPackV3ReviewSummary
    let packJSONText: String
}

// MARK: - Context-Aware `.doraxpack` v3 Builder

@MainActor
enum DoraxPackV3Builder {

    /// Context-aware `"Create for <Frontmost App / Website>"` builder (Step 6):
    /// 1. Gathers live frontmost bundle ID, AX menus, `sdef`, active browser domain/URL,
    ///    linked CLI tools, MCP servers, and existing `AGENT.md`.
    /// 2. Synthesizes a complete `.doraxpack` v3 folder (`pack.json`, `AGENT.md`, `skills/`,
    ///    `commands/`, `hooks/`).
    /// 3. Runs Schema & Diagnostic Check (`DoraxPackV3Validator.validate`) AND Read-Only Live Dry Run.
    /// 4. Returns a `DoraxPackV3SynthesisResult` ready for the Permission & Hook Review Card and
    ///    one-click install.
    static func buildForTarget(
        bundleID: String?,
        appName: String,
        activeURL: String? = nil,
        template: DoraxPackV3Template? = nil,
        stagingRoot: URL? = nil
    ) async -> DoraxPackV3SynthesisResult {
        let domain: String? = activeURL.flatMap { raw in
            let host = DoraxPackScope.normalizedHost(from: raw)
            return host.isEmpty ? nil : host
        }
        let chosenTemplate: DoraxPackV3Template = template
            ?? (domain != nil ? .webAppCompanion : .appCompanion)

        var metadata = chosenTemplate.generateMetadata(
            appName: appName,
            bundleID: bundleID,
            domain: domain)

        var existingAgentMD = ""
        var discoveredMenus: [String] = []
        var discoveredCLIs: [String] = []
        var discoveredMCPs: [DoraxMCPServer] = []

        if let bid = bundleID, !bid.isEmpty {
            let stage1 = await AgenticAIPackBuilder.stage1(bundleID: bid, appName: appName)
            discoveredMenus = Array(stage1.menuPaths.prefix(8))
            discoveredCLIs = stage1.embeddedCLIs.map(\.name) + stage1.pathCLIs
            if !stage1.embeddedCLIs.isEmpty {
                metadata.cliTools = stage1.embeddedCLIs.map {
                    DoraxCLITool(name: $0.name, binary: $0.path, description: "Embedded CLI in \(appName)")
                }
            }
            let profileURL = AppAgentProfileStore.shared.fileURL(forBundleID: bid)
            if let existing = try? String(contentsOf: profileURL, encoding: .utf8) {
                existingAgentMD = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let linkedMCPs = MCPServerManager.shared.servers(forBundleId: bid)
            discoveredMCPs = linkedMCPs.map {
                DoraxMCPServer(
                    name: $0.name,
                    transport: $0.transport,
                    command: ([$0.command] + $0.args).joined(separator: " "),
                    description: "Linked MCP server for \(appName)")
            }
            if !discoveredMCPs.isEmpty {
                metadata.mcpServers = discoveredMCPs
            }
        }

        // Stage folder on disk
        let baseDir = stagingRoot ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("doraxpack-v3-staging", isDirectory: true)
        let packFolder = baseDir.appendingPathComponent("\(metadata.id).doraxpack", isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: packFolder)
        try? fm.createDirectory(at: packFolder, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let packJSONData = (try? encoder.encode(metadata)) ?? Data("{}".utf8)
        let packJSONText = String(data: packJSONData, encoding: .utf8) ?? "{}"
        try? packJSONData.write(to: packFolder.appendingPathComponent("pack.json"), options: .atomic)

        // AGENT.md
        let targetDisplay = domain ?? appName
        var agentLines = [
            "# \(metadata.name)",
            "",
            "You are DoraX's assistant for **\(targetDisplay)**.",
            ""
        ]
        if !discoveredCLIs.isEmpty {
            agentLines.append("## Discovered CLIs: " + discoveredCLIs.joined(separator: ", "))
        }
        if !discoveredMenus.isEmpty {
            agentLines.append("## Key Menus")
            agentLines += discoveredMenus.prefix(5).map { "- \($0)" }
        }
        if !existingAgentMD.isEmpty {
            agentLines += ["", "## Inherited App Rules", existingAgentMD]
        }
        agentLines += [
            "",
            "## Safety Rules",
            "- Prefer read-only sources and tools first.",
            "- NEVER perform destructive writes without explicit owner confirmation."
        ]
        try? agentLines.joined(separator: "\n").write(
            to: packFolder.appendingPathComponent("AGENT.md"), atomically: true, encoding: .utf8)

        // Default skill
        let skillDir = packFolder.appendingPathComponent("skills/quick-workflow", isDirectory: true)
        try? fm.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let skillText = """
        ---
        name: quick-workflow
        description: Read-only inspection workflow for \(targetDisplay).
        ---
        # \(targetDisplay) Workflow
        1. Inspect current context via pack commands and `dorax.*` sources.
        2. Summarize findings cleanly and wait for owner confirmation before any write action.
        """
        try? skillText.write(
            to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        // Optional template helper scripts
        if chosenTemplate == .notchTimer {
            let cmdDir = packFolder.appendingPathComponent("commands", isDirectory: true)
            try? fm.createDirectory(at: cmdDir, withIntermediateDirectories: true)
            let script = """
            #!/usr/bin/env python3
            import json
            print(json.dumps({
                "notch": {
                    "wing_text": "25:00",
                    "wing_icon": "timer",
                    "wing_color": "#F59E0B",
                    "title": "Focus Session",
                    "subtitle": "25-minute deep work timer",
                    "timer_seconds": 1500
                },
                "appearance": {"tint": "#F59E0B", "glow": "breathe"}
            }))
            """
            try? script.write(
                to: cmdDir.appendingPathComponent("focus-notch.py"), atomically: true, encoding: .utf8)
        }
        if chosenTemplate == .webAppCompanion, let host = domain ?? metadata.scope?.domains.first {
            let hooksDir = packFolder.appendingPathComponent("hooks", isDirectory: true)
            try? fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
            let hookScript = """
            #!/usr/bin/env python3
            import json, sys
            print(json.dumps({
                "notch": {
                    "wing_text": "\(host.prefix(10))",
                    "wing_icon": "globe",
                    "wing_color": "#F43F5E",
                    "title": "\(metadata.name)",
                    "subtitle": "Active on \(host)"
                },
                "suggestions": [
                    {"title": "Summarize \(host) page", "subtitle": "\(metadata.name)", "icon": "sparkles"}
                ]
            }))
            """
            try? hookScript.write(
                to: hooksDir.appendingPathComponent("on-url.py"), atomically: true, encoding: .utf8)
        }

        // Load back through canonical loader
        let loaded = (try? DoraxPackV2Loader.load(from: packFolder))
            ?? DoraxPackV2(
                metadata: metadata,
                agentInstructions: agentLines.joined(separator: "\n"),
                modes: [], skills: [], scripts: [], pageScripts: [],
                folderURL: packFolder)

        // 1. Schema & Diagnostic Check
        let diagnostics = DoraxPackV3Validator.validate(loaded)

        // 2. Read-Only Live Dry Run on the first read-only command
        var dryRunOutput: DoraxCommandOutput? = nil
        var dryRunError: String? = nil
        if let firstReadCmd = loaded.metadata.commands?.first(where: { $0.safety.lowercased() == "read" }) {
            let dryResult = await DoraxPackV3Runtime.shared.runCommand(
                firstReadCmd, in: loaded, forceRefresh: true)
            switch dryResult {
            case .success(let out): dryRunOutput = out
            case .failure(let err): dryRunError = err.message
            }
        }

        // 3. Permission & Hook Review Summary
        let perms = loaded.metadata.permissions ?? []
        let contextFields = perms.filter { $0.hasPrefix("context:") || $0.hasPrefix("browser:") }
        let networkHosts = perms.compactMap { p -> String? in
            p.hasPrefix("network:") ? String(p.dropFirst("network:".count)) : nil
        }
        let hookSummaries = (loaded.metadata.hooks ?? []).map { h in
            "\(h.id) — on \(h.on.rawValue) (\(h.on.requiredPermission))"
        }

        let review = DoraxPackV3ReviewSummary(
            packID: loaded.id,
            packName: loaded.name,
            targetLabel: targetDisplay,
            domains: loaded.metadata.effectiveScope.domains,
            contextFieldsRead: contextFields,
            networkHosts: networkHosts,
            hookSummaries: hookSummaries,
            diagnostics: diagnostics,
            dryRunOutput: dryRunOutput,
            dryRunError: dryRunError,
            stagedFolderURL: packFolder)

        return DoraxPackV3SynthesisResult(
            pack: loaded,
            review: review,
            packJSONText: packJSONText)
    }

    /// One-click install of a reviewed `.doraxpack` v3 bundle into `DoraxPackV3Registry`.
    @discardableResult
    static func approveAndInstall(
        _ synthesis: DoraxPackV3SynthesisResult,
        grantHookPermissions: Bool = true,
        destinationRoot: URL? = nil,
        persistToDisk: Bool = !AppDelegate.isHostingTests
    ) throws -> DoraxPackV2 {
        try DoraxPackV3Registry.shared.installPackFolder(
            from: synthesis.review.stagedFolderURL,
            into: destinationRoot,
            grantHookPermissions: grantHookPermissions,
            persistToDisk: persistToDisk)
    }
}

// MARK: - Phase 1: In-Place AI Pack Architect & Upgrader

@MainActor
enum DoraxPackV3AIArchitect {

    /// Proposes a non-destructive multi-file upgrade patch (`DoraxPackV3Patch`) for an existing
    /// `.doraxpack` bundle, preserves existing commands/capabilities/preferences, validates via
    /// `DoraxPackV3Validator`, and runs a read-only dry run before owner approval.
    static func proposeUpgrade(
        pack: DoraxPackV2,
        instruction rawInstruction: String,
        stagingRoot: URL? = nil,
        useLiveAI: Bool = !AppDelegate.isHostingTests
    ) async -> DoraxPackV3Patch {
        let instruction = rawInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentJSON = (try? String(contentsOf: pack.folderURL.appendingPathComponent("pack.json"), encoding: .utf8))
            ?? encodeMetadata(pack.metadata)

        if useLiveAI, !instruction.isEmpty {
            let sysPrompt = """
            You are DoraX's `.doraxpack` v3 AI Pack Architect.
            The user wants to upgrade the existing pack "\(pack.name)" (id: "\(pack.id)").
            Return ONLY strict JSON (no markdown fences) with shape:
            {"summary":"One-sentence description of what changed","pack_json":{...complete valid v3 pack.json...},"files":{"commands/example.py":"#!/usr/bin/env python3\\n..."}}
            Rules:
            - MUST keep format_version=2, schema_version=3, and id="\(pack.id)".
            - Preserve existing commands, capabilities, preferences, scope, and permissions unless the user asked to modify or remove one.
            - Scripts must read context JSON from `sys.stdin` and never read secrets from env vars; output DoraxCommandOutput JSON (`{"items":[...],"detail":{...}}`).
            - Any hook in `hooks[]` MUST declare a non-empty `filter` and matching permission in `permissions[]`.
            - Paths in `files` must be relative (e.g. `commands/my-cmd.py`, `AGENT.md`, `skills/s/SKILL.md`), never containing `..`.
            """
            let userMsg = """
            Upgrade Request:
            \(instruction)

            Existing pack.json:
            \(String(currentJSON.prefix(8_000)))
            """
            if let reply = try? await PanelAssistant.ask(
                userMsg,
                title: "DoraX AI Pack Architect",
                subtitle: "Upgrade \(pack.name) (.doraxpack v3)",
                extraPrompt: sysPrompt,
                history: [],
                provider: AppSettings.shared.selectedAIProvider
            ),
               let parsed = parseAIStructuredUpgrade(reply, basePack: pack, stagingRoot: stagingRoot)
            {
                return await finalizeStagedPatch(parsed, basePack: pack)
            }
            if let localReply = try? await DoraxAppleIntelligenceRunner.generateRaw(
                systemInstruction: sysPrompt,
                prompt: userMsg
            ),
               let parsed = parseAIStructuredUpgrade(localReply, basePack: pack, stagingRoot: stagingRoot)
            {
                return await finalizeStagedPatch(parsed, basePack: pack)
            }
        }

        // Deterministic offline / fallback upgrade builder
        let fallback = buildDeterministicUpgradePatch(pack: pack, instruction: instruction, stagingRoot: stagingRoot)
        return await finalizeStagedPatch(fallback, basePack: pack)
    }

    private struct RawAIUpgradeDraft {
        var summary: String
        var packJSONText: String
        var files: [DoraxPackV3FileChange]
        var stagingFolder: URL
    }

    private static func parseAIStructuredUpgrade(
        _ raw: String,
        basePack: DoraxPackV2,
        stagingRoot: URL?
    ) -> RawAIUpgradeDraft? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              let data = String(trimmed[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var packObj = obj["pack_json"] as? [String: Any]
        else { return nil }

        packObj["format_version"] = 2
        packObj["schema_version"] = 3
        packObj["id"] = basePack.id

        guard let normalizedData = try? JSONSerialization.data(withJSONObject: packObj, options: [.prettyPrinted, .sortedKeys]),
              let decodedMeta = try? JSONDecoder().decode(DoraxPackMetadata.self, from: normalizedData),
              let jsonText = String(data: normalizedData, encoding: .utf8)
        else { return nil }

        _ = decodedMeta // validated decode
        let summary = (obj["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawFiles = obj["files"] as? [String: String] ?? [:]
        var changes: [DoraxPackV3FileChange] = []
        for (rel, content) in rawFiles.sorted(by: { $0.key < $1.key }) {
            guard let safeRel = DoraxPackV3EditorService.validateRelativePath(rel) else { continue }
            let existed = FileManager.default.fileExists(atPath: basePack.folderURL.appendingPathComponent(safeRel).path)
            changes.append(DoraxPackV3FileChange(relativePath: safeRel, content: content, isNew: !existed))
        }

        let stageFolder = makeStagingFolder(pack: basePack, packJSON: jsonText, files: changes, stagingRoot: stagingRoot)
        return RawAIUpgradeDraft(
            summary: (summary?.isEmpty == false ? summary! : "Upgraded \(basePack.name) with AI."),
            packJSONText: jsonText,
            files: changes,
            stagingFolder: stageFolder)
    }

    private static func buildDeterministicUpgradePatch(
        pack: DoraxPackV2,
        instruction: String,
        stagingRoot: URL?
    ) -> RawAIUpgradeDraft {
        var meta = pack.metadata
        meta.formatVersion = 2
        meta.schemaVersion = 3
        meta.version = bumpPatchVersion(meta.version)

        var changes: [DoraxPackV3FileChange] = []
        let cleanInstr = instruction.isEmpty ? "Custom quick command" : instruction
        let lower = cleanInstr.lowercased()

        // If user specifically requested a hex color tint change, update tint while keeping commands
        if let hexRange = cleanInstr.range(of: "#[0-9A-Fa-f]{6}", options: .regularExpression) {
            let newHex = String(cleanInstr[hexRange]).uppercased()
            let currentGlow = meta.appearance?.glow.normalized ?? .soft
            meta.appearance = DoraxPackAppearance(tint: newHex, glow: currentGlow == .none ? .soft : currentGlow)
        }

        let slug = slugify(String(cleanInstr.prefix(36)), fallback: "custom-action")
        let cmdID = uniqueCommandID(slug: slug, existing: Set((meta.commands ?? []).map(\.id)))
        let title = String(cleanInstr.prefix(42)).capitalized
        let scriptRel = "commands/\(cmdID).py"

        let newCmd = DoraxPackCommand(
            id: cmdID,
            title: title,
            subtitle: "Upgraded workflow for \(pack.name): \(cleanInstr)",
            icon: lower.contains("notch") ? "waveform.path.ecg" : "sparkles",
            mode: lower.contains("notch") ? .notch : .list,
            keywords: [pack.id, slug, "upgraded"],
            script: scriptRel,
            timeoutSeconds: 6,
            cacheTTLSeconds: 15,
            safety: "read")

        var cmds = meta.commands ?? []
        cmds.append(newCmd)
        meta.commands = cmds

        var caps = meta.capabilities
        caps.append(PluginPackCapability(
            id: "\(pack.id).\(cmdID)",
            name: title,
            intent: cleanInstr,
            triggers: [title.lowercased(), "\(pack.id) \(slug)"],
            type: "aiPrompt",
            script: cleanInstr,
            safety: "read"))
        meta.capabilities = caps

        let pyScript: String
        if lower.contains("notch") {
            let tint = meta.appearance?.tint ?? "#38BDF8"
            pyScript = """
            #!/usr/bin/env python3
            import json, sys
            _ = sys.stdin.read()
            print(json.dumps({
                "notch": {
                    "wing_text": "\(String(pack.name.prefix(10)))",
                    "wing_icon": "\(meta.icon)",
                    "wing_color": "\(tint)",
                    "title": "\(pack.name) · \(title.replacingOccurrences(of: "\"", with: ""))",
                    "subtitle": "Live status from upgraded command"
                },
                "toast": "Pinned \(pack.name) to Dynamic Notch"
            }))
            """
        } else {
            pyScript = """
            #!/usr/bin/env python3
            import json, sys
            try:
                ctx = json.loads(sys.stdin.read().strip() or "{}")
            except Exception:
                ctx = {}
            q = (ctx.get("query") or "").strip()
            front = (ctx.get("frontmost") or {}).get("appName") or "\(pack.name)"
            print(json.dumps({
                "items": [{
                    "id": "\(cmdID)-ready",
                    "title": "\(title.replacingOccurrences(of: "\"", with: ""))",
                    "subtitle": f"Context: {front}" + (f" · Query: {q}" if q else ""),
                    "icon": "sparkles",
                    "detail": {
                        "markdown": "### \(title.replacingOccurrences(of: "\"", with: ""))\\n\\nAdded to **\(pack.name)** via AI Pack Architect.\\n\\nEdit `\(scriptRel)` to customize live data fetching.",
                        "metadata": [{"label": "Pack", "value": "\(pack.name)"}, {"label": "Version", "value": "\(meta.version)"}]
                    },
                    "actions": [
                        {"id": "copy-summary", "title": "Copy Summary", "icon": "doc.on.doc", "shortcut": "↵", "kind": "copy", "value": "\(title.replacingOccurrences(of: "\"", with: ""))"}
                    ]
                }]
            }))
            """
        }
        changes.append(DoraxPackV3FileChange(relativePath: scriptRel, content: pyScript, isNew: true))

        let jsonText = encodeMetadata(meta)
        let stageFolder = makeStagingFolder(pack: pack, packJSON: jsonText, files: changes, stagingRoot: stagingRoot)
        return RawAIUpgradeDraft(
            summary: "Added \"\(title)\" (\(scriptRel)) to \(pack.name) v\(meta.version), keeping all \(max(0, (pack.metadata.commands ?? []).count)) existing command(s).",
            packJSONText: jsonText,
            files: changes,
            stagingFolder: stageFolder)
    }

    private static func makeStagingFolder(
        pack: DoraxPackV2,
        packJSON: String,
        files: [DoraxPackV3FileChange],
        stagingRoot: URL?
    ) -> URL {
        let base = stagingRoot ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("doraxpack-v3-upgrade-staging", isDirectory: true)
        let folder = base.appendingPathComponent("\(pack.id)-\(UUID().uuidString.prefix(6)).doraxpack", isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        if fm.fileExists(atPath: pack.folderURL.path) {
            try? fm.copyItem(at: pack.folderURL, to: folder)
        } else {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try? Data(packJSON.utf8).write(to: folder.appendingPathComponent("pack.json"), options: .atomic)
        for change in files {
            guard let safe = DoraxPackV3EditorService.validateRelativePath(change.relativePath) else { continue }
            let dest = folder.appendingPathComponent(safe)
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(change.content.utf8).write(to: dest, options: .atomic)
            if ["py", "sh", "zsh"].contains(dest.pathExtension.lowercased()) {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            }
        }
        return folder
    }

    private static func finalizeStagedPatch(_ draft: RawAIUpgradeDraft, basePack: DoraxPackV2) async -> DoraxPackV3Patch {
        let loaded = (try? DoraxPackV2Loader.load(from: draft.stagingFolder))
            ?? DoraxPackV2(
                metadata: basePack.metadata, agentInstructions: basePack.agentInstructions,
                modes: basePack.modes, skills: basePack.skills, scripts: basePack.scripts,
                pageScripts: basePack.pageScripts, folderURL: draft.stagingFolder)
        let diagnostics = DoraxPackV3Validator.validate(loaded)

        let existingIDs = Set((basePack.metadata.commands ?? []).map(\.id))
        let targetCmd = (loaded.metadata.commands ?? []).first { !existingIDs.contains($0.id) && $0.safety.lowercased() == "read" }
            ?? (loaded.metadata.commands ?? []).first { $0.safety.lowercased() == "read" }

        var dryOutput: DoraxCommandOutput? = nil
        var dryError: String? = nil
        if let cmd = targetCmd {
            let res = await DoraxPackV3Runtime.shared.runCommand(cmd, in: loaded, forceRefresh: true)
            switch res {
            case .success(let out): dryOutput = out
            case .failure(let err): dryError = err.message
            }
        }

        let oldPerms = Set(basePack.metadata.permissions ?? [])
        let newPerms = (loaded.metadata.permissions ?? []).filter { !oldPerms.contains($0) }
        let oldHooks = Set((basePack.metadata.hooks ?? []).map(\.id))
        let newHooks = (loaded.metadata.hooks ?? []).filter { !oldHooks.contains($0.id) }.map { "\($0.id) (\($0.on.rawValue))" }

        return DoraxPackV3Patch(
            packID: loaded.id,
            packName: loaded.name,
            summary: draft.summary,
            updatedPackJSON: draft.packJSONText,
            files: draft.files,
            addedPermissions: newPerms,
            addedHooks: newHooks,
            diagnostics: diagnostics,
            dryRunOutput: dryOutput,
            dryRunError: dryError,
            stagedFolderURL: draft.stagingFolder)
    }

    static func encodeMetadata(_ metadata: DoraxPackMetadata) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(metadata)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func slugify(_ raw: String, fallback: String = "command") -> String {
        let s = raw.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return s.isEmpty ? fallback : s
    }

    private static func uniqueCommandID(slug: String, existing: Set<String>) -> String {
        if !existing.contains(slug) { return slug }
        var idx = 2
        while existing.contains("\(slug)-\(idx)") { idx += 1 }
        return "\(slug)-\(idx)"
    }

    private static func bumpPatchVersion(_ version: String) -> String {
        let parts = version.split(separator: ".").map(String.init)
        guard parts.count == 3, let patch = Int(parts[2]) else { return "3.0.1" }
        return "\(parts[0]).\(parts[1]).\(patch + 1)"
    }
}
