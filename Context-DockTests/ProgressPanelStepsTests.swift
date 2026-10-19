import Testing

@testable import Context_Dock

// MARK: - The Progress panel's one step list (#199, plan §3)
//
// The panel shows the turn's reasoning (why it acted) above the tool steps (what it did),
// built from the trace — never generated prose. These pin the list down so the Corner and
// the bottom dock, which draw the same panel, cannot drift.

struct ProgressTraceRulesTests {
    @Test func keepsReasoningDropsPlumbing() {
        let visible = ProgressTraceRules.reasoning([
            "Understood: read the newest email",
            "Lane: data",
            "Checking linked actions, CLI, and MCP…",
            "Matching 31 actions…",
            "Best path: mail.recent · Mail adapter",
            "Looking through the available app adapters and tools…",
            "Reading Mail menus…",
        ])
        #expect(visible == [
            "Understood: read the newest email",
            "Lane: data",
            "Best path: mail.recent · Mail adapter",
        ])
    }

    @Test func dropsRepeatedReasoningLines() {
        #expect(ProgressTraceRules.reasoning(["Lane: data", "Lane: data"]) == ["Lane: data"])
    }

    @Test func noReasoningYieldsNothing() {
        #expect(ProgressTraceRules.reasoning(["Thinking…", "Preparing the response…"]).isEmpty)
    }
}

struct ProgressPanelRowsTests {
    private func read(_ title: String) -> ActivityStep {
        ActivityStep(kind: .read, title: title, status: .ok)
    }

    @Test func reasoningSitsAboveTheStepsThatRan() {
        let step = read("Read 1 message")
        let rows = CornerLivePanelLayout.progressRows(
            reasoning: [
                "Understood: read the newest email",
                "Lane: data",
                "Best path: mail.recent · Mail adapter",
                "Matching 31 actions…",
            ],
            steps: [step])

        #expect(rows == [
            .reasoning("Understood: read the newest email"),
            .reasoning("Lane: data"),
            .reasoning("Best path: mail.recent · Mail adapter"),
            .step(step),
        ])
    }

    @Test func aReasoningLineAStepAlreadyStatesIsDropped() {
        // The chosen route and the step that ran it can read the same; keep the richer step.
        let step = read("Chose mail.recent")
        let rows = CornerLivePanelLayout.progressRows(
            reasoning: ["Chose mail.recent"], steps: [step])
        #expect(rows == [.step(step)])
    }

    @Test func reasoningAloneShowsWhenNoToolRan() {
        // The bug this fixes: a turn that reasoned but ran no registered tool used to show
        // "No steps recorded". Now its reasoning is the list.
        let rows = CornerLivePanelLayout.progressRows(
            reasoning: ["Understood: open Mail", "Lane: data"], steps: [])
        #expect(rows == [.reasoning("Understood: open Mail"), .reasoning("Lane: data")])
    }

    @Test func nothingRecordedIsAnEmptyList() {
        #expect(CornerLivePanelLayout.progressRows(reasoning: [], steps: []).isEmpty)
    }
}
