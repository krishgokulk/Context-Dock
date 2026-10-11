import Testing
import Foundation
@testable import Context_Dock

// MARK: - Activity rows: one row per thing DoraX ran
//
// Steps are recorded where tools execute, never parsed from narration. Everything here is
// offline: stub tools registered under names no real tool uses, and captured CLI lines.

@MainActor
struct ActivityStepTests {

    private func registerStub(_ name: String, result: AgentToolResult) {
        AgentToolRegistry.shared.register(AgentTool(
            name: name, description: "test stub", properties: [:], required: []
        ) { _, _ in result })
    }

    private var context: AgentToolContext {
        AgentToolContext(commandExecutor: { _, _, _ in (true, "", 0) })
    }

    // MARK: Recording

    @Test func aToolRunRecordsOneRowPerCallWithItsOutcome() async {
        registerStub("activity_test_ok", result: AgentToolResult(
            success: true, output: "volume is 30", displayCommand: "ok"))
        registerStub("activity_test_fail", result: AgentToolResult(
            success: false, output: "Operation not permitted", displayCommand: "fail"))
        var denied = AgentToolResult(success: false, output: "Denied", displayCommand: "deny")
        denied.deniedByUser = true
        registerStub("activity_test_deny", result: denied)

        let recorder = ActivityRecorder()
        await ActivityRecorder.$current.withValue(recorder) {
            _ = await AgentToolRegistry.shared.dispatch(
                name: "activity_test_ok", arguments: ["value": "30"], context: context)
            _ = await AgentToolRegistry.shared.dispatch(
                name: "activity_test_fail", arguments: [:], context: context)
            _ = await AgentToolRegistry.shared.dispatch(
                name: "activity_test_deny", arguments: [:], context: context)
        }

        let steps = recorder.steps
        #expect(steps.map(\.status) == [.ok, .failed, .denied])
        #expect(steps[0].title == "Ran activity_test_ok")
        #expect(steps[0].detail == "value 30")
        #expect(steps[0].output == "volume is 30")
        #expect(steps[1].output == "Operation not permitted")
        #expect(steps.allSatisfy { $0.duration != nil })
    }

    @Test func aTurnThatBindsNoRecorderRecordsNothingIntoAnother() async {
        registerStub("activity_test_unbound", result: AgentToolResult(
            success: true, output: "", displayCommand: "x"))
        let recorder = ActivityRecorder()
        _ = await AgentToolRegistry.shared.dispatch(
            name: "activity_test_unbound", arguments: [:], context: context)
        #expect(recorder.steps.isEmpty)
    }

    @Test func settleClosesARowLeftRunning() {
        let recorder = ActivityRecorder()
        recorder.begin(kind: .command, title: "Ran sleep 100")
        recorder.settle()
        #expect(recorder.steps.first?.status == .failed)
    }

    // MARK: Naming

    @Test func aCapabilityWriteIsRanWithItsInput() {
        let described = ActivityStepNaming.describe(
            tool: "run_capability",
            arguments: ["capability_id": "globalcmd.volume", "input": ["value": "30"]])
        #expect(described.kind == .tool)
        #expect(described.title == "Ran globalcmd.volume")
        #expect(described.detail == "value 30")
    }

    @Test func aStatusReadIsReadByItsTitle() {
        let described = ActivityStepNaming.describe(
            tool: "run_capability",
            arguments: ["capability_id": "globalcmd.bluetooth.status", "input": [:]],
            capabilityTitle: "Bluetooth status — read whether it is on",
            capabilityIsRead: true)
        #expect(described.kind == .read)
        #expect(described.title == "Read Bluetooth status")
    }

    @Test func plumbingIsNotAStep() {
        #expect(ActivityStepNaming.plumbingTools.contains("find_capability"))
        #expect(ActivityStepNaming.plumbingTools.contains("read_tool_result"))
    }

    // MARK: Filler

    @Test func fillerIsDroppedOnceTheTurnIsDone() {
        let narration = [
            "Understanding your request…", "Thinking…", "Running globalcmd.volume…",
            "Running it complete", "Writing answer…", "Resolved app: Safari", "Task complete",
        ]
        #expect(ActivityNarration.durableTrace(narration) == ["Resolved app: Safari"])
    }

    @Test func receiptsBecomeStepsOnlyWhenNothingWasRecorded() {
        let receipt = DoraXActionReceipt(
            command: "route(menuCommand, New Window)", output: "done", success: true)
        let fromReceipts = ActivityStep.steps(recorded: [], receipts: [receipt])
        #expect(fromReceipts.map(\.title) == ["Ran New Window"])

        let recorded = [ActivityStep(kind: .tool, title: "Ran globalcmd.volume", status: .ok)]
        #expect(ActivityStep.steps(recorded: recorded, receipts: [receipt]) == recorded)
    }

    @Test func headerCountsCommandsAndSources() {
        let steps = [
            ActivityStep(kind: .tool, title: "Ran globalcmd.volume", status: .ok),
            ActivityStep(kind: .read, title: "Read Bluetooth status", status: .ok),
        ]
        #expect(ActivitySummary.header(for: steps) == "Ran 1 command, read 1 source")
        #expect(ActivitySummary.header(for: [steps[1]]) == "Read 1 source")
        let failed = [ActivityStep(kind: .providerShell, title: "Ran system_profiler", status: .failed)]
        #expect(ActivitySummary.header(for: failed) == "Ran 1 command, 1 failed")
    }

    // MARK: Verification line

    @Test func aWriteWithNoVerifierSaysOnlyItsResult() {
        let line = ActivitySummary.resultLine(
            result: "Volume 30.", isWrite: true, verification: .executorConfirmed, readBack: nil)
        #expect(line == "Volume 30.")
        #expect(!line.contains("Executor confirmed"))
    }

    @Test func aFailedOrUnavailableCheckIsSaid() {
        let failed = ActivitySummary.resultLine(
            result: "Done.", isWrite: true, verification: .unverified, readBack: nil)
        #expect(failed.contains("Verification failed"))
        let unavailable = ActivitySummary.resultLine(
            result: "Done.", isWrite: true, verification: .notAvailable, readBack: nil)
        #expect(unavailable.contains("Verification unavailable"))
        // A read has nothing to verify.
        let read = ActivitySummary.resultLine(
            result: "Bluetooth is on.", isWrite: false, verification: .unverified, readBack: nil)
        #expect(read == "Bluetooth is on.")
    }

    @Test func aReadBackValueIsShownWithATick() {
        let line = ActivitySummary.resultLine(
            result: "Volume 30", isWrite: true, verification: .verified, readBack: "30")
        #expect(line == "Volume 30 ✓ (read back 30)")
    }

    // MARK: CLI providers

    @Test func aCodexCommandTheSandboxBlockedIsAFailedRow() {
        let started = #"{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc 'system_profiler SPBluetoothDataType'","status":"in_progress"}}"#
        let completed = #"{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc 'system_profiler SPBluetoothDataType'","aggregated_output":"sandbox-exec: Operation not permitted","exit_code":1,"status":"failed"}}"#

        let recorder = ActivityRecorder()
        for line in [started, completed] {
            for event in CLIActivityEvent.codex(streamLine: line) { recorder.apply(event) }
        }
        let step = recorder.steps.first
        #expect(recorder.steps.count == 1)
        #expect(step?.kind == .providerShell)
        #expect(step?.title == "Ran system_profiler SPBluetoothDataType")
        #expect(step?.status == .failed)
        #expect(step?.output.contains("Operation not permitted") == true)
    }

    @Test func claudeCodeBashAndMCPCallsBecomeRows() {
        let assistant = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"defaults read -g AppleInterfaceStyle"}},{"type":"tool_use","id":"toolu_2","name":"mcp__dorax__run_capability","input":{"capability_id":"globalcmd.volume"}}]}}"#
        let user = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","is_error":true,"content":"Permission denied"},{"type":"tool_result","tool_use_id":"toolu_2","content":[{"type":"text","text":"Volume 30"}]}]}}"#

        let recorder = ActivityRecorder()
        for line in [assistant, user] {
            for event in CLIActivityEvent.claudeCode(streamLine: line) { recorder.apply(event) }
        }
        let steps = recorder.steps
        #expect(steps.count == 2)
        #expect(steps[0].kind == .providerShell)
        #expect(steps[0].title == "Ran defaults read -g AppleInterfaceStyle")
        #expect(steps[0].status == .failed)
        #expect(steps[1].kind == .mcp)
        #expect(steps[1].title == "Ran run_capability via dorax")
        #expect(steps[1].status == .ok)
        #expect(steps[1].output == "Volume 30")
    }
}
