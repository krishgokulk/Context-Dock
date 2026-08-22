import Foundation
import Testing

@testable import Context_Dock

@MainActor
struct TaskRunHarnessTests {
    @Test func failurePoliciesAreDeterministicAndLocal() {
        #expect(TaskRunStore.classifyFailure("Reminders permission is not granted").kind
            == .permissionRequired)
        #expect(TaskRunStore.classifyFailure("Reminders permission is not granted").policy
            == .requestApproval)
        #expect(TaskRunStore.classifyFailure("The cached menu is stale; refresh context").policy
            == .refreshContext)
        #expect(TaskRunStore.classifyFailure("Request temporarily timed out").policy == .retry)
        #expect(TaskRunStore.classifyFailure("No route is available").policy == .fallback)
        #expect(TaskRunStore.classifyFailure("Verification mismatch").policy == .repair)
        #expect(TaskRunStore.classifyFailure("Already called with repeated arguments").policy
            == .stop)
    }

    @Test func actionKeysAreStableAcrossDictionaryOrderingAndIgnoreExplanation() {
        let first = AgentToolRegistry.callSignature(
            name: "run_capability",
            arguments: [
                "capability_id": "reminders.create",
                "input": ["title": "DoraX", "dueDate": "2026-08-23"],
                "explanation": "first wording",
            ])
        let second = AgentToolRegistry.callSignature(
            name: "run_capability",
            arguments: [
                "explanation": "different wording",
                "input": ["dueDate": "2026-08-23", "title": "DoraX"],
                "capability_id": "reminders.create",
            ])
        #expect(first == second)
    }

    @Test func onlySideEffectsUseDurableReplayProtection() {
        #expect(AgentToolRegistry.isReplaySensitive(
            name: "run_capability",
            arguments: ["capability_id": "reminders.create"]))
        #expect(!AgentToolRegistry.isReplaySensitive(
            name: "run_capability",
            arguments: ["capability_id": "reminders.list"]))
        #expect(AgentToolRegistry.isReplaySensitive(
            name: "run_menu_command", arguments: [:]))
    }

    @Test func legacyTaskRunsDecodeWithSafeHarnessDefaults() throws {
        let json = """
            {
              "id": "D155CC16-BC7B-4B63-A97D-D768FC97B3F9",
              "request": "Open Safari",
              "provider": "openAI",
              "createdAt": "2026-08-22T12:00:00Z",
              "updatedAt": "2026-08-22T12:00:01Z",
              "status": "completed",
              "receipts": []
            }
            """
        let run = try JSONDecoder.taskRun.decode(
            TaskRunStore.Run.self, from: Data(json.utf8))
        #expect(run.objective == "Open Safari")
        #expect(run.budget.maxToolCalls == 5)
        #expect(run.completedNodes.isEmpty)
        #expect(run.failures.isEmpty)
        #expect(run.actionCheckpoints.isEmpty)
    }
}
