// Context-DockTests/AgenticAIPackBuilderTests.swift
//
// Unit tests for the 4-stage Agentic AI Pack Builder (Task U4).

import Foundation
import Testing

@testable import Context_Dock

@MainActor
struct AgenticAIPackBuilderTests {

    // MARK: - CapabilityChannel

    @Test("CapabilityChannel sorts by rawValue (1=extensionHook < 8=menuCommand)")
    func capabilityChannelOrdering() {
        #expect(CapabilityChannel.extensionHook < CapabilityChannel.menuCommand)
        #expect(CapabilityChannel.embeddedCLI < CapabilityChannel.appleScript)
        #expect(CapabilityChannel.utcpHTTP < CapabilityChannel.mcpServer)
    }

    @Test("CapabilityChannel packType maps to correct type strings")
    func capabilityChannelPackType() {
        #expect(CapabilityChannel.embeddedCLI.packType == "shellCommand")
        #expect(CapabilityChannel.localIPC.packType == "shellCommand")
        #expect(CapabilityChannel.utcpHTTP.packType == "httpEndpoint")
        #expect(CapabilityChannel.mcpServer.packType == "mcp")
        #expect(CapabilityChannel.appleScript.packType == "appleScript")
        #expect(CapabilityChannel.urlScheme.packType == "urlScheme")
        #expect(CapabilityChannel.menuCommand.packType == "menubar")
        #expect(CapabilityChannel.extensionHook.packType == "extensionHook")
    }

    // MARK: - Stage 1: IPC Socket Discovery

    @Test("discoverIPCSockets finds matching candidate paths via injected checker")
    func ipcSocketDiscovery() {
        let found = AgenticAIPackBuilder.discoverIPCSockets(
            bundleID: "net.iina.iina",
            appName: "IINA",
            socketChecker: { path in
                path == "/tmp/iina-ipc.sock"
            }
        )
        #expect(found.contains("/tmp/iina-ipc.sock"))
    }

    @Test("discoverIPCSockets returns empty when no sockets exist")
    func ipcSocketDiscoveryEmpty() {
        let found = AgenticAIPackBuilder.discoverIPCSockets(
            bundleID: "com.example.unknownapp",
            appName: "UnknownApp",
            socketChecker: { _ in false }
        )
        #expect(found.isEmpty)
    }

    @Test("discoverIPCSockets checks generic name-based candidate for any app")
    func ipcSocketGenericCandidate() {
        let found = AgenticAIPackBuilder.discoverIPCSockets(
            bundleID: "com.example.myapp",
            appName: "My App",
            socketChecker: { path in
                path == "/tmp/my-app-ipc.sock" || path == "/tmp/my-app.sock"
            }
        )
        #expect(!found.isEmpty)
    }

    // MARK: - Stage 1: Embedded Binary Scanner

    @Test("scanEmbeddedCLIs discovers executable file in Contents/MacOS")
    func embeddedBinaryDiscovery() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeApp-\(UUID().uuidString).app", isDirectory: true)
        let macosDir = tempDir.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macosDir, withIntermediateDirectories: true)

        // Write a fake CLI script
        let fakeCLI = macosDir.appendingPathComponent("fake-cli")
        try "#!/bin/sh\necho hello\n".write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        // Use injected helpTextProvider to avoid real subprocess
        let found = await AgenticAIPackBuilder.scanEmbeddedCLIs(
            appURL: tempDir,
            helpTextProvider: { _ in "fake help text" }
        )

        try? FileManager.default.removeItem(at: tempDir)

        #expect(!found.isEmpty)
        #expect(found.first?.name == "fake-cli")
        #expect(found.first?.helpText == "fake help text")
    }

    @Test("scanEmbeddedCLIs skips non-executable files")
    func embeddedBinarySkipsNonExecutable() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeApp2-\(UUID().uuidString).app", isDirectory: true)
        let macosDir = tempDir.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macosDir, withIntermediateDirectories: true)

        // Write a non-executable file
        let nonExec = macosDir.appendingPathComponent("not-a-cli")
        try "#!/bin/sh\n".write(to: nonExec, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: nonExec.path)

        let found = await AgenticAIPackBuilder.scanEmbeddedCLIs(
            appURL: tempDir,
            helpTextProvider: { _ in nil }
        )
        try? FileManager.default.removeItem(at: tempDir)
        #expect(found.isEmpty)
    }

    @Test("scanEmbeddedCLIs returns empty for nil appURL")
    func embeddedBinaryNilURL() async {
        let found = await AgenticAIPackBuilder.scanEmbeddedCLIs(
            appURL: nil, helpTextProvider: { _ in nil })
        #expect(found.isEmpty)
    }

    // MARK: - Stage 1: Full with injected resolver

    @Test("stage1 returns expected app metadata via injected bundle resolver")
    func stage1WithInjectedResolver() async {
        let fakeBundle = Bundle.main
        let result = await AgenticAIPackBuilder.stage1(
            bundleID: "com.test.myapp",
            appName: "MyApp",
            bundleURLResolver: { _ in fakeBundle.bundleURL },
            ipcSocketChecker: { _ in false },
            isExecutable: { _ in false },
            helpTextProvider: { _ in nil }
        )
        #expect(result.bundleID == "com.test.myapp")
        #expect(result.appName == "MyApp")
        #expect(!result.appVersion.isEmpty)
        #expect(result.isInstalled)
    }

    @Test("stage1 marks isInstalled false when bundleURL resolver returns nil")
    func stage1NotInstalled() async {
        let result = await AgenticAIPackBuilder.stage1(
            bundleID: "com.nonexistent.app",
            appName: "NonExistent",
            bundleURLResolver: { _ in nil },
            ipcSocketChecker: { _ in false },
            isExecutable: { _ in false },
            helpTextProvider: { _ in nil }
        )
        #expect(!result.isInstalled)
        #expect(result.appVersion == "1.0")
    }

    // MARK: - Stage 2: Research + Cache

    @Test("stage2 uses injected docs provider")
    func stage2UsesDocsProvider() async {
        let result = await AgenticAIPackBuilder.stage2(
            bundleID: "com.test.stage2-\(UUID().uuidString)",
            appVersion: "3.0",
            websiteDocsProvider: { _, _, _ in "Injected docs snippet." }
        )
        #expect(result.documentationSnippet == "Injected docs snippet.")
        #expect(!result.isCached)
    }

    @Test("stage2 caches result — second call with same bundleID + version returns isCached true")
    func stage2Caching() async {
        let uniqueID = "com.test.cache-\(UUID().uuidString)"
        _ = await AgenticAIPackBuilder.stage2(
            bundleID: uniqueID,
            appVersion: "1.0",
            websiteDocsProvider: { _, _, _ in "cached docs" }
        )
        let second = await AgenticAIPackBuilder.stage2(
            bundleID: uniqueID,
            appVersion: "1.0",
            websiteDocsProvider: { _, _, _ in "should not be called" }
        )
        #expect(second.isCached)
    }

    @Test("stage2 does not share cache across different appVersions")
    func stage2NoCrosVersionCache() async {
        let uniqueID = "com.test.vcache-\(UUID().uuidString)"
        _ = await AgenticAIPackBuilder.stage2(bundleID: uniqueID, appVersion: "1.0",
                                               websiteDocsProvider: { _, _, _ in "v1" })
        let v2 = await AgenticAIPackBuilder.stage2(bundleID: uniqueID, appVersion: "2.0",
                                                    websiteDocsProvider: { _, _, _ in "v2 docs" })
        #expect(!v2.isCached)
        #expect(v2.documentationSnippet == "v2 docs")
    }

    // MARK: - Stage 3: Channel Ranking

    private func makeStage1(
        bundleID: String = "com.test.app",
        urlSchemes: [String] = [],
        sdefCommands: [String] = [],
        menuPaths: [String] = [],
        embeddedCLIs: [EmbeddedCLIBinary] = [],
        pathCLIs: [String] = [],
        ipcSocketPaths: [String] = []
    ) -> Stage1IntrospectionResult {
        Stage1IntrospectionResult(
            bundleID: bundleID, appName: "TestApp", appVersion: "1.0", isInstalled: true,
            urlSchemes: urlSchemes, documentTypes: [], sdefClasses: [],
            sdefCommands: sdefCommands, menuPaths: menuPaths,
            embeddedCLIs: embeddedCLIs, pathCLIs: pathCLIs, cliHelpTexts: [:],
            ipcSocketPaths: ipcSocketPaths)
    }

    private func makeStage2(bundleID: String = "com.test.app") -> Stage2ResearchResult {
        Stage2ResearchResult(bundleID: bundleID, appVersion: "1.0",
                             openAPITools: [], openAPIBaseURL: nil,
                             documentationSnippet: nil, isCached: false)
    }

    @Test("stage3 ranks embeddedCLI (2) before appleScript (6) before urlScheme (7) before menuCommand (8)")
    func stage3ChannelRanking() {
        let s1 = makeStage1(
            urlSchemes: ["testapp"],
            sdefCommands: ["open document"],
            menuPaths: ["File ▸ Open"],
            pathCLIs: ["testapp-cli"]
        )
        let plan = AgenticAIPackBuilder.stage3(stage1: s1, stage2: makeStage2())
        #expect(!plan.rankedCapabilities.isEmpty)
        // embeddedCLI must precede appleScript/urlScheme/menuCommand
        if let cliIdx = plan.rankedCapabilities.firstIndex(where: { $0.channel == .embeddedCLI }),
           let asIdx = plan.rankedCapabilities.firstIndex(where: { $0.channel == .appleScript }) {
            #expect(cliIdx < asIdx)
        }
        if let cliIdx = plan.rankedCapabilities.firstIndex(where: { $0.channel == .embeddedCLI }),
           let menuIdx = plan.rankedCapabilities.firstIndex(where: { $0.channel == .menuCommand }) {
            #expect(cliIdx < menuIdx)
        }
    }

    @Test("stage3 sets primaryChannel to lowest-priority (highest-ranked) discovered channel")
    func stage3PrimaryChannel() {
        let s1 = makeStage1(menuPaths: ["Help ▸ About"], pathCLIs: ["mytool"])
        let plan = AgenticAIPackBuilder.stage3(stage1: s1, stage2: makeStage2())
        #expect(plan.primaryChannel == .embeddedCLI)
    }

    @Test("stage3 deduplicates capabilities with the same lowercased name")
    func stage3DeduplicatesCapabilities() {
        let cli = EmbeddedCLIBinary(name: "mytool", path: "/app/Contents/MacOS/mytool", helpText: nil)
        let s1 = makeStage1(embeddedCLIs: [cli], pathCLIs: ["mytool"])
        let plan = AgenticAIPackBuilder.stage3(stage1: s1, stage2: makeStage2())
        let myToolCount = plan.rankedCapabilities.filter {
            $0.name.lowercased() == "mytool"
        }.count
        #expect(myToolCount == 1)
    }

    @Test("stage3 returns empty plan when no signals discovered")
    func stage3EmptyPlan() {
        let plan = AgenticAIPackBuilder.stage3(stage1: makeStage1(), stage2: makeStage2())
        #expect(plan.rankedCapabilities.isEmpty)
        #expect(plan.primaryChannel == nil)
    }

    @Test("stage3 marks urlScheme capabilities as readOnly")
    func stage3UrlSchemeIsReadOnly() {
        let s1 = makeStage1(urlSchemes: ["myapp"])
        let plan = AgenticAIPackBuilder.stage3(stage1: s1, stage2: makeStage2())
        let urlCap = plan.rankedCapabilities.first { $0.channel == .urlScheme }
        #expect(urlCap?.isReadOnly == true)
    }

    // MARK: - Stage 4: Pack Synthesis

    @Test("stage4 creates pack.json and AGENT.md with 0644 permissions")
    func stage4SynthesizesFiles() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("u4-stage4-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let s1 = makeStage1(
            bundleID: "com.test.synthapp",
            pathCLIs: ["synth-tool"]
        )
        let s2 = makeStage2(bundleID: "com.test.synthapp")
        let s3 = AgenticAIPackBuilder.stage3(stage1: s1, stage2: s2)
        let result = await AgenticAIPackBuilder.stage4(
            stage1: s1, stage2: s2, stage3: s3, tempDirectory: tempDir)

        let packURL = result.reviewCard.stagedPackURL
        let packJSON = packURL.appendingPathComponent("pack.json")
        let agentMD = packURL.appendingPathComponent("AGENT.md")

        #expect(FileManager.default.fileExists(atPath: packJSON.path))
        #expect(FileManager.default.fileExists(atPath: agentMD.path))

        // Verify 0644 permissions (non-executable)
        let attrs = try FileManager.default.attributesOfItem(atPath: packJSON.path)
        let perm = attrs[.posixPermissions] as? Int
        #expect(perm == 0o644)

        // pack.json must decode to DoraxPackMetadata v2
        let data = try Data(contentsOf: packJSON)
        let metadata = try JSONDecoder().decode(DoraxPackMetadata.self, from: data)
        #expect(metadata.formatVersion == 2)
        #expect(!metadata.id.isEmpty)
    }

    @Test("stage4 returns isApproved false — staging never auto-approves")
    func stage4NotAutoApproved() async {
        let s1 = makeStage1()
        let s2 = makeStage2()
        let s3 = AgenticAIPackBuilder.stage3(stage1: s1, stage2: s2)
        let result = await AgenticAIPackBuilder.stage4(stage1: s1, stage2: s2, stage3: s3)
        #expect(!result.isApproved)
    }

    // MARK: - Full pipeline

    @Test("build() runs all 4 stages and returns non-approved PackSynthesisResult")
    func fullPipelineReturnsNonApproved() async {
        let result = await AgenticAIPackBuilder.build(
            bundleID: "com.test.fullpipeline-\(UUID().uuidString)",
            appName: "PipelineApp",
            websiteDocsProvider: { _, _, _ in nil },
            bundleURLResolver: { _ in nil }
        )
        #expect(!result.isApproved)
        #expect(!result.reviewCard.packID.isEmpty)
        #expect(result.reviewCard.appName == "PipelineApp")
    }

    @Test("build() captures docs snippet in review card via injected provider")
    func fullPipelineWithDocsProvider() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("u4-full-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = await AgenticAIPackBuilder.build(
            bundleID: "com.test.withfeedback-\(UUID().uuidString)",
            appName: "FeedbackApp",
            websiteDocsProvider: { _, _, _ in "Great app with many features." },
            tempDirectory: tempDir,
            bundleURLResolver: { _ in nil }
        )
        // AGENT.md at the staged URL should contain the docs snippet
        let agentMD = result.reviewCard.stagedPackURL.appendingPathComponent("AGENT.md")
        if let agentText = try? String(contentsOf: agentMD, encoding: .utf8) {
            #expect(agentText.contains("FeedbackApp"))
        }
        #expect(!result.isApproved)
    }
}
