// Context-DockTests/AutonomousAppDiscoveryTests.swift
// Context-Dock
//
// Unit tests for Autonomous App Discovery & CLI Linker (Follow-up to #373).
// Covers:
// 1. Candidate binary generation across well-known vendors and heuristics
// 2. PATH scanning across /opt/homebrew/bin, ~/.local/bin, /usr/local/bin
// 3. One-click CLI linking into TerminalPackageManager and contextAppBundleIds
// 4. AppKnowledgeSkill enriched formatting with URL schemes and CLI accelerators
// 5. Autonomous Knowledge Enrichment persistence into SkillStore and AGENT.md

import Foundation
import Testing

@testable import Context_Dock

@MainActor
@Suite(.serialized)
struct AutonomousAppDiscoveryTests {

    // MARK: - 1. Candidate Binary Generation

    @Test("Candidate binary names identify vendor tools and algorithmic heuristics")
    func candidateBinaryNamesMatchKnownApps() {
        // Antigravity -> agy, antigravity
        let agyCandidates = AutonomousAppDiscoveryEngine.candidateBinaryNames(
            bundleId: "com.google.antigravity",
            appName: "Antigravity")
        #expect(agyCandidates.contains("agy"))
        #expect(agyCandidates.contains("antigravity"))

        // VS Code -> code
        let vscodeCandidates = AutonomousAppDiscoveryEngine.candidateBinaryNames(
            bundleId: "com.microsoft.VSCode",
            appName: "Visual Studio Code")
        #expect(vscodeCandidates.contains("code"))

        // GitHub Desktop -> gh, git
        let ghCandidates = AutonomousAppDiscoveryEngine.candidateBinaryNames(
            bundleId: "com.github.GitHubClient",
            appName: "GitHub Desktop")
        #expect(ghCandidates.contains("gh"))
        #expect(ghCandidates.contains("git"))

        // Generic app -> heuristics
        let genericCandidates = AutonomousAppDiscoveryEngine.candidateBinaryNames(
            bundleId: "io.ffmpeg.player",
            appName: "FFmpeg Player")
        #expect(genericCandidates.contains("ffmpegplayer"))
        #expect(genericCandidates.contains("ffmpeg-player"))
        #expect(genericCandidates.contains("player"))
    }

    // MARK: - 2. PATH Auto-Discovery

    @Test("CLI discovery scans specified PATH directories and identifies executable tools")
    func cliDiscoveryDetectsMatchingBinaries() {
        let mockScanDirs = ["/opt/homebrew/bin", "/usr/local/bin"]
        let mockExecutablePaths: Set<String> = [
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/code"
        ]

        let discovered = AutonomousAppDiscoveryEngine.discoverCLITools(
            bundleId: "com.google.antigravity",
            appName: "Antigravity",
            scanDirectories: mockScanDirs,
            isExecutable: { mockExecutablePaths.contains($0) })

        #expect(discovered.count == 1)
        #expect(discovered.first?.command == "agy")
        #expect(discovered.first?.path == "/opt/homebrew/bin/agy")
    }

    // MARK: - 3. One-Click CLI Linking

    @Test("Linking a discovered CLI attaches bundleId to TerminalPackage in TerminalPackageManager")
    func linkingDiscoveredCLIAttachesBundleId() {
        let pkgMgr = TerminalPackageManager.shared
        let testBundleID = "com.test.antigravity.cli.\(UUID().uuidString)"
        let tool = DiscoveredCLITool(
            name: "agy-test",
            command: "agy-test-\(UUID().uuidString.prefix(6))",
            path: "/opt/homebrew/bin/agy-test")

        AutonomousAppDiscoveryEngine.linkCLITool(
            tool,
            toBundleId: testBundleID,
            appName: "Antigravity Test")

        let linked = pkgMgr.packages.first { $0.command == tool.command }
        #expect(linked != nil)
        #expect(linked?.contextAppBundleIds.contains(testBundleID) == true)

        // Cleanup
        if let linked {
            pkgMgr.removePackage(linked)
        }
    }

    // MARK: - 4. Skill Formatting with URL Schemes and CLI Accelerators

    @Test("AppKnowledgeSkill formats instructions with URL schemes and CLI accelerators")
    func appKnowledgeSkillIncludesURLSchemesAndCLIs() throws {
        let skill = try #require(AppKnowledgeSkill.make(
            bundleId: "com.microsoft.VSCode",
            appName: "Code",
            version: "1.96.0",
            helpTitles: ["Documentation", "Interactive Playground"],
            capabilities: .init(actions: 1, cliTools: 1, skills: 0, menuCommands: 10, mcpServers: 0, apiConnections: 0),
            websiteKnowledge: "Official VS Code Editor by Microsoft",
            urlSchemes: ["vscode", "vscode-insiders"],
            discoveredCLIs: ["code"]))

        #expect(skill.instructions.contains("vscode://"))
        #expect(skill.instructions.contains("vscode-insiders://"))
        #expect(skill.instructions.contains("Command-line accelerators available on PATH:"))
        #expect(skill.instructions.contains("- code"))
        #expect(skill.instructions.contains("Documentation"))
    }

    // MARK: - 5. Autonomous Knowledge Enrichment

    @Test("Enrichment persists learned knowledge into SkillStore and AGENT.md")
    func autonomousEnrichmentPersistsSkillAndAgentProfile() async throws {
        let testBundleID = "com.test.discovery.enrichment.\(UUID().uuidString)"
        let testAppName = "EnrichedApp"
        let mockScanDirs = ["/opt/homebrew/bin"]
        let mockExecutablePaths: Set<String> = [
            "/opt/homebrew/bin/enrichedapp"
        ]

        let result = await AutonomousAppDiscoveryEngine.enrich(
            bundleId: testBundleID,
            appName: testAppName,
            scanDirectories: mockScanDirs,
            bundleURLResolver: { _ in nil },
            isExecutable: { mockExecutablePaths.contains($0) },
            websiteDocsProvider: { _, _, _ in
                "EnrichedApp is an autonomous orchestration platform with high performance."
            })

        #expect(result.bundleId == testBundleID)
        #expect(result.appName == testAppName)
        #expect(result.discoveredCLIs.contains("enrichedapp"))
        #expect(result.updatedSkill == true)
        #expect(result.updatedAgentProfile == true)

        // Verify SkillStore persistence
        let skill = SkillStore.shared.skills(for: testBundleID)
            .first { $0.id == AppKnowledgeSkill.id(for: testBundleID) }
        #expect(skill != nil)
        #expect(skill?.name == "\(testAppName) — what this app is")
        #expect(skill?.instructions.contains("enrichedapp") == true)

        // Verify AGENT.md in AppAgentProfileStore persistence
        let profile = AppAgentProfileStore.shared.profile(forBundleID: testBundleID, appName: testAppName)
        #expect(profile != nil)
        #expect(profile?.tools.cli?.contains("enrichedapp") == true)
        #expect(profile?.never.isEmpty == false)

        // Cleanup
        if let skill {
            SkillStore.shared.remove(id: skill.id)
        }
        let profileFile = AppAgentProfileStore.shared.fileURL(forBundleID: testBundleID)
        try? FileManager.default.removeItem(at: profileFile.deletingLastPathComponent())
        AppAgentProfileStore.shared.invalidate(bundleID: testBundleID)
    }
}
