import Foundation
import Testing

@testable import Context_Dock

// MARK: - Tool Loop Progress & Stop Tests (#154: E6a)
//
// Verifies:
// 1. Two rounds with nothing new (same output as earlier rounds, or only failures) stop the loop.
// 2. A round with new output resets the no-progress counter.
// 3. Every provider reads its max output tokens limit from the canonical table.
// 4. A stop is recorded in the turn trace with its reason ("no_progress", "step_limit", "cancelled").

struct ToolLoopProgressStopTests {

    // MARK: - Progress Tracker Unit Tests

    @Test func twoEmptyRoundsStopTheLoop() {
        var tracker = ToolLoopProgressTracker()

        let round1Stopped = tracker.recordRound(results: [(success: true, output: "")])
        #expect(!round1Stopped)
        #expect(tracker.consecutiveNoProgressCount == 1)

        let round2Stopped = tracker.recordRound(results: [(success: true, output: "")])
        #expect(round2Stopped)
        #expect(tracker.consecutiveNoProgressCount == 2)
    }

    @Test func aRoundWithNewOutputResetsTheCount() {
        var tracker = ToolLoopProgressTracker()

        // Round 1 fails
        let r1Stopped = tracker.recordRound(results: [(success: false, output: "Error: File not found")])
        #expect(!r1Stopped)
        #expect(tracker.consecutiveNoProgressCount == 1)

        // Round 2 produces new successful output -> resets count
        let r2Stopped = tracker.recordRound(results: [(success: true, output: "tax_2019_final.pdf")])
        #expect(!r2Stopped)
        #expect(tracker.consecutiveNoProgressCount == 0)

        // Round 3 produces empty output -> count becomes 1 again
        let r3Stopped = tracker.recordRound(results: [(success: true, output: "")])
        #expect(!r3Stopped)
        #expect(tracker.consecutiveNoProgressCount == 1)

        // Round 4 produces second empty output in a row -> stops
        let r4Stopped = tracker.recordRound(results: [(success: true, output: "")])
        #expect(r4Stopped)
        #expect(tracker.consecutiveNoProgressCount == 2)
    }

    @Test func repeatedOutputsCountAsNoProgress() {
        var tracker = ToolLoopProgressTracker()

        // Round 1 produces "data"
        let r1 = tracker.recordRound(results: [(success: true, output: "data")])
        #expect(!r1)
        #expect(tracker.consecutiveNoProgressCount == 0)

        // Round 2 produces the exact same output -> no progress
        let r2 = tracker.recordRound(results: [(success: true, output: "data")])
        #expect(!r2)
        #expect(tracker.consecutiveNoProgressCount == 1)

        // Round 3 produces the exact same output again -> stops after two in a row
        let r3 = tracker.recordRound(results: [(success: true, output: "data")])
        #expect(r3)
        #expect(tracker.consecutiveNoProgressCount == 2)
    }

    @Test func consecutiveFailuresStopTheLoop() {
        var tracker = ToolLoopProgressTracker()

        let r1 = tracker.recordRound(results: [(success: false, output: "Command failed 1")])
        #expect(!r1)
        #expect(tracker.consecutiveNoProgressCount == 1)

        let r2 = tracker.recordRound(results: [(success: false, output: "Command failed 2")])
        #expect(r2)
        #expect(tracker.consecutiveNoProgressCount == 2)
    }

    @Test func whitespaceOnlyOutputCountsAsNoProgress() {
        var tracker = ToolLoopProgressTracker()

        let r1 = tracker.recordRound(results: [(success: true, output: "   \n\t")])
        #expect(!r1)
        #expect(tracker.consecutiveNoProgressCount == 1)

        let r2 = tracker.recordRound(results: [(success: true, output: "\n")])
        #expect(r2)
        #expect(tracker.consecutiveNoProgressCount == 2)
    }

    @Test func mixedResultsInSingleRoundWithOneNewSuccessCountsAsProgress() {
        var tracker = ToolLoopProgressTracker()

        let r1 = tracker.recordRound(results: [
            (success: false, output: "Err"),
            (success: true, output: "first_discovery"),
        ])
        #expect(!r1)
        #expect(tracker.consecutiveNoProgressCount == 0)

        // Same output in round 2:
        let r2 = tracker.recordRound(results: [
            (success: false, output: "Err"),
            (success: true, output: "first_discovery"),
        ])
        #expect(!r2)
        #expect(tracker.consecutiveNoProgressCount == 1)
    }

    // MARK: - Max Output Tokens Table Tests

    @Test func eachProviderReadsItsLimitFromTable() {
        #expect(ToolLoopBudget.maxTokens(for: .anthropic) == 16000)
        #expect(ToolLoopBudget.maxTokens(for: .claudeCode) == 16000)
        #expect(ToolLoopBudget.maxTokens(for: .claudeBridge) == 16000)
        #expect(ToolLoopBudget.maxTokens(for: .openAI) == 8192)
        #expect(ToolLoopBudget.maxTokens(for: .googleGemini) == 8192)
        #expect(ToolLoopBudget.maxTokens(for: .ollama) == 8192)
        #expect(ToolLoopBudget.maxTokens(for: .openAICompatible) == 8192)
        #expect(ToolLoopBudget.maxTokens(for: .kimi) == 8192)
        #expect(ToolLoopBudget.maxTokens(for: .chatGPTSubscription) == 8192)
        #expect(ToolLoopBudget.maxTokens(for: .chatGPTBridge) == 8192)
        #expect(ToolLoopBudget.maxTokens(for: .onDevice) == 2048)
        #expect(ToolLoopBudget.maxTokens(for: .shortcuts) == 8192)
    }

    // MARK: - Turn Trace Stop Reason Tests

    @Test func stopReasonIsRecordedInTraceAndRoundTripsViaJSON() throws {
        var trace = TurnTrace(provider: "anthropic")
        trace.stopReason = "no_progress"

        let line = try #require(TurnRecorder.line(for: trace))
        #expect(line.contains("\"dorax.stop_reason\":\"no_progress\""))

        let traces = TurnTraceReport.traces(inLog: "2026-11-07T12:00:00Z \(line)\n")
        #expect(traces.first?.stopReason == "no_progress")
    }

    // MARK: - Loop End-to-End Stop Integration Tests

    private final class MockToolTransport: OpenAIToolTransport, @unchecked Sendable {
        let ledgerProvider: AIProvider
        var responses: [OpenAIToolResponse] = []
        var sentBodies: [[String: Any]] = []
        private var callIndex = 0

        init(ledgerProvider: AIProvider = .openAI, responses: [OpenAIToolResponse]) {
            self.ledgerProvider = ledgerProvider
            self.responses = responses
        }

        func send(
            endpoint: String,
            apiKey: String?,
            body: [String: Any],
            timeout: TimeInterval,
            extraHeaders: [String: String]
        ) async throws -> OpenAIToolResponse {
            sentBodies.append(body)
            guard callIndex < responses.count else {
                throw AIServiceError.emptyResponse("Mock responses exhausted")
            }
            let resp = responses[callIndex]
            callIndex += 1
            return resp
        }
    }

    @Test func openAILoopStopsAfterTwoEmptyRoundsAndRecordsStopReason() async throws {
        // Prepare two responses, each returning a tool call
        let toolCall1 = OpenAIToolResponse.ToolCall(
            id: "call_1", type: "function",
            function: .init(name: "mock_empty_tool", arguments: "{}"))
        let resp1 = OpenAIToolResponse(
            choices: [
                .init(
                    message: .init(role: "assistant", content: nil, tool_calls: [toolCall1]),
                    finish_reason: "tool_calls")
            ], usage: nil)

        let toolCall2 = OpenAIToolResponse.ToolCall(
            id: "call_2", type: "function",
            function: .init(name: "mock_empty_tool", arguments: "{}"))
        let resp2 = OpenAIToolResponse(
            choices: [
                .init(
                    message: .init(role: "assistant", content: nil, tool_calls: [toolCall2]),
                    finish_reason: "tool_calls")
            ], usage: nil)

        let mockTransport = MockToolTransport(ledgerProvider: .openAI, responses: [resp1, resp2])
        let service = AIProviderService.shared

        let sinkFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("turn-trace-test-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: sinkFile) }
        let defaults = UserDefaults(suiteName: "ToolLoopStopTests.\(UUID().uuidString)")!
        defaults.set(true, forKey: DoraXTurnLog.enabledKey)
        let sink = DoraXTurnLog.Sink(defaults: defaults, fileURL: sinkFile)

        let (response, _) = try await TurnRecorder.run(provider: "openAI", sink: sink) {
            try await service.sendOpenAIWithTools(
                message: "what did I name my 2019 tax PDF?",
                contextPrompt: "You are DoraX.",
                apiKey: "test-key",
                history: [],
                commandExecutor: { _, _, _ in (true, "", 0) },
                customTools: [
                    [
                        "type": "function",
                        "function": [
                            "name": "mock_empty_tool",
                            "description": "mock tool",
                            "parameters": ["type": "object", "properties": [:] as [String: Any]],
                        ] as [String: Any],
                    ]
                ],
                maxIterations: 10,
                endpoint: "https://api.openai.com/v1",
                model: "gpt-4o",
                transport: mockTransport,
                simulateAllTools: false
            )
        }

        // Even though maxIterations was 10, the loop stopped after 2 rounds because both were empty!
        #expect(mockTransport.sentBodies.count == 2)
        #expect(mockTransport.sentBodies[0]["max_tokens"] as? Int == 8192)
        #expect(response.contains("I stopped after consecutive attempts yielded no new results"))

        sink.flush()
        let log = try String(contentsOf: sinkFile, encoding: .utf8)
        let trace = try #require(TurnTraceReport.traces(inLog: log).first)
        #expect(trace.stopReason == "no_progress")
    }
}
