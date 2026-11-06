// Context-DockTests/StreamlineSettingsAndExtensionsTests.swift
//
// Tests for Task #373: Streamline Settings & Extensions Architecture (Packs, Apps, Store).
// Covers:
// 1. Sidebar consolidation into 2 Extensions rows (`Apps` and `Store / Packs`)
// 2. 3-tab App Detail simplification (`Capabilities & Skills`, `Agent (AGENT.md)`, `Access & Permissions`)
// 3. Automatic App Binding when installing a pack from `Store / Packs`
// 4. AI Pack Synthesis (sdef + menu hierarchy + OpenAPI 3.x / UTCP introspection)

import Foundation
import Testing

@testable import Context_Dock

@MainActor
@Suite(.serialized)
struct StreamlineSettingsAndExtensionsTests {

    // MARK: - 1. Sidebar Consolidation

    @Test("Extensions sidebar section consolidates 4 items into Apps and Store / Packs")
    func extensionsSidebarSectionHasAppsAndStorePacks() throws {
        let section = try #require(
            SettingsSidebarSection.all.first(where: { $0.id == "extensions" }))
        #expect(section.rows.compactMap(\.page) == [.integrations, .plugins])
        #expect(SettingsPage.integrations.title == "Apps")
        #expect(SettingsPage.plugins.title == "Store / Packs")

        // Legacy `.appPacks` routes cleanly to Apps destination
        #expect(
            SettingsRouteResolver.destination(for: .appPacks)
                == IntegrationDestination(scope: .apps, tab: .overview))
    }

    // MARK: - 2. 3-Tab App Detail Model

    @Test("App Detail View exposes 3 unified user-facing tabs and maps legacy IntegrationDetailTab cases")
    func appDetailTabHasThreeCleanTabs() {
        #expect(AppDetailTab.allCases == [.capabilities, .agent, .access])
        #expect(AppDetailTab.capabilities.title == "Capabilities & Skills")
        #expect(AppDetailTab.agent.title == "Agent (AGENT.md)")
        #expect(AppDetailTab.access.title == "Access & Permissions")

        // Overview, Actions, and Resources all converge onto Capabilities & Skills
        #expect(IntegrationDetailTab.overview.appTab == .capabilities)
        #expect(IntegrationDetailTab.actions.appTab == .capabilities)
        #expect(IntegrationDetailTab.resources.appTab == .capabilities)
        #expect(IntegrationDetailTab.agent.appTab == .agent)
        #expect(IntegrationDetailTab.access.appTab == .access)
    }

    // MARK: - 3. Automatic App Binding

    @Test("Installing an app-targeted Store Pack binds capabilities, UTCP endpoints, and skills to the matching app")
    func storePackInstallerBindsToMatchingApp() throws {
        let testBundleID = "com.test.dorax.storepack.notion"
        let manifest = PluginManifest(
            id: "test-notion-pack",
            name: "Notion Test Pack",
            version: "1.0.0",
            icon: "doc.text.fill",
            description: "Test Notion pack for automatic binding",
            targetApp: PluginTargetApp(
                bundleId: testBundleID,
                name: "Notion Test"),
            capabilities: [
                PluginPackCapability(
                    id: "notion_new_page",
                    name: "Create Notion Page",
                    intent: "Create a new page in Notion",
                    triggers: ["new notion page"],
                    type: "menuClick",
                    menuPath: ["File", "New Page"],
                    safety: "write")
            ],
            utcpEndpoints: [
                PluginPackUTCPEndpoint(
                    id: "notion_search",
                    name: "Notion Search",
                    baseURL: "https://api.notion.com",
                    method: "POST",
                    path: "/v1/search",
                    description: "Search Notion workspace",
                    requiresAuth: true)
            ],
            skills: [
                PluginPackSkill(
                    id: "test-notion-skill",
                    name: "Notion Research Notes",
                    summary: "Summarize active source into Notion",
                    instructions: "Read active source and create a Notion page.")
            ]
        )

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dorax-pack-bind-\(UUID().uuidString)", isDirectory: true)

        var createdConnectionIDs: [String] = []
        var createdSkillIDs: [String] = []
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            AppAdapterManager.shared.removeInMemoryAdapter(bundleId: testBundleID)
            for id in createdConnectionIDs {
                APIConnectionStore.shared.disconnect(id: id)
            }
            for id in createdSkillIDs {
                SkillStore.shared.remove(id: id)
            }
        }

        let result = try StorePackInstaller.install(
            manifest,
            into: tempDir,
            persistToDisk: false)
        createdConnectionIDs = result.registeredUTCPConnectionIDs
        createdSkillIDs = result.registeredSkillIDs

        #expect(!result.isGlobal)
        #expect(result.boundBundleID == testBundleID)
        #expect(result.registeredCapabilityIDs == ["pack.test-notion-pack.notion_new_page"])
        #expect(result.registeredUTCPConnectionIDs.count == 1)
        #expect(result.registeredSkillIDs.count == 1)

        // 1. Adapter action bound to AppAdapterManager
        let adapter = try #require(AppAdapterManager.shared.adapter(for: testBundleID))
        #expect(adapter.actions.contains(where: { $0.id == "pack.test-notion-pack.notion_new_page" }))

        // 2. UTCP endpoint bound to APIConnectionStore and visible in ScopeInventory.app
        let connections = APIConnectionStore.shared.connections(for: testBundleID)
        #expect(connections.contains(where: { $0.toolCount == 1 }))

        let inventory = ScopeInventory.app(bundleId: testBundleID, appName: "Notion Test")
        let allItems = inventory.groups.flatMap(\.items)
        #expect(allItems.contains(where: { $0.contains("Create Notion Page") }))
        #expect(allItems.contains(where: { $0.contains("1 direct UTCP tool") }))
        #expect(allItems.contains(where: { $0.contains("Notion Research Notes") }))
    }

    @Test("Installing a global Store Pack binds to Global Context when bundle_id is omitted")
    func storePackInstallerBindsGlobalPackToGlobalScope() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dorax-global-pack-\(UUID().uuidString)", isDirectory: true)
        var createdSkillIDs: [String] = []
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            for id in createdSkillIDs {
                SkillStore.shared.remove(id: id)
            }
        }

        let pack = StorePackCatalog.githubGlobalPack
        let result = try StorePackInstaller.install(
            pack,
            into: tempDir,
            persistToDisk: false)
        createdSkillIDs = result.registeredSkillIDs

        #expect(result.isGlobal)
        #expect(result.boundBundleID == nil)
    }

    // MARK: - 4. AI Pack Synthesis (sdef + Menu Tree + OpenAPI / UTCP)

    @Test("AIPackIntrospector combines sdef commands and OpenAPI 3.x / UTCP endpoints into prompt context")
    func aiPackIntrospectorSynthesizesSdefAndOpenAPI() async {
        let sampleSdef = """
        <?xml version="1.0" encoding="UTF-8"?>
        <dictionary title="Safari Terminology">
            <suite name="Safari Suite" code="sfri">
                <command name="search the web" code="sfrisrch" description="Searches the web using Safari">
                    <direct-parameter type="text" description="The search query"/>
                </command>
            </suite>
        </dictionary>
        """

        let sampleOpenAPI = """
        {
          "openapi": "3.0.0",
          "info": { "title": "Notion API", "version": "1.0.0" },
          "servers": [{ "url": "https://api.notion.com" }],
          "paths": {
            "/v1/search": {
              "post": {
                "operationId": "searchWorkspace",
                "summary": "Search pages and databases"
              }
            }
          }
        }
        """

        let report = await AIPackIntrospector.introspect(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            sdefXMLOverride: sampleSdef,
            openAPISpecText: sampleOpenAPI
        )

        #expect(report.sdefCommands.contains(where: { $0.contains("search the web") }))
        #expect(report.openAPITools.count == 1)
        #expect(report.openAPITools.first?.name == "searchWorkspace")

        let endpoints = AIPackIntrospector.synthesizeUTCPEndpoints(
            from: report.openAPITools,
            baseURL: report.openAPIBaseURL)
        #expect(endpoints.count == 1)
        #expect(endpoints.first?.id == "searchWorkspace")
        #expect(endpoints.first?.baseURL == "https://api.notion.com")
        #expect(endpoints.first?.path == "/v1/search")

        let promptBlock = report.promptContextBlock
        #expect(promptBlock.contains("com.apple.Safari"))
        #expect(promptBlock.contains("search the web"))
        #expect(promptBlock.contains("searchWorkspace"))
    }

    @Test("PluginCreatorModel.draft enriches synthesized pack with target_app and parsed OpenAPI UTCP endpoints")
    func pluginCreatorModelDraftSynthesizesCompletePack() async {
        let sampleOpenAPI = """
        {
          "openapi": "3.0.0",
          "info": { "title": "Linear API", "version": "1.0.0" },
          "servers": [{ "url": "https://api.linear.app" }],
          "paths": {
            "/issues": {
              "get": {
                "operationId": "listIssues",
                "summary": "List Linear issues"
              }
            }
          }
        }
        """

        let aiResponse = """
        ```json
        {
          "id": "safari-linear-helper",
          "name": "Safari Linear Helper",
          "description": "Clip Safari tabs to Linear",
          "icon": "safari",
          "capabilities": [
            {
              "id": "new_tab",
              "name": "New Tab",
              "intent": "Open a new Safari tab",
              "type": "menuClick",
              "menu_path": ["File", "New Tab"],
              "safety": "read"
            }
          ],
          "skills": [
            {
              "id": "clip-tab",
              "name": "Clip Active Tab",
              "summary": "Clip tab to Linear",
              "instructions": "Read active Safari tab and create a Linear issue."
            }
          ]
        }
        ```
        """

        let model = PluginCreatorModel(text: PluginCreatorPane.starter)
        model.makeEngine = {
            PluginAuthoringEngine(send: { _, _ in aiResponse })
        }
        model.selectedTargetBundleID = "com.apple.Safari"
        model.openAPISpecText = sampleOpenAPI
        model.request = "Create a Safari pack that clips tabs to Linear"

        await model.draft()

        #expect(model.draftError == nil)
        #expect(model.canSave)
        let manifest = try? #require(model.manifest)
        #expect(manifest?.targetApp?.bundleId == "com.apple.Safari")
        #expect(manifest?.capabilities?.first?.id == "new_tab")
        #expect(manifest?.utcpEndpoints?.first?.id == "listIssues")
        #expect(manifest?.skills?.first?.id == "clip-tab")
    }
}
