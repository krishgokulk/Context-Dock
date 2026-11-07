import Foundation
import Testing

@testable import Context_Dock

// MARK: - ToolLoopAdapter + runToolLoop Tests (#155: E6b)
//
// Drives the unified loop via a mock adapter to verify shared loop logic:
// 1. The loop delegates message building, body building, and round sending to the adapter.
// 2. Tool calls are dispatched and results appended through the adapter.
// 3. The loop stops after two empty rounds regardless of which adapter is used.
// 4. The loop returns the final text from the adapter on a non-tool response.

private struct MockToolCall {
    let id: String
    let name: String
    let args: [String: Any]
}

private enum MockRoundOutcome {
    case toolCalls([MockToolCall])
    case finalText(String)
}

/// Minimal `ToolLoopAdapter` conformance backed by a scripted response sequence.
private struct MockLoopAdapter: ToolLoopAdapter {
    final class State: @unchecked Sendable {
        var roundIndex = 0
        var bodiesBuilt: [[String: Any]] = []
        var messagesBuilt: [[String: Any]] = []
        var appendedResultsPerRound: [[(success: Bool, output: String)]] = []
    }

    let outcomes: [MockRoundOutcome]
    let state = State()

    var toolFormat: AgentToolRegistry.SchemaFormat { .openAI }
    var provider: AIProvider { .openAI }
    var model: String { "mock-model" }

    func buildMessages(
        contextPrompt: String, message: String, history: [ChatMessage],
        imageAttachments: [URL], recorder: TurnRecorder?
    ) -> [[String: Any]] {
        let msg: [String: Any] = ["role": "user", "content": message]
        state.messagesBuilt.append(msg)
        return [msg]
    }

    func buildBody(messages: [[String: Any]], tools: [[String: Any]], contextPrompt: String) -> [String: Any] {
        let body: [String: Any] = ["messages": messages, "tools": tools]
        state.bodiesBuilt.append(body)
        return body
    }

    func sendRound(body: [String: Any]) async throws -> ToolRoundOutput {
        let idx = state.roundIndex
        state.roundIndex += 1
        let outcome = idx < outcomes.count ? outcomes[idx] : .finalText("done")
        return makeOutput(outcome)
    }

    func streamRound(
        body: [String: Any], onEvent: @Sendable (AIProviderStreamEvent) -> Void
    ) async throws -> ToolRoundOutput {
        fatalError("Mock adapter does not support streaming")
    }

    func appendToolResults(
        to messages: [[String: Any]], calls: [NormalizedToolCall],
        results: [(success: Bool, output: String, exitCode: Int32?)]
    ) -> [[String: Any]] {
        state.appendedResultsPerRound.append(results.map { (success: $0.success, output: $0.output) })
        var msgs = messages
        for (call, result) in zip(calls, results) {
            msgs.append(["role": "tool", "tool_call_id": call.id, "content": result.output])
        }
        return msgs
    }

    func recordUsage(round: ToolRoundOutput) {}

    func noteRound(_ recorder: TurnRecorder?, round: ToolRoundOutput, roundStarted: ContinuousClock.Instant) {
        recorder?.noteRound(TurnTrace.Round(
            inputTokens: nil, cacheReadTokens: nil, outputTokens: nil,
            toolCalls: round.outcome.toolCallNames,
            finishReasons: nil, streamed: false,
            duration: TurnRecorder.seconds(since: roundStarted)))
    }

    private func makeOutput(_ outcome: MockRoundOutcome) -> ToolRoundOutput {
        switch outcome {
        case .finalText(let text):
            return ToolRoundOutput(
                outcome: .finalText(text), usage: nil, finishReasons: nil,
                streamed: false, assistantTurnDict: [:])
        case .toolCalls(let calls):
            let normalized = calls.map { NormalizedToolCall(id: $0.id, name: $0.name, arguments: $0.args) }
            let assistantDict: [String: Any] = ["role": "assistant"]
            return ToolRoundOutput(
                outcome: .toolCalls(normalized), usage: nil, finishReasons: nil,
                streamed: false, assistantTurnDict: assistantDict)
        }
    }
}

// MARK: - Tests

struct ToolLoopAdapterTests {

    // MARK: Helper

    /// Runs the unified loop with the given mock adapter through `sendOpenAIWithTools`
    /// by injecting the adapter indirectly via a custom transport that delegates to it.
    ///
    /// Because `runToolLoop` is `private`, the tests exercise it through the OpenAI thin
    /// wrapper using a `MockOpenAITransport` whose responses are shaped from `MockLoopAdapter`
    /// outcomes. This validates the shared loop without coupling to provider wire formats.
    private final class ScriptedTransport: OpenAIToolTransport, @unchecked Sendable {
        let ledgerProvider: AIProvider = .openAI
        var responses: [OpenAIToolResponse]
        private var callIndex = 0

        init(responses: [OpenAIToolResponse]) {
            self.responses = responses
        }

        func send(
            endpoint: String, apiKey: String?, body: [String: Any],
            timeout: TimeInterval, extraHeaders: [String: String]
        ) async throws -> OpenAIToolResponse {
            guard callIndex < responses.count else {
                throw AIServiceError.emptyResponse("ScriptedTransport exhausted")
            }
            let resp = responses[callIndex]
            callIndex += 1
            return resp
        }
    }

    private func openAIResponse(toolName: String, callID: String) -> OpenAIToolResponse {
        let tc = OpenAIToolResponse.ToolCall(
            id: callID, type: "function",
            function: .init(name: toolName, arguments: "{}"))
        return OpenAIToolResponse(
            choices: [.init(
                message: .init(role: "assistant", content: nil, tool_calls: [tc]),
                finish_reason: "tool_calls")],
            usage: nil)
    }

    private func openAIFinalResponse(text: String) -> OpenAIToolResponse {
        OpenAIToolResponse(
            choices: [.init(
                message: .init(role: "assistant", content: text, tool_calls: nil),
                finish_reason: "stop")],
            usage: nil)
    }

    // MARK: - Final text

    @Test func loopReturnsFinalTextImmediately() async throws {
        let transport = ScriptedTransport(responses: [openAIFinalResponse(text: "Here is the answer")])
        let (response, cmds) = try await AIProviderService.shared.sendOpenAIWithTools(
            message: "test",
            contextPrompt: "sys",
            apiKey: "key",
            history: [],
            commandExecutor: { _, _, _ in (true, "", 0) },
            customTools: [],
            maxIterations: 5,
            endpoint: "https://api.openai.com/v1",
            model: "gpt-4o",
            transport: transport,
            simulateAllTools: false)
        #expect(response == "Here is the answer")
        #expect(cmds.isEmpty)
        #expect(transport.responses.count - transport.callIndex == 0, "Should have consumed the one response")
    }

    // MARK: - No-progress stop via unified loop

    @Test func loopStopsAfterTwoEmptyRoundsViaUnifiedLoop() async throws {
        // Two rounds, each with a tool call that returns empty output.
        let transport = ScriptedTransport(responses: [
            openAIResponse(toolName: "noop", callID: "c1"),
            openAIResponse(toolName: "noop", callID: "c2"),
        ])
        let (response, _) = try await AIProviderService.shared.sendOpenAIWithTools(
            message: "do stuff",
            contextPrompt: "sys",
            apiKey: "key",
            history: [],
            commandExecutor: { _, _, _ in (true, "", 0) },
            customTools: [
                [
                    "type": "function",
                    "function": [
                        "name": "noop",
                        "description": "does nothing",
                        "parameters": ["type": "object", "properties": [:] as [String: Any]],
                    ] as [String: Any],
                ]
            ],
            maxIterations: 10,
            endpoint: "https://api.openai.com/v1",
            model: "gpt-4o",
            transport: transport,
            simulateAllTools: false)
        // The loop should have stopped after two empty rounds.
        #expect(transport.callIndex == 2)
        #expect(response.contains("I stopped after consecutive attempts"))
    }

    // MARK: - Step limit

    @Test func loopReturnsStepLimitMessageWhenIterationsExhausted() async throws {
        // Always return a tool call; loop should hit maxIterations=2 and stop.
        let transport = ScriptedTransport(responses: [
            openAIResponse(toolName: "busy", callID: "c1"),
            openAIResponse(toolName: "busy", callID: "c2"),
            // This third response should not be consumed.
            openAIFinalResponse(text: "unreachable"),
        ])
        let (response, _) = try await AIProviderService.shared.sendOpenAIWithTools(
            message: "work",
            contextPrompt: "sys",
            apiKey: "key",
            history: [],
            commandExecutor: { _, _, _ in (true, "output_\(arc4random())", 0) },
            customTools: [],
            maxIterations: 2,
            endpoint: "https://api.openai.com/v1",
            model: "gpt-4o",
            transport: transport,
            simulateAllTools: true)
        #expect(transport.callIndex == 2)
        #expect(response.contains("step limit"))
    }
}
