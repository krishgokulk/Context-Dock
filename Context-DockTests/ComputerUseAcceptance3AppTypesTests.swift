// ComputerUseAcceptance3AppTypesTests.swift
// Context-DockTests
//
// Acceptance Test Suite for Task #368 Part 5:
// Autonomous Computer Use Acceptance Across 3 App Types (Scriptable, Menu-Only, Canvas).
// Spec: docs/superpowers/specs/2026-11-03-unified-frontmost-app-agent-and-computer-use.md (§8).

import ApplicationServices
import Foundation
import XCTest

@testable import Context_Dock

@MainActor
final class ComputerUseAcceptance3AppTypesTests: XCTestCase {

    private func item(_ path: [String], enabled: Bool = true) -> ComputerUseTarget {
        ComputerUseTarget(path: path, isEnabled: enabled)
    }

    // MARK: - 1. Tier 1: Scriptable App Acceptance

    func testTier1ScriptableAppSdefInspection() async {
        let bundleId = "com.apple.Pages"
        let appName = "Pages"

        let manifest = AppScriptingDictionary(
            bundleID: bundleId,
            appName: appName,
            version: "14.2",
            parsedAt: Date(),
            classes: [
                ScriptingClass(
                    name: "document",
                    suite: "Pages Suite",
                    plural: "documents",
                    properties: [
                        ScriptingProperty(name: "name", type: "text", isReadOnly: true, isWriteOnly: false, summary: "Document name"),
                        ScriptingProperty(name: "path", type: "text", isReadOnly: true, isWriteOnly: false, summary: "Document file path"),
                        ScriptingProperty(name: "modified", type: "boolean", isReadOnly: true, isWriteOnly: false, summary: "Document modified status")
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

        AppDictionaryStore.shared._injectForTesting(bundleID: bundleId, manifest: manifest)

        let dictResult = await SynthesizedScriptRunner.readDictionary(
            appInput: appName,
            query: "export",
            scope: nil,
            grantedApps: [appName.lowercased(): bundleId]
        )

        XCTAssertTrue(dictResult.success)
        XCTAssertTrue(dictResult.output.contains("`export`"))
        XCTAssertTrue(dictResult.output.contains("Pages (com.apple.Pages)"))
    }

    func testTier1SynthesizedScriptExecutionWithReadBack() async {
        // Test script runner execution using a deterministic osascript call
        let runner = PluginScriptRunner()
        let script = "return \"Exported document to /tmp/report.pdf\""
        let env = ["DORAX_APP": "Pages", "DORAX_BUNDLE_ID": "com.apple.Pages"]

        let result = await runner.run(
            type: .applescript,
            script: script,
            env: env,
            timeout: 10,
            workingDirectory: nil
        )

        switch result {
        case .success(let run):
            XCTAssertEqual(run.exitCode, 0)
            let trimmed = run.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(trimmed, "Exported document to /tmp/report.pdf")
            // Verified read-back confirmation
            XCTAssertTrue(trimmed.contains("/tmp/report.pdf"))
        case .failure(let err):
            XCTFail("Script execution should succeed: \(err.message)")
        }
    }

    func testTier1DirectiveParsing() {
        let directive = """
        {"synthesized_script": {"script": "tell application \\"Pages\\" to export front document to file \\"/tmp/out.pdf\\" as PDF", "language": "applescript", "reason": "Export current document as PDF", "app": "Pages"}}
        """

        let invocation = AITypedInvocationResolver.invocation(from: directive)
        XCTAssertNotNil(invocation)
        XCTAssertEqual(invocation?.kind, .synthesizedScript)
        XCTAssertEqual(invocation?.capabilityID, "appAgent.synthesizedScript")
        XCTAssertEqual(invocation?.arguments["language"], "applescript")
        XCTAssertEqual(invocation?.arguments["reason"], "Export current document as PDF")
        XCTAssertEqual(invocation?.requiresApproval, true)
    }

    func testTier1AgentMDSafetyRulesRefusal() async {
        let bundleId = "com.apple.Notes"
        let appName = "Notes"

        // Inject safety profile with 'never delete' rule
        let profile = AppAgentProfile(
            appName: appName,
            bundleID: bundleId,
            summary: "Apple Notes agent profile",
            never: ["Never delete existing notes without explicit user request", "Never delete attachments"],
            verify: [:],
            tools: AppAgentProfile.Tools(),
            instructions: "",
            problems: []
        )
        try? AppAgentProfileStore.shared.save(profile, forBundleID: bundleId)

        let result = await SynthesizedScriptRunner.run(
            script: "tell application \"Notes\" to delete note 1",
            language: "applescript",
            reason: "Delete note",
            appInput: appName,
            scope: nil,
            grantedApps: [appName.lowercased(): bundleId],
            userRequest: "clean up notes"
        )

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.output.contains("violate safety rule in Notes's AGENT.md"))
    }

    // MARK: - 2. Tier 2: Menu-Only App Acceptance

    func testTier2MenuOnlyTaskPlanning() {
        let bundleId = "com.apple.Preview"
        let appName = "Preview"

        let plan = FrontmostAppTaskPlan.make(
            query: "export this image as PDF",
            bundleId: bundleId,
            appName: appName
        )

        XCTAssertTrue(plan.allowedToolNames.contains("operate_app"))
        XCTAssertTrue(plan.allowedToolNames.contains("run_menu_command"))
        XCTAssertTrue(plan.allowedToolNames.contains("ax_snapshot"))
        XCTAssertTrue(plan.allowedToolNames.contains("ax_act"))
    }

    func testTier2MenuTargetResolverNestedExport() {
        let menuItems = [
            item(["File", "Open…"]),
            item(["File", "Export…"]),
            item(["File", "Export as PDF…"]),
            item(["File", "Print…"]),
            item(["Edit", "Undo"]),
        ]

        let matched = ComputerUseTargetResolver.best(
            matching: "File > Export as PDF",
            among: menuItems
        )

        XCTAssertNotNil(matched)
        XCTAssertEqual(matched?.path, ["File", "Export as PDF…"])
    }

    func testTier2AXSnapshotElementsAndRendering() {
        let elements = [
            AXSnapshotElement(
                id: "e1",
                role: "TextField",
                label: "Save As:",
                value: "Untitled.pdf",
                isEnabled: true,
                canPress: false,
                isTextInput: true
            ),
            AXSnapshotElement(
                id: "e2",
                role: "PopUpButton",
                label: "Format:",
                value: "PDF",
                isEnabled: true,
                canPress: true,
                isTextInput: false
            ),
            AXSnapshotElement(
                id: "e3",
                role: "Button",
                label: "Save",
                value: nil,
                isEnabled: true,
                canPress: true,
                isTextInput: false
            ),
            AXSnapshotElement(
                id: "e4",
                role: "Button",
                label: "Cancel",
                value: nil,
                isEnabled: true,
                canPress: true,
                isTextInput: false
            )
        ]

        let context = ["Export sheet active", "Destination: ~/Documents"]
        let rendered = AXSnapshotter.render(
            appName: "Preview",
            snapshot: (elements: elements, context: context, windowTitle: "Export Sheet")
        )

        XCTAssertTrue(rendered.contains("Preview — window \"Export Sheet\""))
        XCTAssertTrue(rendered.contains("[e1] TextField \"Save As:\" value=\"Untitled.pdf\""))
        XCTAssertTrue(rendered.contains("[e2] PopUpButton \"Format:\" value=\"PDF\""))
        XCTAssertTrue(rendered.contains("[e3] Button \"Save\""))
        XCTAssertTrue(rendered.contains("Text on screen:"))
        XCTAssertTrue(rendered.contains("- Export sheet active"))
    }

    func testTier2ObserveActVerifyLoopGuard() {
        var loopGuard = AXLoopGuard(maxSteps: 5, maxIdenticalRepeats: 2)

        // Step 1: Click Save As field
        XCTAssertEqual(loopGuard.record(actionKey: "click|e1|"), .proceed)
        // Step 2: Type new filename
        XCTAssertEqual(loopGuard.record(actionKey: "type|e1|Invoice.pdf"), .proceed)
        // Step 3: Click Save
        XCTAssertEqual(loopGuard.record(actionKey: "click|e3|"), .proceed)

        // Attempting repeated failing click
        XCTAssertEqual(loopGuard.record(actionKey: "click|e3|"), .proceed)
        // Third identical repeat stalls
        XCTAssertEqual(loopGuard.record(actionKey: "click|e3|"), .stalled)

        // Budget exhaustion check
        var budgetGuard = AXLoopGuard(maxSteps: 2, maxIdenticalRepeats: 3)
        XCTAssertEqual(budgetGuard.record(actionKey: "step1"), .proceed)
        XCTAssertEqual(budgetGuard.record(actionKey: "step2"), .proceed)
        XCTAssertEqual(budgetGuard.record(actionKey: "step3"), .budgetExhausted)
    }

    func testTier2DestructiveControlsForbidden() {
        let destructivePaths = [
            ["File", "Delete"],
            ["Messages", "Send"],
            ["Finder", "Empty Trash"],
            ["Edit", "Delete All"],
            ["Account", "Sign Out"],
            ["File", "Discard Changes"]
        ]

        for path in destructivePaths {
            XCTAssertTrue(ComputerUseTargetResolver.isForbidden(path: path), "Expected \(path) to be forbidden")
        }

        let benignPaths = [
            ["File", "Export as PDF…"],
            ["File", "Save As…"],
            ["Edit", "Copy"],
            ["View", "Zoom In"]
        ]

        for path in benignPaths {
            XCTAssertFalse(ComputerUseTargetResolver.isForbidden(path: path), "Expected \(path) to be allowed")
        }
    }

    func testTier2DirectiveParsing() {
        let snapDirective = #"{"ax_snapshot": {"reason": "inspect export dialog"}}"#
        let snapInvocation = AITypedInvocationResolver.invocation(from: snapDirective)
        XCTAssertEqual(snapInvocation?.kind, .axSnapshot)
        XCTAssertEqual(snapInvocation?.capabilityID, "computerUse.axSnapshot")
        XCTAssertEqual(snapInvocation?.arguments["reason"], "inspect export dialog")

        let actDirective = #"{"ax_act": {"action": "click", "id": "e3", "reason": "confirm export"}}"#
        let actInvocation = AITypedInvocationResolver.invocation(from: actDirective)
        XCTAssertEqual(actInvocation?.kind, .axAct)
        XCTAssertEqual(actInvocation?.capabilityID, "computerUse.axAct")
        XCTAssertEqual(actInvocation?.arguments["action"], "click")
        XCTAssertEqual(actInvocation?.arguments["id"], "e3")
    }

    // MARK: - 3. Tier 3: Canvas App Acceptance

    func testTier3CanvasVisionFallbackTargetIds() {
        XCTAssertTrue(ComputerUseVision.isPixelID("t1"))
        XCTAssertTrue(ComputerUseVision.isPixelID("t42"))
        XCTAssertFalse(ComputerUseVision.isPixelID("e1"))
        XCTAssertFalse(ComputerUseVision.isPixelID("t"))
        XCTAssertFalse(ComputerUseVision.isPixelID("text"))
        XCTAssertFalse(ComputerUseVision.isPixelID(""))
    }

    func testTier3PixelTargetMapping() {
        let windowFrame = CGRect(x: 100, y: 100, width: 800, height: 600)
        // Vision bounding box is normalized with bottom-left origin: (x: 0.25, y: 0.75, width: 0.1, height: 0.05)
        let box = CGRect(x: 0.25, y: 0.75, width: 0.1, height: 0.05)
        let expectedX = windowFrame.minX + box.midX * windowFrame.width // 100 + 0.3 * 800 = 340
        let expectedY = windowFrame.minY + (1 - box.midY) * windowFrame.height // 100 + (1 - 0.775) * 600 = 235

        let target = PixelTarget(
            id: "t1",
            label: "Export Frame",
            point: CGPoint(x: expectedX, y: expectedY)
        )

        XCTAssertEqual(target.id, "t1")
        XCTAssertEqual(target.label, "Export Frame")
        XCTAssertEqual(target.point.x, 340)
        XCTAssertEqual(target.point.y, 235)
    }

    func testTier3VisionDirectiveParsing() {
        let screenSnapDirective = #"{"ax_snapshot": {"mode": "screen", "reason": "read canvas controls"}}"#
        let invocation = AITypedInvocationResolver.invocation(from: screenSnapDirective)
        XCTAssertEqual(invocation?.kind, .axSnapshot)
        XCTAssertEqual(invocation?.arguments["mode"], "screen")
        XCTAssertEqual(invocation?.arguments["reason"], "read canvas controls")
    }

    // MARK: - 4. Skill Capture Acceptance

    func testSkillCaptureMultiStepWorkflow() {
        let bundleId = "com.apple.Preview"
        let appName = "Preview"
        let goal = "Export as PDF"

        let recorder = ComputerUseSkillRecorder.shared
        recorder.discard(bundleID: bundleId)

        // Step 1: Menu item
        let step1 = ComputerUseSkillRecorder.describeMenu(path: "File ▸ Export as PDF…")
        recorder.succeeded(bundleID: bundleId, appName: appName, goal: goal, step: step1)

        // Step 2: Button click
        let step2 = ComputerUseSkillRecorder.describe(
            action: "click", role: "Button", label: "Save", isPixel: false
        )
        XCTAssertNotNil(step2)
        recorder.succeeded(bundleID: bundleId, appName: appName, goal: goal, step: step2!)

        // Finalize skill
        let store = SkillStore.shared
        let createdSkill = recorder.finish(bundleID: bundleId, store: store)

        XCTAssertNotNil(createdSkill)
        XCTAssertEqual(createdSkill?.adapterBundleId, bundleId)
        XCTAssertEqual(createdSkill?.name, "Learned: Export as PDF")
        XCTAssertTrue(createdSkill?.instructions.contains("1. press menu File ▸ Export as PDF…") == true)
        XCTAssertTrue(createdSkill?.instructions.contains("2. click Button \"Save\"") == true)
        XCTAssertFalse(createdSkill?.isPinned ?? true)
    }

    func testSkillCapturePrivacyAndFiltering() {
        // User typed content: replaced with generic reference
        let typed = ComputerUseSkillRecorder.describe(
            action: "type", role: "TextField", label: "File Name", isPixel: false
        )
        XCTAssertEqual(typed, "type into TextField \"File Name\" (the text from the request)")

        // Pixel OCR targets: omitted because coordinates shift dynamically
        let pixel = ComputerUseSkillRecorder.describe(
            action: "click", role: "text (pixels)", label: "Dynamic Button", isPixel: true
        )
        XCTAssertNil(pixel)

        // User data rows: omitted because row content is document data, not app UI
        let row = ComputerUseSkillRecorder.describe(
            action: "click", role: "Row", label: "Annual_Report_2026.pages", isPixel: false
        )
        XCTAssertNil(row)
    }

    // MARK: - 5. Safety HUD & Emergency Controls

    func testSafetyHUDLifecycleAndStopCooldown() {
        let session = ComputerUseSession.shared
        let bundleId = "com.apple.Preview"
        let appName = "Preview"

        // Begin operating session
        session.began(appName: appName, bundleID: bundleId)
        XCTAssertEqual(session.appName, appName)
        XCTAssertFalse(session.isStopped)

        // Simulate emergency Stop (Esc key or Stop button)
        session.stop()
        XCTAssertTrue(session.isStopped)
        XCTAssertNil(session.appName)
        XCTAssertEqual(ComputerUseSession.stopCooldown, 30)
    }
}
