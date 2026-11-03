import ApplicationServices
import Foundation
import Testing

@testable import Context_Dock

@MainActor
@Suite("Frontmost App Agent Phase 1: Context Assembler Unification")
struct FrontmostAppAgentPhase1Tests {

    @Test("AppAgentProfile formats frontmatter tools, safety rules and instructions")
    func appAgentProfilePromptBlock() {
        let markdown = """
        ---
        app: Pages
        bundle_id: com.apple.Pages
        summary: Word processing and document layout.
        tools:
          capabilities: [pages.exportPDF, pages.wordCount]
          mcp: [pages-mcp]
          cli: [pandoc]
          actions: [exportPDF]
          scripts: [clean-layout.sh]
        never:
          - Overwrite existing documents without confirmation
        verify:
          export: pages.exportPDF
        ---

        Prefer exporting via native menus or AppleScript when available.
        """

        let profile = AppAgentProfile.parse(markdown, bundleID: "com.apple.Pages", appName: "Pages")
        let prompt = profile.promptBlock()

        #expect(prompt.contains("## How Pages is worked with (this app's AGENT.md profile)"))
        #expect(prompt.contains("Word processing and document layout."))
        #expect(prompt.contains("Declared capabilities: pages.exportPDF, pages.wordCount"))
        #expect(prompt.contains("Declared MCP servers: pages-mcp"))
        #expect(prompt.contains("Declared CLI tools: pandoc"))
        #expect(prompt.contains("Declared actions: exportPDF"))
        #expect(prompt.contains("clean-layout.sh"))
        #expect(prompt.contains("Never, in this app:"))
        #expect(prompt.contains("Overwrite existing documents without confirmation"))
        #expect(prompt.contains("Prefer exporting via native menus or AppleScript"))
    }

    @Test("FrontmostAppTaskPlan integrates AGENT.md declared tools and safety rules")
    func taskPlanIntegratesAgentProfile() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-profile-test-\(UUID().uuidString)", isDirectory: true)
        let store = AppAgentProfileStore(root: tempRoot)
        let profile = AppAgentProfile(
            appName: "TestApp",
            bundleID: "com.test.agentapp",
            summary: "A test app profile.",
            never: ["Quit or restart unexpectedly"],
            verify: [:],
            tools: AppAgentProfile.Tools(
                capabilities: ["test.cap"],
                mcp: ["test-mcp"],
                cli: ["test-cli"],
                actions: ["testAction"],
                scripts: ["run-tests.sh"]
            ),
            instructions: "Always verify output.",
            problems: []
        )
        try store.save(profile, forBundleID: "com.test.agentapp")

        // Save to standard shared store path temporarily to verify FrontmostAppTaskPlan.make
        let sharedURL = AppAgentProfileStore.shared.fileURL(forBundleID: "com.test.agentapp")
        try? FileManager.default.createDirectory(at: sharedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? profile.markdown().write(to: sharedURL, atomically: true, encoding: .utf8)
        AppAgentProfileStore.shared.invalidate(bundleID: "com.test.agentapp")

        defer {
            try? FileManager.default.removeItem(at: sharedURL)
            AppAgentProfileStore.shared.invalidate(bundleID: "com.test.agentapp")
        }

        let plan = FrontmostAppTaskPlan.make(
            query: "Export this document as PDF",
            bundleId: "com.test.agentapp",
            appName: "TestApp")

        #expect(plan.allowedToolNames.contains("run_app_script"))
        #expect(plan.allowedToolNames.contains("run_mcp_tool"))
        #expect(plan.allowedToolNames.contains("run_adapter_action"))
        #expect(plan.allowedToolNames.contains("run_command"))
        #expect(plan.allowedToolNames.contains("run_menu_command"))
        #expect(plan.allowedToolNames.contains("find_menu_command"))

        let rule = plan.promptRule
        #expect(rule.contains("APP SAFETY RULES (AGENT.md):"))
        #expect(rule.contains("Quit or restart unexpectedly"))
    }

    @Test("SkillStore provides active per-app skills with complete domain instructions")
    func skillStorePerAppSkillsBlock() {
        let bundleId = "com.apple.Keynote"
        let skill = AdapterSkill(
            id: UUID().uuidString,
            adapterBundleId: bundleId,
            name: "Slide Presentation Designer",
            summary: "Formats slide decks cleanly",
            instructions: "Always ensure slide titles use 24pt bold and contrast background.",
            version: "1.0",
            isEnabled: true,
            surfaceId: "",
            isPinned: false
        )
        SkillStore.shared.upsert(skill)
        defer { SkillStore.shared.remove(id: skill.id) }

        let block = SkillStore.shared.perAppSkillsPromptBlock(for: bundleId)
        #expect(block.contains("## App Skills (SkillScope.app: com.apple.Keynote)"))
        #expect(block.contains("Slide Presentation Designer"))
        #expect(block.contains("Formats slide decks cleanly"))
        #expect(block.contains("Always ensure slide titles use 24pt bold and contrast background."))
    }

    @Test("AppMenuCapabilityCache formats live menu commands snapshot for the provider")
    func menuCommandsSnapshotBlock() {
        let bundleId = "com.apple.Pages"
        let appName = "Pages"
        let placeholder = AXUIElementCreateSystemWide()

        let items = [
            AXMenuItem(
                title: "PDF…",
                path: ["File", "Export To", "PDF…"],
                isEnabled: true,
                element: placeholder,
                children: [],
                sourcePID: 100,
                sourceAppName: appName,
                isAppleMenu: false,
                hasLiveAvailability: true,
                shortcutChar: "P",
                shortcutModifiers: 1048576
            ),
            AXMenuItem(
                title: "Word…",
                path: ["File", "Export To", "Word…"],
                isEnabled: true,
                element: placeholder,
                children: [],
                sourcePID: 100,
                sourceAppName: appName,
                isAppleMenu: false,
                hasLiveAvailability: true
            ),
        ]

        AppMenuCapabilityCache.shared.store(
            items: items,
            bundleIdentifier: bundleId,
            appName: appName
        )

        let snapshot = AppMenuCapabilityCache.shared.menuCommandsSnapshotBlock(
            bundleIdentifier: bundleId, appName: appName)

        #expect(snapshot.contains("## Live Menu Commands for Pages"))
        #expect(snapshot.contains("File ▸ Export To ▸ PDF…"))
        #expect(snapshot.contains("File ▸ Export To ▸ Word…"))
        #expect(snapshot.contains("run_menu_command"))
    }

    @Test("ScopedPromptAssembler positions liveMenu correctly and respects budget")
    func scopedPromptAssemblerLiveMenu() {
        var prompt = ScopedPromptAssembler()
        prompt.set(.identity, "IDENTITY")
        prompt.set(.capabilities, "CAPABILITIES")
        prompt.set(.liveMenu, "LIVE_MENU_COMMANDS")
        prompt.set(.skills, "SKILLS")

        let assembled = prompt.assemble(for: .anthropic)
        let capIndex = assembled.range(of: "CAPABILITIES")!.lowerBound
        let menuIndex = assembled.range(of: "LIVE_MENU_COMMANDS")!.lowerBound
        let skillIndex = assembled.range(of: "SKILLS")!.lowerBound

        #expect(capIndex < menuIndex)
        #expect(menuIndex < skillIndex)

        // Drop order respects liveMenu under small on-device budget
        var bigPrompt = ScopedPromptAssembler()
        for section in ScopedPromptSection.allCases {
            bigPrompt.set(section, String(repeating: "m", count: 2_000))
        }
        let smallAssembled = bigPrompt.assemble(for: .onDevice)
        let budget = ScopedPromptAssembler.budget(for: .onDevice)!
        #expect(smallAssembled.count <= budget)
    }

    @Test("RouteTools empty route output directs to menu commands and Computer Use")
    func findRouteDirectsToMenuCommandsOnEmpty() async {
        let registry = AgentToolRegistry.shared
        registry.registerRouteTools()
        let tool = registry.tool(named: "find_route")!

        var context = AgentToolContext(commandExecutor: { _, _, _ in (true, "", 0) })
        context.grantedApps = ["pages": "com.apple.Pages", "com.apple.pages": "com.apple.Pages"]

        let result = await tool.handler(["request": "nonexistent_action_xyz", "app": "Pages"], context)
        #expect(result.output.contains("run_menu_command"))
        #expect(result.output.contains("operate_app"))
        #expect(result.output.contains("Do NOT tell the user to manually install CLI tools"))
    }
}
