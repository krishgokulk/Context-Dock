// Context-Dock/Services/AutonomousAppDiscoveryEngine.swift
// Context-Dock
//
// 2-Stage Autonomous Discovery Engine (CLI, Deep Links, Web Docs & GitHub)
// Reference: docs/architecture/APP_KNOWLEDGE_SKILLS.md (§3)
// Reference: docs/superpowers/specs/2026-11-05-streamline-settings-and-extensions.md (§2.2)

import AppKit
import Foundation

/// A discovered CLI binary on user PATH matching an installed application.
struct DiscoveredCLITool: Identifiable, Equatable {
    var id: String { path }
    let name: String
    let command: String
    let path: String
}

/// The outcome of running autonomous knowledge enrichment for an app.
struct AppEnrichmentResult: Equatable {
    let bundleId: String
    let appName: String
    let version: String
    let discoveredCLIs: [String]
    let urlSchemes: [String]
    let updatedSkill: Bool
    let updatedAgentProfile: Bool
    let documentationSnippetLength: Int
}

@MainActor
enum AutonomousAppDiscoveryEngine {

    /// Standard user binary search directories where package managers and developers place CLIs.
    nonisolated static var defaultScanDirectories: [String] {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin",
            "\(home)/.local/bin",
            "/usr/local/bin"
        ]
    }

    // MARK: - Candidate CLI Generation

    /// Returns candidate CLI executable names for a given app based on known vendors and heuristics.
    nonisolated static func candidateBinaryNames(bundleId: String, appName: String) -> [String] {
        var names: [String] = []
        let lowerBundle = bundleId.lowercased()
        let lowerName = appName.lowercased()

        // 1. Well-known vendor tool mappings
        if lowerBundle.contains("antigravity") || lowerName.contains("antigravity") {
            names.append(contentsOf: ["agy", "antigravity"])
        }
        if lowerBundle.contains("vscode") || lowerBundle.contains("visualstudio.code")
            || lowerName == "code" || lowerName.contains("vs code") || lowerName.contains("visual studio code") {
            names.append("code")
        }
        if lowerBundle.contains("githubclient") || lowerName.contains("github desktop") || lowerName == "github" {
            names.append(contentsOf: ["gh", "git"])
        }
        if lowerBundle.contains("ghostty") || lowerName.contains("ghostty") {
            names.append("ghostty")
        }
        if lowerBundle.contains("sublime") || lowerName.contains("sublime") {
            names.append("subl")
        }
        if lowerBundle.contains("cursor") || lowerName.contains("cursor") {
            names.append("cursor")
        }
        if lowerBundle.contains("docker") || lowerName.contains("docker") {
            names.append(contentsOf: ["docker", "docker-compose"])
        }
        if lowerBundle.contains("postman") || lowerName.contains("postman") {
            names.append(contentsOf: ["postman", "newman"])
        }
        if lowerBundle.contains("iterm") || lowerName.contains("iterm") {
            names.append("iterm2")
        }
        if lowerBundle.contains("xcode") || lowerName.contains("xcode") {
            names.append(contentsOf: ["xcodebuild", "xcrun", "simctl"])
        }
        if lowerBundle.contains("spotify") || lowerName.contains("spotify") {
            names.append(contentsOf: ["spotify", "spt"])
        }
        if lowerBundle.contains("handbrake") || lowerName.contains("handbrake") {
            names.append(contentsOf: ["HandBrakeCLI", "handbrake"])
        }
        if lowerBundle.contains("obsidian") || lowerName.contains("obsidian") {
            names.append("obsidian")
        }
        if lowerBundle.contains("raycast") || lowerName.contains("raycast") {
            names.append("raycast")
        }

        // 2. Generic heuristics
        let trimmedName = lowerName.replacingOccurrences(of: " ", with: "")
        if !trimmedName.isEmpty {
            names.append(trimmedName)
            names.append("\(trimmedName)-cli")
        }
        let hyphenated = lowerName.replacingOccurrences(of: " ", with: "-")
        if hyphenated != trimmedName && !hyphenated.isEmpty {
            names.append(hyphenated)
            names.append("\(hyphenated)-cli")
        }
        if let lastComponent = lowerBundle.split(separator: ".").last, !lastComponent.isEmpty {
            let lastStr = String(lastComponent)
            names.append(lastStr)
            names.append("\(lastStr)-cli")
        }

        // Deduplicate while preserving discovery order
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }
    }

    // MARK: - PATH Auto-Discovery

    /// Scans directories for matching candidate CLI binaries.
    nonisolated static func discoverCLITools(
        bundleId: String,
        appName: String,
        scanDirectories: [String] = defaultScanDirectories,
        isExecutable: ((String) -> Bool)? = nil
    ) -> [DiscoveredCLITool] {
        let candidates = candidateBinaryNames(bundleId: bundleId, appName: appName)
        let checkExecutable = isExecutable ?? { path in
            FileManager.default.isExecutableFile(atPath: path)
        }

        var results: [DiscoveredCLITool] = []
        var seenCommands = Set<String>()

        for candidate in candidates {
            for dir in scanDirectories {
                let expandedDir = NSString(string: dir).expandingTildeInPath
                let fullPath = (expandedDir as NSString).appendingPathComponent(candidate)
                if checkExecutable(fullPath) {
                    if seenCommands.insert(candidate.lowercased()).inserted {
                        results.append(DiscoveredCLITool(
                            name: candidate,
                            command: candidate,
                            path: fullPath))
                        break
                    }
                }
            }
        }

        return results
    }

    // MARK: - Bundle Introspection

    /// Extracts URL schemes declared in the app bundle's Info.plist (`CFBundleURLTypes`).
    nonisolated static func extractURLSchemes(
        bundleId: String,
        bundleURLResolver: ((String) -> URL?)? = nil
    ) -> [String] {
        let resolver = bundleURLResolver ?? { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        }
        guard let url = resolver(bundleId),
              let bundle = Bundle(url: url),
              let urlTypes = bundle.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]]
        else { return [] }

        var schemes: [String] = []
        for type in urlTypes {
            if let typeSchemes = type["CFBundleURLSchemes"] as? [String] {
                schemes.append(contentsOf: typeSchemes)
            }
        }
        var seen = Set<String>()
        return schemes.filter { seen.insert($0.lowercased()).inserted }.sorted()
    }

    /// Reads CFBundleShortVersionString or CFBundleVersion from the bundle.
    nonisolated static func installedVersion(
        bundleId: String,
        bundleURLResolver: ((String) -> URL?)? = nil
    ) -> String {
        let resolver = bundleURLResolver ?? { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        }
        guard let url = resolver(bundleId),
              let info = Bundle(url: url)?.infoDictionary
        else { return "" }
        return (info["CFBundleShortVersionString"] as? String)
            ?? (info["CFBundleVersion"] as? String)
            ?? ""
    }

    // MARK: - One-Click CLI Linking

    /// Links a discovered CLI tool to an app adapter.
    static func linkCLITool(
        _ tool: DiscoveredCLITool,
        toBundleId bundleId: String,
        appName: String
    ) {
        let pkgMgr = TerminalPackageManager.shared
        if let existing = pkgMgr.packages.first(where: {
            $0.command.caseInsensitiveCompare(tool.command) == .orderedSame
                || ($0.installedPath != nil && $0.installedPath == tool.path)
        }) {
            var updated = existing
            if !updated.contextAppBundleIds.contains(bundleId) {
                updated.contextAppBundleIds.append(bundleId)
                pkgMgr.updatePackage(updated)
            }
            pkgMgr.ensureHelpScanned(command: tool.command)
        } else {
            let pkg = TerminalPackage(
                id: UUID(),
                name: tool.name,
                command: tool.command,
                description: "Command-line tool for \(appName)",
                installedPath: tool.path,
                keywords: [tool.command, tool.name, appName],
                usageExamples: [],
                readmeContent: nil,
                isEnabled: true,
                customNotes: "",
                helpText: nil,
                subcommands: [],
                usagePattern: nil,
                taskCategories: [],
                contextAppBundleIds: [bundleId],
                contextualExamples: []
            )
            pkgMgr.addPackage(pkg)
            pkgMgr.ensureHelpScanned(command: tool.command)
        }
    }

    // MARK: - Autonomous Knowledge Enrichment

    /// Runs Stage 1 & Stage 2 enrichment for an app:
    /// - Discovers PATH CLI tools
    /// - Extracts Info.plist URL schemes
    /// - Ingests official documentation / README (once per version, cached)
    /// - Persists findings into `<App> — what this app is` skill in `SkillStore`
    /// - Persists operating rules & routes into `AGENT.md` in `AppAgentProfileStore`
    @discardableResult
    static func enrich(
        bundleId: String,
        appName: String,
        scanDirectories: [String] = defaultScanDirectories,
        bundleURLResolver: ((String) -> URL?)? = nil,
        isExecutable: ((String) -> Bool)? = nil,
        websiteDocsProvider: ((String, String, String?) async -> String?)? = nil
    ) async -> AppEnrichmentResult {
        let version = installedVersion(bundleId: bundleId, bundleURLResolver: bundleURLResolver)
        let effectiveVersion = version.isEmpty ? "1.0" : version
        let urlSchemes = extractURLSchemes(bundleId: bundleId, bundleURLResolver: bundleURLResolver)
        let discoveredTools = discoverCLITools(
            bundleId: bundleId,
            appName: appName,
            scanDirectories: scanDirectories,
            isExecutable: isExecutable)

        // 1. Kick on-demand background help scans for discovered tools
        for tool in discoveredTools {
            TerminalPackageManager.shared.ensureHelpScanned(command: tool.command)
        }

        // 2. Fetch or retrieve cached docs (adheres to Outbound Privacy Gate: cached per version)
        var docText: String? = nil
        let adapter = AppAdapterManager.shared.adapter(for: bundleId)
        let website = adapter?.website
        if let docsProvider = websiteDocsProvider {
            docText = await docsProvider(bundleId, effectiveVersion, website)
        } else if let website, AppWebsiteKnowledge.fetchableURL(from: website) != nil {
            docText = await AppWebsiteKnowledge.knowledge(
                bundleId: bundleId,
                version: effectiveVersion,
                website: website)
        }

        // 3. Assemble and persist <App> — what this app is into SkillStore
        let helpMenuTitles = AppMenuCapabilityCache.shared
            .menuItems(bundleIdentifier: bundleId, appName: appName, maxResults: 400)
            .filter { $0.path.first == "Help" && $0.path.count > 1 }
            .map(\.title)

        let capabilities = AppKnowledgeSkill.Capabilities(
            actions: adapter?.actions.count ?? 0,
            cliTools: ScopedGroundingBlocks.runnableCommandBinaries(forBundleId: bundleId).count + discoveredTools.count,
            skills: SkillStore.shared.skills(for: bundleId).filter { $0.id != AppKnowledgeSkill.id(for: bundleId) }.count,
            menuCommands: AppMenuCapabilityCache.shared.summary(bundleIdentifier: bundleId)?.recordCount ?? 0,
            mcpServers: MCPServerManager.shared.servers(forBundleId: bundleId).count,
            apiConnections: APIConnectionStore.shared.connections(for: bundleId).count
        )

        var updatedSkill = false
        if var skill = AppKnowledgeSkill.make(
            bundleId: bundleId,
            appName: appName,
            version: effectiveVersion,
            helpTitles: helpMenuTitles,
            capabilities: capabilities,
            websiteKnowledge: docText,
            urlSchemes: urlSchemes,
            discoveredCLIs: discoveredTools.map(\.command)
        ) {
            if let existing = SkillStore.shared.skills(for: bundleId).first(where: { $0.id == skill.id }) {
                skill.isEnabled = existing.isEnabled
            }
            SkillStore.shared.upsert(skill)
            updatedSkill = true
        }

        // 4. Assemble and persist AGENT.md into AppAgentProfileStore
        var updatedProfile = false
        var profile = AppAgentProfileStore.shared.profile(forBundleID: bundleId, appName: appName)
            ?? AppAgentProfileStore.shared.draft(forBundleID: bundleId, appName: appName)

        var cliSet = Set(profile.tools.cli ?? [])
        for tool in discoveredTools {
            cliSet.insert(tool.command)
        }
        if !cliSet.isEmpty {
            profile.tools.cli = Array(cliSet).sorted()
        }

        let safetyRule = "Delete files, quit \(appName), or execute destructive commands without explicit user confirmation."
        if !profile.never.contains(where: { $0.localizedCaseInsensitiveContains("quit") || $0.localizedCaseInsensitiveContains("delete") }) {
            profile.never.append(safetyRule)
        }

        var extraLines: [String] = []
        if !urlSchemes.isEmpty, !profile.instructions.contains("URL schemes") {
            extraLines.append("Supported URL deep link schemes: \(urlSchemes.map { "\($0)://" }.joined(separator: ", ")).")
        }
        if !discoveredTools.isEmpty, !profile.instructions.contains("CLI accelerators") {
            let cmds = discoveredTools.map(\.command).joined(separator: ", ")
            extraLines.append("Available CLI accelerators: \(cmds). Prefer direct CLI commands for headless operations.")
        }
        if let docSnippet = docText, !docSnippet.isEmpty, !profile.instructions.contains("Product Overview") {
            let snippet = docSnippet.prefix(500)
            extraLines.append("Product Overview: \(snippet)...")
        }

        if !extraLines.isEmpty {
            if !profile.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profile.instructions += "\n\n"
            }
            profile.instructions += extraLines.joined(separator: "\n")
        }

        do {
            try AppAgentProfileStore.shared.save(profile, forBundleID: bundleId)
            AppAgentProfileStore.shared.invalidate(bundleID: bundleId)
            updatedProfile = true
        } catch {
            // Non-fatal
        }

        return AppEnrichmentResult(
            bundleId: bundleId,
            appName: appName,
            version: effectiveVersion,
            discoveredCLIs: discoveredTools.map(\.command),
            urlSchemes: urlSchemes,
            updatedSkill: updatedSkill,
            updatedAgentProfile: updatedProfile,
            documentationSnippetLength: docText?.count ?? 0
        )
    }
}
