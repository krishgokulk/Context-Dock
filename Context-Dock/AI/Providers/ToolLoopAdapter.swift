import Foundation

/// A single resolved tool call, normalized across provider wire formats.
struct NormalizedToolCall {
    let id: String
    let name: String
    let arguments: [String: Any]
}

/// Usage counters from a single tool-loop round, normalized across providers.
struct ToolRoundUsage {
    let inputTokens: Int?
    let cacheReadTokens: Int?
    let cacheWriteTokens: Int?
    let outputTokens: Int?
}

/// What one provider round produces, normalized for the unified loop.
struct ToolRoundOutput {
    enum Outcome {
        case toolCalls([NormalizedToolCall])
        case finalText(String)
        case refusal(String)
    }
    let outcome: Outcome
    let usage: ToolRoundUsage?
    let finishReasons: [String]?
    let streamed: Bool
    /// Pre-built assistant-turn dict ready to append to the message history.
    /// Filled by the adapter so provider-specific round-trip data is preserved
    /// (Anthropic thinking blocks must be echoed verbatim with their signatures).
    let assistantTurnDict: [String: Any]
}

extension ToolRoundOutput.Outcome {
    var toolCallNames: [String] {
        guard case .toolCalls(let calls) = self else { return [] }
        return calls.map(\.name)
    }
}

/// Per-provider translation layer for `runToolLoop`.
///
/// Each conforming type only translates between normalized types and the
/// provider's wire format. The loop itself owns all shared logic: rounds,
/// budgets, the no-progress stop, caching, receipts, and streaming status.
protocol ToolLoopAdapter {
    var toolFormat: AgentToolRegistry.SchemaFormat { get }
    var provider: AIProvider { get }
    var model: String { get }

    /// Build the initial message history from common inputs.
    /// Adapters that bake the system prompt into messages (OpenAI, Gemini) do so here.
    /// Anthropic leaves the system prompt out of messages; `buildBody` handles it.
    func buildMessages(
        contextPrompt: String,
        message: String,
        history: [ChatMessage],
        imageAttachments: [URL],
        recorder: TurnRecorder?
    ) -> [[String: Any]]

    /// Build the per-round request body.
    /// `contextPrompt` is passed for providers (Anthropic) that put it in the body, not messages.
    func buildBody(messages: [[String: Any]], tools: [[String: Any]], contextPrompt: String) -> [String: Any]

    /// Send one buffered round; returns a normalized result.
    func sendRound(body: [String: Any]) async throws -> ToolRoundOutput

    /// Stream one round; returns a normalized result.
    func streamRound(
        body: [String: Any],
        onEvent: @escaping @Sendable (AIProviderStreamEvent) -> Void
    ) async throws -> ToolRoundOutput

    /// Append tool results to the message history (called after the loop dispatches tools).
    func appendToolResults(
        to messages: [[String: Any]],
        calls: [NormalizedToolCall],
        results: [(success: Bool, output: String, exitCode: Int32?)]
    ) -> [[String: Any]]

    /// Record usage counters in the token ledger.
    func recordUsage(round: ToolRoundOutput)

    /// Add a round entry to the turn trace.
    func noteRound(_ recorder: TurnRecorder?, round: ToolRoundOutput, roundStarted: ContinuousClock.Instant)
}
