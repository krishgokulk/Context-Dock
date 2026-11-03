// SynthesizedScriptToolTests.swift
// Context-DockTests
//
// Tests for Phase 2: Autonomous Scripting Tool (sdef inspection, synthesized AppleScript/JXA, safety & approval gating).

import ApplicationServices
import Foundation
import Testing

@testable import Context_Dock

@MainActor
@Suite("Frontmost App Agent Phase 2: Autonomous Scripting Tool Tests")
struct SynthesizedScriptToolTests {

    @Test("AgentToolRegistry registers read_app_dictionary and run_synthesized_script")
    func registryRegistersSynthesizedScriptTools() {
        let registry = AgentToolRegistry()
        #expect(registry.tool(named: "read_app_dictionary") != nil)
        #expect(registry.tool(named: "run_synthesized_script") != nil)
    }

    @Test("OutboundGate classifies read_app_dictionary as local and run_synthesized_script as outbound")
    func outboundGateClassifiesSynthesizedScriptTools() {
        #expect(OutboundGate.localTools.contains("read_app_dictionary"))
        #expect(OutboundGate.outboundTools.contains("run_synthesized_script"))
        #expect(OutboundGate.isClassified(toolName: "read_app_dictionary"))
        #expect(OutboundGate.isClassified(toolName: "run_synthesized_script"))
    }

    @Test("FrontmostAppTaskPlan includes synthesized scripting tools for frontmost app")
    func frontmostAppTaskPlanIncludesSynthesizedScriptTools() {
        let plan = FrontmostAppTaskPlan.make(
            query: "export document to PDF",
            bundleId: "com.apple.Pages",
            appName: "Pages"
        )

        #expect(plan.allowedToolNames.contains("read_app_dictionary"))
        #expect(plan.allowedToolNames.contains("run_synthesized_script"))
    }

    @Test("AppScriptingDictionary formats clean markdown summary for AI provider")
    func appScriptingDictionaryFormatsSummary() {
        let manifest = AppScriptingDictionary(
            bundleID: "com.apple.Pages",
            appName: "Pages",
            version: "14.0",
            parsedAt: Date(),
            classes: [
                ScriptingClass(
                    name: "document",
                    suite: "Pages Suite",
                    plural: "documents",
                    properties: [
                        ScriptingProperty(name: "name", type: "text", isReadOnly: true, isWriteOnly: false, summary: "Document name"),
                        ScriptingProperty(name: "path", type: "text", isReadOnly: true, isWriteOnly: false, summary: "Document file path")
                    ],
                    elementTypes: [],
                    respondsTo: []
                )
            ],
            commands: [
                ScriptingCommand(
                    name: "export",
                    suite: "Pages Suite",
                    verbClass: .write,
                    directType: "document",
                    parameters: [
                        ScriptingParameter(name: "to", type: "file"),
                        ScriptingParameter(name: "as", type: "text")
                    ]
                )
            ]
        )

        let summary = manifest.formattedSummary()
        #expect(summary.contains("## Scripting Dictionary (sdef) for Pages (com.apple.Pages)"))
        #expect(summary.contains("`export` [direct: document] (to: file, as: text)"))
        #expect(summary.contains("**document**: name: text (ro), path: text (ro)"))
    }

    @Test("read_app_dictionary guides model to Computer Use when app has no sdef")
    func readAppDictionaryMissingSdef() async {
        let result = await SynthesizedScriptRunner.readDictionary(
            appInput: "NonScriptableApp",
            query: "",
            scope: nil,
            grantedApps: ["nonscriptableapp": "com.example.nonscriptable"]
        )

        #expect(result.success)
        #expect(result.output.contains("has no AppleScript scripting dictionary (sdef)"))
        #expect(result.output.contains("run_menu_command"))
        #expect(result.output.contains("operate_app"))
    }

    @Test("run_synthesized_script validates empty script inputs")
    func runSynthesizedScriptEmptyValidation() async {
        let result = await SynthesizedScriptRunner.run(
            script: "",
            language: "applescript",
            reason: "testing empty",
            appInput: "Pages",
            scope: nil,
            grantedApps: [:],
            userRequest: "export"
        )

        #expect(!result.success)
        #expect(result.output.contains("No script code provided"))
    }

    @Test("run_synthesized_script honors unattended refusal without prompting")
    func runSynthesizedScriptUnattendedRefusal() async {
        // Under withUnattendedRun, AICapabilityApprovalCenter refuses all approvals automatically
        await AICapabilityApprovalCenter.withUnattendedRun {
            let result = await SynthesizedScriptRunner.run(
                script: "tell application \"Pages\" to get name of front document",
                language: "applescript",
                reason: "Get document title",
                appInput: "Pages",
                scope: nil,
                grantedApps: ["pages": "com.apple.Pages"],
                userRequest: "what is the name of the document"
            )

            #expect(!result.success)
            #expect(result.output.contains("declined"))
        }
    }

    @Test("AITypedInvocation parses synthesized_script directives from provider text")
    func typedInvocationParsesSynthesizedScript() {
        let text = """
        {"synthesized_script": {"script": "tell application \\"Finder\\" to get name of front window", "language": "applescript", "reason": "Get window name", "app": "Finder"}}
        """

        let invocation = AITypedInvocationResolver.invocation(from: text)
        #expect(invocation != nil)
        #expect(invocation?.kind == .synthesizedScript)
        #expect(invocation?.capabilityID == "appAgent.synthesizedScript")
        #expect(invocation?.arguments["script"] == "tell application \"Finder\" to get name of front window")
        #expect(invocation?.arguments["language"] == "applescript")
        #expect(invocation?.arguments["reason"] == "Get window name")
        #expect(invocation?.arguments["bundleId"] == "Finder")
        #expect(invocation?.requiresApproval == true)
    }
}
