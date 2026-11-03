// ComputerUseEscalationPhase3Tests.swift
// Context-DockTests
//
// Tests for Phase 3: Seamless Computer Use Cascading & Menu Normalization.

import ApplicationServices
import Foundation
import Testing

@testable import Context_Dock

@MainActor
@Suite("Frontmost App Agent Phase 3: Seamless Computer Use Cascading Tests")
struct ComputerUseEscalationPhase3Tests {

    private func item(_ path: [String], enabled: Bool = true) -> ComputerUseTarget {
        ComputerUseTarget(path: path, isEnabled: enabled)
    }

    @Test("ComputerUseTargetResolver matches nested menu path hierarchy with '>' delimiter")
    func nestedMenuPathHierarchyWithGreaterDelimiter() {
        let candidates = [
            item(["File", "Export To", "PDF…"]),
            item(["File", "Export To", "Word…"]),
            item(["File", "Print…"]),
        ]

        let chosen = ComputerUseTargetResolver.best(
            matching: "File > Export To > PDF",
            among: candidates
        )

        #expect(chosen != nil)
        #expect(chosen?.path == ["File", "Export To", "PDF…"])
    }

    @Test("ComputerUseTargetResolver matches nested menu path with '▸' delimiter and ellipsis")
    func nestedMenuPathWithChevronDelimiter() {
        let candidates = [
            item(["File", "Export To", "PDF…"]),
            item(["File", "Export To", "Word…"]),
        ]

        let chosen = ComputerUseTargetResolver.best(
            matching: "File ▸ Export To ▸ PDF…",
            among: candidates
        )

        #expect(chosen != nil)
        #expect(chosen?.path == ["File", "Export To", "PDF…"])
    }

    @Test("ComputerUseTargetResolver disambiguates identical titles across different menus")
    func disambiguatesIdenticalTitlesAcrossMenus() {
        let candidates = [
            item(["File", "Settings…"]),
            item(["Tools", "Settings…"]),
        ]

        let chosenFile = ComputerUseTargetResolver.best(
            matching: "File > Settings",
            among: candidates
        )
        #expect(chosenFile?.path.first == "File")

        let chosenTools = ComputerUseTargetResolver.best(
            matching: "Tools > Settings",
            among: candidates
        )
        #expect(chosenTools?.path.first == "Tools")
    }

    @Test("AppToolCatalog.noRouteCard communicates autonomous escalation instead of dead end")
    func noRouteCardCommunicatesAutonomousEscalation() {
        let card = AppToolCatalog.noRouteCard(forBundleId: "com.apple.mail", appName: "Mail")
        #expect(card.fallback.contains("Operating Mail autonomously"))
        #expect(card.fallback.contains("menus"))
        #expect(card.fallback.contains("accelerator"))
    }

    @Test("AgentToolRegistry operate_app supports text parameter for one-shot focusing")
    func operateAppSupportsTextParameter() {
        let registry = AgentToolRegistry()
        let operateApp = registry.tool(named: "operate_app")
        #expect(operateApp != nil)
        #expect(operateApp?.properties["text"] != nil)
        #expect(operateApp?.properties["target"] != nil)
        #expect(operateApp?.properties["reason"] != nil)
    }

    @Test("LanePlan decodes data-to-UI lane cascade with focus restoration")
    func lanePlanDataToUICascade() {
        let snapshot = AppStateSnapshot(
            isRunning: true,
            isFrontmost: false,
            previousFrontmostBundleID: "com.apple.finder"
        )

        let plan = LanePlan.decide(
            request: "Archive this email",
            appName: "Mail",
            needsRunningApp: true,
            bringsAppForward: true,
            state: snapshot
        )

        #expect(plan.bringsForward == true)
        #expect(plan.returnsFocusTo == "com.apple.finder")
        #expect(plan.planCard?.contains("Bring Mail forward") == true)
    }

    @Test("AXUIFocusHelper safely handles invalid PID without crashing")
    func focusHelperHandlesInvalidPID() {
        let result = AXUIFocusHelper.focusSearchOrTextField(in: 0)
        #expect(!result.success)
    }
}
