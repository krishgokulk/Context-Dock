// FrontmostAppAgentE2ETests.swift
// Context-DockTests
//
// End-to-End verification across the 3-Tier Escalation Ladder:
// 1. Apple native apps (headless/native data-lane routes)
// 2. Scriptable third-party apps (sdef dictionary & synthesized scripting)
// 3. Non-scriptable UI apps (live menu commands, fuzzy path resolution, and AX UI focusing)

import ApplicationServices
import Foundation
import Testing

@testable import Context_Dock

@MainActor
@Suite("Frontmost App Agent Phase 4: End-to-End Verification Tests")
struct FrontmostAppAgentE2ETests {

    private func item(_ path: [String], enabled: Bool = true) -> ComputerUseTarget {
        ComputerUseTarget(path: path, isEnabled: enabled)
    }

    // MARK: - 1. Apple Native App (Tier 1 Headless / Data Lane)

    @Test("Tier 1: Apple native app plans data-lane route and populates ambient context")
    func appleNativeAppDataLanePlan() {
        let bundleId = "com.apple.mail"
        let appName = "Mail"

        let readPlan = FrontmostAppTaskPlan.make(
            query: "find recent emails from John",
            bundleId: bundleId,
            appName: appName
        )

        // Read query uses data-lane tools
        #expect(readPlan.allowedToolNames.contains("find_capability"))
        #expect(readPlan.allowedToolNames.contains("run_capability"))
        #expect(readPlan.allowedToolNames.contains("run_adapter_action"))

        let actionPlan = FrontmostAppTaskPlan.make(
            query: "delete this email",
            bundleId: bundleId,
            appName: appName
        )
        #expect(actionPlan.allowedToolNames.contains("run_menu_command"))

        // Prompt assembly integrates ambient app identity and live menu slot
        var assembler = ScopedPromptAssembler()
        assembler.set(.identity, "Frontmost App: \(appName) (\(bundleId))")
        assembler.set(.capabilities, "Available: mail.search, mail.read")
        assembler.set(.liveMenu, "File ▸ New Message\nMailbox ▸ Synchronize")

        let assembled = assembler.assemble(for: .anthropic)
        #expect(assembled.contains("Frontmost App: Mail"))
        #expect(assembled.contains("Available: mail.search"))
        #expect(assembled.contains("Mailbox ▸ Synchronize"))
    }

    // MARK: - 2. Scriptable Third-Party App (Tier 2 Autonomous Scripting)

    @Test("Tier 2: Scriptable app exposes sdef dictionary and synthesized scripting tools")
    func scriptableThirdPartyAppTier2() async {
        let bundleId = "com.spotify.client"
        let appName = "Spotify"

        let plan = FrontmostAppTaskPlan.make(
            query: "pause current playing track",
            bundleId: bundleId,
            appName: appName
        )

        // Scripting tools are offered in frontmost turn
        #expect(plan.allowedToolNames.contains("read_app_dictionary"))
        #expect(plan.allowedToolNames.contains("run_synthesized_script"))

        // Mock sdef manifest injection
        let manifest = AppScriptingDictionary(
            bundleID: bundleId,
            appName: appName,
            version: "1.2.0",
            parsedAt: Date(),
            classes: [
                ScriptingClass(
                    name: "track",
                    suite: "Spotify Suite",
                    plural: "tracks",
                    properties: [
                        ScriptingProperty(name: "name", type: "text", isReadOnly: true, isWriteOnly: false, summary: "Track title"),
                        ScriptingProperty(name: "artist", type: "text", isReadOnly: true, isWriteOnly: false, summary: "Artist name")
                    ],
                    elementTypes: [],
                    respondsTo: []
                )
            ],
            commands: [
                ScriptingCommand(
                    name: "pause",
                    suite: "Spotify Suite",
                    verbClass: .write,
                    directType: nil,
                    parameters: []
                )
            ]
        )

        AppDictionaryStore.shared._injectForTesting(bundleID: bundleId, manifest: manifest)

        let dictResult = await SynthesizedScriptRunner.readDictionary(
            appInput: appName,
            query: "pause",
            scope: nil,
            grantedApps: [appName.lowercased(): bundleId]
        )

        #expect(dictResult.success)
        #expect(dictResult.output.contains("`pause`"))
    }

    // MARK: - 3. Non-Scriptable UI App (Tier 3 Computer Use / Live Menus)

    @Test("Tier 3: Non-scriptable app escalates to live menu commands and Computer Use")
    func nonScriptableUIAppEscalation() async {
        let bundleId = "com.figma.Desktop"
        let appName = "Figma"

        // Step A: read_app_dictionary detects absence of sdef and guides model to live menus
        let dictResult = await SynthesizedScriptRunner.readDictionary(
            appInput: appName,
            query: "",
            scope: nil,
            grantedApps: [appName.lowercased(): bundleId]
        )

        #expect(dictResult.success)
        #expect(dictResult.output.contains("has no AppleScript scripting dictionary (sdef)"))
        #expect(dictResult.output.contains("run_menu_command"))
        #expect(dictResult.output.contains("operate_app"))

        // Step B: Live menu path matching with hierarchy delimiters
        let menuCandidates = [
            item(["File", "Export…"]),
            item(["File", "Export Frames to PDF…"]),
            item(["Edit", "Copy as SVG"]),
        ]

        let resolved = ComputerUseTargetResolver.best(
            matching: "File > Export Frames to PDF",
            among: menuCandidates
        )

        #expect(resolved != nil)
        #expect(resolved?.path == ["File", "Export Frames to PDF…"])

        // Step C: Route fallback produces non-blocking escalation card
        let card = AppToolCatalog.noRouteCard(forBundleId: bundleId, appName: appName)
        #expect(card.fallback.lowercased().contains("operating \(appName.lowercased()) autonomously"))
        #expect(card.fallback.contains("menus"))
    }

    // MARK: - 4. Ambient App Context Isolation

    @Test("Ambient app context updates cleanly without leaking previous app state")
    func ambientAppContextIsolation() {
        var assembler = ScopedPromptAssembler()

        // App A: Pages
        assembler.set(.identity, "Frontmost: Pages (com.apple.Pages)")
        assembler.set(.liveMenu, "File ▸ Export To ▸ PDF…")
        assembler.set(.skills, "Skill: Document formatting guidelines")

        let pagesAssembled = assembler.assemble(for: .anthropic)
        #expect(pagesAssembled.contains("Frontmost: Pages"))
        #expect(pagesAssembled.contains("Export To ▸ PDF…"))
        #expect(!pagesAssembled.contains("Keynote"))

        // Switch to App B: Keynote
        assembler.set(.identity, "Frontmost: Keynote (com.apple.Keynote)")
        assembler.set(.liveMenu, "Play ▸ Play Slideshow")
        assembler.set(.skills, "Skill: Slide deck animations")

        let keynoteAssembled = assembler.assemble(for: .anthropic)
        #expect(keynoteAssembled.contains("Frontmost: Keynote"))
        #expect(keynoteAssembled.contains("Play ▸ Play Slideshow"))
        #expect(!keynoteAssembled.contains("Pages"))
        #expect(!keynoteAssembled.contains("Export To ▸ PDF…"))
    }
}
