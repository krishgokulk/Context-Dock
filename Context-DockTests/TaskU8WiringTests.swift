import Foundation
import Testing
@testable import Context_Dock

// Task U8 (U8a–U8d): Last-Mile Blueprint Wiring tests.

@Suite("Task U8a — Pack Builder UI & Notch Approval Wiring")
@MainActor
struct TaskU8aPackBuilderWiringTests {

    private func makeSampleSynthesis(packID: String = "u8a-test-pack", appName: String = "TestApp") -> PackSynthesisResult {
        let metadata = DoraxPackMetadata(
            formatVersion: 2,
            id: packID,
            name: "\(appName) Pack",
            version: "2.0.0",
            bundleId: "com.test.u8a",
            capabilities: [
                PluginPackCapability(
                    id: "\(packID).ping",
                    name: "Ping",
                    intent: "Check status",
                    triggers: ["ping"],
                    type: "bash",
                    script: "echo pong",
                    safety: "read")
            ]
        )
        let pack = DoraxPackV2(
            metadata: metadata,
            agentInstructions: "# TestApp\nRead-only test instructions.",
            modes: [],
            skills: [],
            scripts: [],
            pageScripts: [],
            folderURL: FileManager.default.temporaryDirectory
        )
        let card = OwnerReviewCard(
            packID: packID,
            appName: appName,
            capabilities: [
                RankedCapability(name: "Ping", channel: .embeddedCLI, detail: "echo pong", isReadOnly: true)
            ],
            requestedPermissions: ["Shell execution of discovered CLI tools"],
            scriptFiles: [],
            dryRunResults: [DryRunProbeResult(channel: .embeddedCLI, succeeded: true, detail: "--help probe")],
            stagedPackURL: FileManager.default.temporaryDirectory
        )
        return PackSynthesisResult(pack: pack, reviewCard: card, isApproved: false)
    }

    @Test func creatorModelBuildStagesReviewCardAndApproveInstalls() async throws {
        let model = PluginCreatorModel(text: PluginCreatorPane.starter)
        model.selectedTargetBundleID = "com.test.u8a"

        let expected = makeSampleSynthesis()
        var approvedPackID: String?

        model.buildPackOverride = { _, _ in expected }
        model.approveAndInstallOverride = { result in
            approvedPackID = result.pack.id
            return StorePackBindResult(
                packID: result.pack.id,
                boundBundleID: result.pack.metadata.bundleId,
                appName: result.pack.name,
                isGlobal: false,
                registeredCapabilityIDs: ["u8a-test-pack.ping"],
                registeredUTCPConnectionIDs: [],
                registeredSkillIDs: [],
                registeredGlobalCommandIDs: []
            )
        }

        await model.buildPack()
        #expect(model.pendingPackResult?.reviewCard == expected.reviewCard)
        #expect(model.packBuildError == nil)
        #expect(model.text.contains("u8a-test-pack"))

        let bindResult = try model.approvePendingPack()
        #expect(bindResult?.packID == "u8a-test-pack")
        #expect(approvedPackID == "u8a-test-pack")
        #expect(model.pendingPackResult == nil)
        #expect(model.packInstallStatus != nil)
    }

    @Test func creatorModelDismissClearsPendingReviewWithoutInstalling() async {
        let model = PluginCreatorModel(text: PluginCreatorPane.starter)
        model.selectedTargetBundleID = "com.test.u8a"
        model.buildPackOverride = { _, _ in self.makeSampleSynthesis() }

        await model.buildPack()
        #expect(model.pendingPackResult != nil)

        model.dismissPendingPack()
        #expect(model.pendingPackResult == nil)
    }

    @Test func dynamicNotchStateHoldsAndDismissesPendingPackReview() {
        let notch = DynamicNotchState.shared
        let sample = makeSampleSynthesis(packID: "u8a-notch-pack", appName: "NotchApp")
        notch.pendingPackReview = sample
        #expect(notch.pendingPackReview?.reviewCard.packID == "u8a-notch-pack")

        notch.dismissPendingPackReview()
        #expect(notch.pendingPackReview == nil)
        #expect(notch.packReviewError == nil)
    }
}

@Suite("Task U8b — ExtensionHookRegistry & SafariEscalationPolicy Wiring")
@MainActor
struct TaskU8bSafariWiringTests {

    @Test func extensionHookRegistersAsCallableAICapabilityInCapabilityRegistry() {
        let registry = ExtensionHookRegistry()
        let hookID = "safari.u8bTestExtractStructured"
        let hook = DoraxExtensionHook(
            id: hookID,
            name: "Structured Article Extractor",
            urlPattern: "*",
            scriptFile: "extract-article-and-links.js"
        )
        let script = DoraxPackScriptEntry(
            filename: "extract-article-and-links.js",
            content: "return document.title;"
        )

        registry.register(
            hooks: [hook],
            packID: "u8b-safari-test",
            bundleID: "com.apple.Safari",
            pageScripts: [script]
        )
        defer { registry.unregister(packID: "u8b-safari-test") }

        let cap = CapabilityRegistry.shared.capability(id: hookID)
        #expect(cap != nil)
        #expect(cap?.appBundleID == "com.apple.Safari")
        #expect(cap?.runsWithoutAdapter == true)
        #expect(cap?.riskLevel == .low)

        registry.unregister(packID: "u8b-safari-test")
        #expect(CapabilityRegistry.shared.capability(id: hookID) == nil)
    }

    @Test func safariEscalationPolicyDecideRoutesLiveTabVsSafariDriverMCP() {
        #expect(SafariEscalationPolicy.decide(for: "summarize this page") == .extensionLightweight)
        #expect(SafariEscalationPolicy.decide(for: "safari.extractStructured") == .extensionLightweight)
        #expect(SafariEscalationPolicy.decide(for: "show console errors on this page") == .safariDriverMCP)
        #expect(SafariEscalationPolicy.decide(for: "list network requests") == .safariDriverMCP)
        #expect(SafariEscalationPolicy.decide(for: "take a full page screenshot") == .safariDriverMCP)
        #expect(SafariEscalationPolicy.decide(for: "automate form submission") == .safariDriverMCP)
    }

    @Test func safariCapabilityRouterEscalatesDeepAutomationQueries() async {
        let router = SafariCapabilityRouter()
        let resolution = await router.route(
            actionPhrase: "show console errors",
            original: "show console errors on this page"
        )
        guard case .candidates(let candidates) = resolution else {
            Issue.record("Expected MCP escalation candidate for console errors")
            return
        }
        #expect(candidates.first?.route == .mcp)
        #expect(candidates.first?.source == .mcp)
        #expect(candidates.first?.debugReason.contains(SafariEngine.safariDriverMCP.routeLabel) == true)
    }

    @Test func safariCapabilityRouterDoesNotHijackSummarizeAboutNetworkTraffic() async {
        let router = SafariCapabilityRouter()
        let resolution = await router.route(
            actionPhrase: "summarize this page about network traffic",
            original: "summarize this page about network traffic"
        )
        if case .candidates(let candidates) = resolution {
            #expect(candidates.first?.route != .mcp)
        }
    }

    @Test func appScopedChatServiceSafariGuidanceMatchesEscalationPolicy() {
        let light = AppScopedChatService.safariEscalationGuidance(for: "extract links from this article")
        #expect(light.engine == .extensionLightweight)
        #expect(light.promptNote.contains(SafariEngine.extensionLightweight.routeLabel))

        let deep = AppScopedChatService.safariEscalationGuidance(for: "inspect network traffic for api calls")
        #expect(deep.engine == .safariDriverMCP)
        #expect(deep.promptNote.contains("safaridriver --mcp"))
    }
}

@Suite("Task U8c — StorePackInstaller.installV2 Atomic Binding")
@MainActor
struct TaskU8cInstallV2BindingTests {

    @Test func installV2RegistersPluginCapabilitiesCLIToolsMCPServersAndModes() throws {
        let bundleID = "com.test.u8c.atomic"
        let packID = "u8c-atomic-pack"
        let cliCommand = "u8c-fake-cli"
        let mcpName = "u8c-test-mcp"
        let modeID = "u8c-focus-mode"

        let metadata = DoraxPackMetadata(
            formatVersion: 2,
            id: packID,
            name: "U8c Atomic App",
            version: "2.0.0",
            bundleId: bundleID,
            capabilities: [
                PluginPackCapability(
                    id: "run-check",
                    name: "Run Check",
                    intent: "Verify pack action registration",
                    triggers: ["run check"],
                    type: "bash",
                    script: "echo ok",
                    safety: "read")
            ],
            cliTools: [
                DoraxCLITool(name: "U8c CLI", binary: cliCommand, description: "Test CLI tool")
            ],
            mcpServers: [
                DoraxMCPServer(
                    name: mcpName,
                    transport: "stdio",
                    command: "/usr/bin/env u8c-mcp --stdio",
                    description: "Test MCP server")
            ]
        )

        let pack = DoraxPackV2(
            metadata: metadata,
            agentInstructions: "# U8c Atomic App",
            modes: [
                DoraxPackMode(
                    id: modeID,
                    name: "Focus Mode",
                    description: "Strict read-only mode",
                    systemPromptAppend: "Stay focused.",
                    toolFilter: ["plugin.\(packID).run-check"],
                    isDefault: true)
            ],
            skills: [],
            scripts: [],
            pageScripts: [],
            folderURL: FileManager.default.temporaryDirectory
        )

        defer {
            CapabilityRegistry.shared.removeCapability(id: PluginCapability.id(pluginID: packID, action: "run-check"))
            TerminalPackageManager.shared.packages.removeAll { $0.command == cliCommand }
            if let server = MCPServerManager.shared.servers(forBundleId: bundleID).first(where: { $0.name == mcpName }) {
                MCPServerManager.shared.unlink(id: server.id, from: bundleID, persistToDisk: false)
            }
        }

        let bindResult = try StorePackInstaller.installV2(pack, persistToDisk: false)

        // 1. PluginCapability.make registered into CapabilityRegistry and reported in bindResult
        let capID = PluginCapability.id(pluginID: packID, action: "run-check")
        let registeredCap = CapabilityRegistry.shared.capability(id: capID)
        #expect(registeredCap != nil)
        #expect(registeredCap?.appBundleID == bundleID)
        #expect(bindResult.registeredCapabilityIDs.contains(capID))

        // 2. cli_tools linked into TerminalPackageManager
        let linkedCLI = TerminalPackageManager.shared.packages.first { $0.command == cliCommand }
        #expect(linkedCLI != nil)
        #expect(linkedCLI?.contextAppBundleIds.contains(bundleID) == true)

        // 3. mcp_servers registered into MCPServerManager
        let linkedMCP = MCPServerManager.shared.servers(forBundleId: bundleID).first { $0.name == mcpName }
        #expect(linkedMCP != nil)
        #expect(linkedMCP?.command == "/usr/bin/env")
        #expect(linkedMCP?.args == ["u8c-mcp", "--stdio"])

        // 4. modes.json loaded into AppPetManifestRegistry
        let petManifest = AppPetManifestRegistry.shared.manifest(forBundleID: bundleID)
        #expect(petManifest?.modes.contains(where: { $0.id == modeID }) == true)
        #expect(petManifest?.defaultMode == modeID)

        // 5. Converted manifest validates cleanly with zero schema errors (cli_tools names must not
        //    leak into agent.tools and trigger PluginInstallError.doesNotValidate).
        let manifest = pack.toPluginManifest()
        let errors = PluginSchema.validate(manifest).filter { $0.severity == .error }
        #expect(errors.isEmpty)
    }

    @Test func scanEmbeddedCLIsSkipsSubdirectoriesInsideResources() async throws {
        let tmpApp = FileManager.default.temporaryDirectory
            .appendingPathComponent("U8ScanTest-\(UUID().uuidString).app", isDirectory: true)
        let resources = tmpApp.appendingPathComponent("Contents/Resources", isDirectory: true)
        let fakeDir = resources.appendingPathComponent("Background Images", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpApp) }

        let found = await AgenticAIPackBuilder.scanEmbeddedCLIs(
            appURL: tmpApp,
            helpTextProvider: { _ in nil }
        )
        #expect(!found.contains(where: { $0.name == "Background Images" }))
    }
}

@Suite("Task U8d — Menu Group Removal & Rich Thread Persistence")
@MainActor
struct TaskU8dPromptAndPersistenceTests {

    @Test func scopeInventoryOmitsStaticMenuCommandsGroup() {
        let inventory = ScopeInventory.app(bundleId: "com.apple.Safari", appName: "Safari")
        #expect(!inventory.groups.contains(where: { $0.title == "Menu commands" }))
    }

    @Test func storedChatMessageRoundTripsRichCardsChipsAndReceipts() throws {
        let now = Date(timeIntervalSince1970: 1_763_650_000)
        let fileURL = URL(fileURLWithPath: "/tmp/u8d-report.pdf")
        let receipt = DoraXActionReceipt(
            command: "notes.search",
            output: "Found 1 note",
            success: true
        )
        let original = AIChatMessage(
            role: .assistant,
            content: "Here is your report and matching note.",
            structuredData: "{\"ok\":true}",
            hasInstallButton: true,
            attachments: [fileURL],
            appLaunches: [AppLaunchAction(label: "Safari", systemIcon: "safari", bundleId: "com.apple.Safari")],
            recentFiles: [RecentFileAction(url: fileURL)],
            noteResults: [NoteSearchAction(id: "n1", title: "Roadmap", folder: "Work", snippet: "Q4", modifiedDate: now)],
            noteTasks: [NoteTaskAction(text: "Ship U8")],
            reminderResults: [ReminderResultAction(title: "Review PR", detail: "Today", state: .created)],
            messageResults: [MessageSentAction(recipientName: "Alex", recipientHandle: "+15550100", state: .sent)],
            browserTabs: [BrowserTabAction(title: "Example", url: "https://example.com", windowIndex: 1, tabIndex: 2)],
            pageLinks: [PageLinkAction(title: "Docs", url: "https://example.com/docs", pageTitle: "Example")],
            mcpToolsRan: ["notes.search", "finder.recent"],
            evidenceReceipts: [receipt],
            activeMode: "Research",
            modeProvenance: "Safari: Research",
            runOutput: "stdout line 1",
            timestamp: now
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode([StoredChatMessage(from: original)])
        let decoded = try decoder.decode([StoredChatMessage].self, from: data)
        let restored = try #require(decoded.first?.toAIChatMessage())

        #expect(restored.content == original.content)
        #expect(restored.timestamp == now)
        #expect(restored.structuredData == "{\"ok\":true}")
        #expect(restored.hasInstallButton == true)
        #expect(restored.attachments == [fileURL])
        #expect(restored.appLaunches == original.appLaunches)
        #expect(restored.recentFiles == original.recentFiles)
        #expect(restored.noteResults == original.noteResults)
        #expect(restored.noteTasks.map(\.text) == ["Ship U8"])
        #expect(restored.reminderResults.map(\.title) == ["Review PR"])
        #expect(restored.reminderResults.first?.state == .created)
        #expect(restored.messageResults.first?.recipientName == "Alex")
        #expect(restored.messageResults.first?.state == .sent)
        #expect(restored.browserTabs == original.browserTabs)
        #expect(restored.pageLinks == original.pageLinks)
        #expect(restored.mcpToolsRan == ["notes.search", "finder.recent"])
        #expect(restored.evidenceReceipts.count == 1)
        #expect(restored.evidenceReceipts.first?.command == "notes.search")
        #expect(restored.activeMode == "Research")
        #expect(restored.modeProvenance == "Safari: Research")
        #expect(restored.runOutput == "stdout line 1")
    }

    @Test func generalAIChatConversationStorePersistsRichCardsAndReceipts() {
        let storageKey = "dorax.test.u8d.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }

        let receipt = DoraXActionReceipt(command: "safari.extractStructured", output: "ok", success: true)
        let msg = AIChatMessage(
            role: .assistant,
            content: "Extracted page links.",
            noteResults: [NoteSearchAction(id: "n2", title: "Spec", folder: "Notes", snippet: "U8", modifiedDate: nil)],
            pageLinks: [PageLinkAction(title: "Home", url: "https://example.org", pageTitle: "Example")],
            mcpToolsRan: ["safari.extractStructured"],
            evidenceReceipts: [receipt],
            activeMode: "Browse",
            modeProvenance: "Safari: Browse"
        )

        GeneralAIChatConversationStore.save([msg], key: storageKey)
        let loaded = GeneralAIChatConversationStore.load(key: storageKey)
        #expect(loaded.count == 1)
        #expect(loaded.first?.noteResults.first?.title == "Spec")
        #expect(loaded.first?.pageLinks.first?.url == "https://example.org")
        #expect(loaded.first?.mcpToolsRan == ["safari.extractStructured"])
        #expect(loaded.first?.evidenceReceipts.first?.command == "safari.extractStructured")
        #expect(loaded.first?.activeMode == "Browse")
        #expect(loaded.first?.modeProvenance == "Safari: Browse")
    }
}
