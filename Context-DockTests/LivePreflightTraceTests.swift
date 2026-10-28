import Foundation
import Testing

@testable import Context_Dock

// #44 — the Pet's live trace says which app, whether it is running, the plan, and the route
// about to run. The lines are recorded by the code that knows each fact; these pin that they
// are worded legibly and pass the Progress panel's allow-list while plumbing still does not.

struct LivePreflightTraceTests {
    @Test func aMenuRouteNamesItsPathAndKind() {
        let line = AgentToolNarration.route(
            tool: "run_menu_command", arguments: ["path": "File\u{1F}New Tab"])
        #expect(line == "Route: File ▸ New Tab · menu command")
        #expect(ProgressTraceRules.reasoning([line!]) == [line!])
    }

    @Test func otherActionRoutesAreNamed() {
        #expect(
            AgentToolNarration.route(tool: "operate_app", arguments: ["target": "Check for Updates"])
                == "Route: live menu bar · Check for Updates")
        #expect(
            AgentToolNarration.route(
                tool: "run_adapter_action", arguments: ["action_id": "safari.newTab"])
                == "Route: app action · safari.newTab")
    }

    @Test func readsAndUnknownToolsCarryNoRoute() {
        #expect(AgentToolNarration.route(tool: "read_file", arguments: ["path": "/tmp/x"]) == nil)
        #expect(AgentToolNarration.route(tool: "run_menu_command", arguments: [:]) == nil)
    }

    @Test func appStateSaysRunningOrNot() {
        #expect(AgentToolNarration.appState(name: "Safari", isRunning: true) == "App: Safari is running")
        #expect(
            AgentToolNarration.appState(name: "Safari", isRunning: false)
                == "App: Safari is not running")
        #expect(AgentToolNarration.appState(name: "", isRunning: true) == nil)
    }

    @Test func theTurnsPreflightLinesAllShowLive() {
        let step = "  1. Open a tab — Safari · menu command"
        let trace = [
            "Understood: action", "Target: Safari", "Planned the minimum evidence route",
            "App: Safari is running", "Planned 2 steps · Open a tab", step,
            "Route: File ▸ New Tab · menu command", "Pressing File ▸ New Tab…",
        ]
        #expect(ProgressTraceRules.reasoning(trace) == [
            "Understood: action", "Target: Safari", "App: Safari is running",
            "Planned 2 steps · Open a tab", step, "Route: File ▸ New Tab · menu command",
        ])
    }

    @Test func plumbingStillStaysOut() {
        #expect(!ProgressTraceRules.isPlanLine("Planned the minimum evidence route"))
        #expect(ProgressTraceRules.reasoning(["Matching 31 actions…", "Thinking…"]).isEmpty)
    }
}

// A subscription CLI acts through the MCP server, so its calls are in the recorded steps and
// not in `executed`. An answer reporting that work must not be called unperformed — the
// correction pass re-ran the click and opened two tabs.
struct CLIActionsCountAsPerformedTests {
    @Test func aRecordedMenuClickIsPerformedWork() {
        let steps = [
            ActivityStep(
                kind: .mcp, title: "Ran dorax_run_menu_command via dorax", status: .ok),
            ActivityStep(kind: .read, title: "Read page", status: .ok),
        ]
        let performed = AgentAnswerVerifier.performedActions(in: steps)
        #expect(performed.count == 1)
        #expect(
            !AgentAnswerVerifier.claimsUnperformedWork(
                answer: "I sent File → New Tab to Safari.", executed: performed))
    }

    @Test func aFailedOrRunningStepIsNotPerformedWork() {
        let steps = [
            ActivityStep(kind: .tool, title: "Ran x", status: .failed),
            ActivityStep(kind: .mcp, title: "Ran y", status: .running),
        ]
        #expect(AgentAnswerVerifier.performedActions(in: steps).isEmpty)
    }
}

// New Tab opens no window, so the window diff could not confirm it. The tab list can.
struct TabCountExpectationTests {
    @Test func tabMenuItemsPromiseATabCountChange() {
        #expect(TabCountExpectation.delta(forMenuItem: "New Tab") == 1)
        #expect(TabCountExpectation.delta(forMenuItem: "Close Tab") == -1)
        #expect(TabCountExpectation.delta(forMenuItem: "New Private Window") == nil)
        #expect(TabCountExpectation.delta(forMenuItem: "New Empty Tab Group") == nil)
        #expect(TabCountExpectation.delta(forMenuItem: "Print…") == nil)
    }

    @Test func aMatchingCountIsVerifiedAnyOtherIsNot() {
        let ok = TabCountExpectation.outcome(before: 3, after: 4, delta: 1, appName: "Safari")
        #expect(ok.verified && ok.message == "Safari now has 4 tabs (was 3).")
        let bad = TabCountExpectation.outcome(before: 3, after: 3, delta: 1, appName: "Safari")
        #expect(!bad.verified && bad.message.contains("expected 4"))
    }
}

struct CollapsingMCPWrapperTests {
    private func step(_ kind: ActivityStep.Kind, _ title: String, _ detail: String) -> ActivityStep {
        ActivityStep(kind: kind, title: title, detail: detail, status: .ok)
    }

    @Test func oneClickIsOneRow() {
        let rows = ActivityStep.collapsingMCPWrappers([
            step(.mcp, "Ran dorax_run_menu_command via dorax", "app Safari · path File > New Tab"),
            step(.tool, "Ran run_menu_command", "app Safari · path File > New Tab"),
        ])
        #expect(rows.map(\.title) == ["Ran run_menu_command"])
    }

    @Test func aWrapperWithoutItsInnerStepStays() {
        let wrapper = step(.mcp, "Ran dorax_run_menu_command via dorax", "app Safari · path File > New Tab")
        #expect(ActivityStep.collapsingMCPWrappers([wrapper]).count == 1)
        // Two clicks stay two rows.
        let two = [wrapper, step(.tool, "Ran run_menu_command", "app Safari · path File > New Tab"), wrapper,
            step(.tool, "Ran run_menu_command", "app Safari · path File > New Tab")]
        #expect(ActivityStep.collapsingMCPWrappers(two).count == 2)
    }
}
