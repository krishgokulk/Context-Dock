import Foundation

/// How much room a tool loop leaves the model to answer in.
///
/// Keeps per-provider output token limits in one canonical table across all tool loops.
/// Anthropic defaults to 16,000 so models that think before they write (adaptive thinking)
/// do not exhaust their budget before emitting visible tool calls or answers. Other
/// providers default to 8,192.
enum ToolLoopBudget {
    /// Default output token budget when a provider is not explicitly mapped.
    static let defaultMaxTokens = 8192

    /// Output token budget per provider for tool loops.
    static let maxTokensByProvider: [AIProvider: Int] = [
        .anthropic: 16000,
        .claudeCode: 16000,
        .claudeBridge: 16000,
        .openAI: 8192,
        .googleGemini: 8192,
        .ollama: 8192,
        .openAICompatible: 8192,
        .kimi: 8192,
        .chatGPTSubscription: 8192,
        .chatGPTBridge: 8192,
        .onDevice: 2048,
        .shortcuts: 8192,
    ]

    /// Legacy convenience property returning the default limit.
    static var maxTokens: Int { defaultMaxTokens }

    /// Returns the maximum output tokens for the specified provider.
    static func maxTokens(for provider: AIProvider) -> Int {
        maxTokensByProvider[provider] ?? defaultMaxTokens
    }
}

/// Tracks whether tool calls in a tool loop are making forward progress.
///
/// A loop ends when:
/// 1. The model finishes with prose (normal completion).
/// 2. The loop hits `maxIterations` (step limit).
/// 3. The user stops the turn (cancellation).
/// 4. Two consecutive rounds add nothing new (same outputs as earlier rounds, or only failures).
struct ToolLoopProgressTracker: Sendable {
    /// Consecutive rounds that produced no new output or only failures.
    private(set) var consecutiveNoProgressCount: Int = 0

    /// Outputs from successful tool calls seen in earlier rounds.
    private(set) var seenOutputs: Set<String> = []

    /// Max consecutive rounds without progress before the loop stops.
    let maxConsecutiveNoProgress: Int

    init(maxConsecutiveNoProgress: Int = 2) {
        self.maxConsecutiveNoProgress = maxConsecutiveNoProgress
    }

    /// Evaluates the results of a round's tool executions.
    ///
    /// - Parameter results: Array of (success, output) for all tool calls executed in the round.
    /// - Returns: `true` if the loop should stop due to no progress (consecutiveNoProgressCount >= maxConsecutiveNoProgress).
    mutating func recordRound(results: [(success: Bool, output: String)]) -> Bool {
        guard !results.isEmpty else { return false }

        var foundNewProgress = false

        for result in results {
            guard result.success else { continue }
            let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if !seenOutputs.contains(trimmed) {
                foundNewProgress = true
                seenOutputs.insert(trimmed)
            }
        }

        if foundNewProgress {
            consecutiveNoProgressCount = 0
        } else {
            consecutiveNoProgressCount += 1
        }

        return consecutiveNoProgressCount >= maxConsecutiveNoProgress
    }
}

// MARK: - E7a: Per-round focus tracker

/// Decides which tool category to show each round — by rule, not model call.
///
/// State machine:
///   first round:  pure question → answer (zero tools); action request → inspect
///   after inspect with calls → act
///   after act with calls → verify
private struct RoundFocusTracker {
    private let isPureQuestion: Bool
    private var hasInspectedWithCalls = false
    private var hasActedWithCalls = false

    init(message: String) {
        isPureQuestion = !message.isEmpty
            && GeneralAIActionResolver.shared.asksOnly(message)
            && !ChatRouteResolver.isActionRequest(message)
    }

    mutating func nextFocus() -> TurnFocus {
        if hasActedWithCalls { return .verify }
        if hasInspectedWithCalls { return .act }
        return isPureQuestion ? .answer : .inspect
    }

    mutating func record(focus: TurnFocus, toolCallCount: Int) {
        guard toolCallCount > 0 else { return }
        switch focus {
        case .inspect: hasInspectedWithCalls = true
        case .act:     hasActedWithCalls = true
        default: break
        }
    }
}

extension AIProviderService {
    // MARK: - Tool Definitions

    /// Dispatch a custom L2 extension tool call. Returns (success, output).
    ///
    /// An extension is arbitrary code nobody has judged, so it goes through the same outbound
    /// gate as every registered tool: once the turn holds private data and untrusted content it
    /// asks first, or refuses when unattended.
    private func dispatchCustomTool(
        name: String, arguments: [String: Any], turn: AgentTurnToken, chatScope: GeneralChatScope?
    ) async -> (Bool, String) {
        let registry = AgentToolRegistry.shared
        if let stopped = await registry.gateOutbound(
            target: OutboundGate.unknownToolTarget, what: "extension tool: \(name)",
            turn: turn, chatScope: chatScope)
        {
            return (false, stopped.output)
        }
        let (success, output) = await L2ExtensionManager.shared.execute(toolName: name, arguments: arguments)
        await registry.taint.record(
            toolName: name, arguments: arguments, output: output, succeeded: success, turn: turn)
        return (success, output)
    }

    // MARK: - Unified Tool Loop

    private func runToolLoop<A: ToolLoopAdapter>(
        adapter: A,
        message: String,
        contextPrompt: String,
        history: [ChatMessage],
        commandExecutor: @escaping (String, String, Bool) async -> (Bool, String, Int32),
        customTools: [[String: Any]],
        maxIterations: Int,
        imageAttachments: [URL],
        userContext: UserContext,
        chatScope: GeneralChatScope?,
        grantedApps: [String: String],
        simulateAllTools: Bool,
        onStream: (@Sendable (AIProviderStreamEvent) -> Void)?,
        onStatus: ((String) -> Void)?
    ) async throws -> (finalResponse: String, executedCommands: [ExecutedCommand]) {

        let turn = await AgentToolRegistry.shared.beginTurn(
            userText: TurnUserText.resolve(history: history, message: message),
            promptBlocks: [contextPrompt, message],
            startsPrivate: OutboundGate.isPrivateDataApp(
                bundleID: AgentToolRegistry.scopedBundleID(for: chatScope)),
            startsUntrusted: OutboundGate.isThirdPartyContentApp(
                bundleID: AgentToolRegistry.scopedBundleID(for: chatScope)))
        defer { AgentToolRegistry.shared.endTurn(turn) }
        let recorder = TurnRecorder.current
        recorder?.notePass()

        var executedCommands: [ExecutedCommand] = []
        var streamingUnavailable = false

        var messages = adapter.buildMessages(
            contextPrompt: contextPrompt, message: message,
            history: history, imageAttachments: imageAttachments, recorder: recorder)

        let allTools = await AgentToolRegistry.shared.schemas(format: adapter.toolFormat) + customTools
        onStatus?("Found \(allTools.count) available tools; choosing the best route…")
        recorder?.noteModel(adapter.model)
        // noteToolsSent is called per-round after focus filtering (E7a); prompt section size
        // is recorded once against the full set since that is the per-round schema budget.
        recorder?.notePromptSections(TurnRecorder.toolSchemaSection(allTools))

        var roundsUsed = 0
        var toolCallsSeen = 0
        var progressTracker = ToolLoopProgressTracker()
        var focusTracker = RoundFocusTracker(message: message)
        defer {
            AgentTurnDiagnostics.record(
                model: adapter.model, toolsOffered: allTools.count,
                rounds: roundsUsed, toolCalls: toolCallsSeen)
        }

        for _ in 0..<maxIterations {
            if Task.isCancelled {
                recorder?.noteStopReason("cancelled")
                return ("Stopped.", executedCommands)
            }
            roundsUsed += 1

            // E7a: pick focus for this round and trim the tool set.
            let focus = focusTracker.nextFocus()
            let roundTools = AIToolBudget.apply(focus: focus, to: allTools)
            recorder?.noteToolsSent(TurnRecorder.toolNames(in: roundTools))

            var body = adapter.buildBody(messages: messages, tools: roundTools, contextPrompt: contextPrompt)
            // OpenAI-compatible providers error on an empty tools array; Anthropic silently
            // accepts it but the spec says omit the key. Remove both keys for .answer so the
            // model answers from context and no provider is surprised by [].
            if focus == .answer {
                body.removeValue(forKey: "tools")
                body.removeValue(forKey: "tool_choice")
            }
            let roundStarted = ContinuousClock.now

            var roundOutput: ToolRoundOutput?
            if let onStream, !streamingUnavailable {
                do {
                    roundOutput = try await adapter.streamRound(body: body, onEvent: onStream)
                } catch let error as AIServiceError {
                    if case .authenticationFailed = error { throw error }
                    streamingUnavailable = true
                    recorder?.noteFallback("stream_to_buffered")
                }
            }
            if roundOutput == nil {
                roundOutput = try await adapter.sendRound(body: body)
            }
            let result = roundOutput!

            adapter.recordUsage(round: result)
            adapter.noteRound(recorder, round: result, roundStarted: roundStarted)
            recorder?.noteRoundFocus(focus)

            switch result.outcome {
            case .refusal(let partial):
                recorder?.noteStopReason("refusal")
                return (
                    partial.isEmpty
                        ? "The provider declined this request."
                        : "The provider declined this request partway through:\n\n\(partial)",
                    executedCommands
                )

            case .finalText(let text):
                onStatus?("Preparing the final response…")
                return (text.isEmpty ? "(no response)" : text, executedCommands)

            case .toolCalls(let calls):
                focusTracker.record(focus: focus, toolCallCount: calls.count)
                toolCallsSeen += calls.count
                messages.append(result.assistantTurnDict)

                var roundResults: [(success: Bool, output: String, exitCode: Int32?)] = []
                for call in calls {
                    var (success, output): (Bool, String) = (false, "")
                    var exitCode: Int32?
                    if let route = AgentToolNarration.route(tool: call.name, arguments: call.arguments) {
                        onStatus?(route)
                    }
                    onStatus?(AgentToolNarration.start(tool: call.name, arguments: call.arguments))
                    if simulateAllTools {
                        success = true
                        output = "Simulated \(call.name) tool call"
                        executedCommands.append(ExecutedCommand(command: call.name, output: output, success: true))
                    } else if let dispatched = await AgentToolRegistry.shared.dispatch(
                        name: call.name,
                        arguments: call.arguments,
                        context: AgentToolContext(
                            commandExecutor: commandExecutor, userContext: userContext,
                            userRequest: message,
                            attachments: imageAttachments, chatScope: chatScope,
                            grantedApps: grantedApps, turn: turn, onStatus: onStatus)
                    ) {
                        success = dispatched.success
                        output = dispatched.output
                        exitCode = dispatched.exitCode
                        executedCommands.append(ExecutedCommand(
                            command: dispatched.displayCommand,
                            output: output,
                            success: success,
                            isVerification: call.name == "verify_outcome"))
                        onStatus?(AgentToolNarration.finish(
                            displayCommand: dispatched.displayCommand, success: success, output: output))
                    } else {
                        (success, output) = await dispatchCustomTool(
                            name: call.name, arguments: call.arguments, turn: turn, chatScope: chatScope)
                        executedCommands.append(ExecutedCommand(
                            command: "\(call.name)(\(call.arguments))", output: output, success: success))
                    }
                    roundResults.append((success: success, output: output, exitCode: exitCode))
                }

                messages = adapter.appendToolResults(
                    to: messages,
                    calls: calls,
                    results: roundResults.map { (success: $0.success, output: $0.output, exitCode: $0.exitCode) })

                if progressTracker.recordRound(results: roundResults.map { (success: $0.success, output: $0.output) }) {
                    recorder?.noteStopReason("no_progress")
                    onStatus?("No progress after repeated attempts; answering with what is known…")
                    return (
                        executedCommands.isEmpty
                            ? "I could not find what was requested after multiple attempts."
                            : "I stopped after consecutive attempts yielded no new results. What was found so far is listed below.",
                        executedCommands
                    )
                }
                onStatus?("Understanding the returned tool data…")
            }
        }
        recorder?.noteStopReason("step_limit")
        return (
            executedCommands.isEmpty
                ? "I hit this turn's step limit before finishing, and nothing was run. Ask "
                    + "again with a narrower request."
                : "I hit this turn's step limit before finishing. What ran so far is listed "
                    + "below — ask me to continue if that is not enough.",
            executedCommands
        )
    }

    // MARK: - OpenAI / Ollama Tool Loop

    func sendOpenAIWithTools(
        message: String,
        contextPrompt: String,
        apiKey: String?,
        history: [ChatMessage],
        commandExecutor: @escaping (String, String, Bool) async -> (Bool, String, Int32),
        customTools: [[String: Any]] = [],
        maxIterations: Int,
        endpoint: String,
        model: String,
        timeout: TimeInterval = 60,
        extraHeaders: [String: String] = [:],
        transport: any OpenAIToolTransport,
        imageAttachments: [URL] = [],
        userContext: UserContext = .none,
        chatScope: GeneralChatScope? = nil,
        grantedApps: [String: String] = [:],
        simulateAllTools: Bool,
        onStream: (@Sendable (AIProviderStreamEvent) -> Void)? = nil,
        onStatus: ((String) -> Void)? = nil
    ) async throws -> (finalResponse: String, executedCommands: [ExecutedCommand]) {
        let adapter = OpenAILoopAdapter(
            apiKey: apiKey, endpoint: endpoint, timeout: timeout,
            extraHeaders: extraHeaders, transport: transport, modelName: model)
        return try await runToolLoop(
            adapter: adapter, message: message, contextPrompt: contextPrompt,
            history: history, commandExecutor: commandExecutor, customTools: customTools,
            maxIterations: maxIterations, imageAttachments: imageAttachments,
            userContext: userContext, chatScope: chatScope, grantedApps: grantedApps,
            simulateAllTools: simulateAllTools, onStream: onStream, onStatus: onStatus)
    }

    // MARK: - Anthropic Tool Loop

    func sendAnthropicWithTools(
        message: String,
        contextPrompt: String,
        apiKey: String,
        history: [ChatMessage],
        commandExecutor: @escaping (String, String, Bool) async -> (Bool, String, Int32),
        customTools: [[String: Any]] = [],
        maxIterations: Int,
        model: String,
        imageAttachments: [URL] = [],
        userContext: UserContext = .none,
        chatScope: GeneralChatScope? = nil,
        grantedApps: [String: String] = [:],
        simulateAllTools: Bool,
        onStream: (@Sendable (AIProviderStreamEvent) -> Void)? = nil,
        onStatus: ((String) -> Void)? = nil
    ) async throws -> (finalResponse: String, executedCommands: [ExecutedCommand]) {
        let adapter = AnthropicLoopAdapter(apiKey: apiKey, modelName: model)
        return try await runToolLoop(
            adapter: adapter, message: message, contextPrompt: contextPrompt,
            history: history, commandExecutor: commandExecutor, customTools: customTools,
            maxIterations: maxIterations, imageAttachments: imageAttachments,
            userContext: userContext, chatScope: chatScope, grantedApps: grantedApps,
            simulateAllTools: simulateAllTools, onStream: onStream, onStatus: onStatus)
    }

    // MARK: - Gemini Tool Loop

    func sendGeminiWithTools(
        message: String,
        contextPrompt: String,
        apiKey: String,
        history: [ChatMessage],
        commandExecutor: @escaping (String, String, Bool) async -> (Bool, String, Int32),
        customTools: [[String: Any]] = [],
        maxIterations: Int,
        imageAttachments: [URL] = [],
        userContext: UserContext = .none,
        chatScope: GeneralChatScope? = nil,
        grantedApps: [String: String] = [:],
        simulateAllTools: Bool,
        onStream: (@Sendable (AIProviderStreamEvent) -> Void)? = nil,
        onStatus: ((String) -> Void)? = nil
    ) async throws -> (finalResponse: String, executedCommands: [ExecutedCommand]) {
        let adapter = GeminiLoopAdapter(apiKey: apiKey)
        return try await runToolLoop(
            adapter: adapter, message: message, contextPrompt: contextPrompt,
            history: history, commandExecutor: commandExecutor, customTools: customTools,
            maxIterations: maxIterations, imageAttachments: imageAttachments,
            userContext: userContext, chatScope: chatScope, grantedApps: grantedApps,
            simulateAllTools: simulateAllTools, onStream: onStream, onStatus: onStatus)
    }
}

// MARK: - OpenAI Adapter

struct OpenAILoopAdapter: ToolLoopAdapter {
    let apiKey: String?
    let endpoint: String
    let timeout: TimeInterval
    let extraHeaders: [String: String]
    let transport: any OpenAIToolTransport
    let modelName: String

    var toolFormat: AgentToolRegistry.SchemaFormat { .openAI }
    var provider: AIProvider { transport.ledgerProvider }
    var model: String { modelName }

    func buildMessages(
        contextPrompt: String, message: String, history: [ChatMessage],
        imageAttachments: [URL], recorder: TurnRecorder?
    ) -> [[String: Any]] {
        // Subscription bridges serve a coding agent with its own sandboxed tools; without this
        // it "checks" the wrong filesystem instead of using the tools we hand it below.
        var messages: [[String: Any]] = [
            ["role": "system", "content": contextPrompt + OpenAICompatibleProviderAdapter.hostRuntimeNote]
        ]
        let fittedHistory = ChatHistoryBudget.fit(history, provider: .openAI)
        recorder?.notePromptSections([
            "system": contextPrompt.count,
            "history": fittedHistory.reduce(0) { $0 + $1.content.count },
            "message": message.count,
        ])
        for msg in fittedHistory {
            messages.append(["role": msg.role.rawValue, "content": msg.content])
        }
        // Vision: when the user attached/captured images, send the first user turn as a
        // text+image content array so the model actually sees them (not just OCR text).
        let imageBlocks = AIAttachmentPreparer.imageBlocks(forURLs: imageAttachments)
        if imageBlocks.isEmpty {
            messages.append(["role": "user", "content": message])
        } else {
            var content: [[String: Any]] = [["type": "text", "text": message]]
            for block in imageBlocks {
                content.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(block.mediaType);base64,\(block.data)"],
                ])
            }
            messages.append(["role": "user", "content": content])
        }
        return messages
    }

    func buildBody(messages: [[String: Any]], tools: [[String: Any]], contextPrompt: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": modelName,
            "messages": messages,
            "tools": tools,
            "tool_choice": "auto",
            // No temperature: newer Claude models served through OpenAI-compatible
            // proxies reject sampling parameters with HTTP 400.
            "max_tokens": ToolLoopBudget.maxTokens(for: transport.ledgerProvider),
        ]
        if apiKey == nil { body.removeValue(forKey: "max_tokens") }
        return body
    }

    func sendRound(body: [String: Any]) async throws -> ToolRoundOutput {
        // A buffered round must say so explicitly: Ollama defaults `stream` to true and
        // would otherwise answer a buffered request with an event stream the transport
        // cannot decode.
        var body = body
        body["stream"] = false
        let decoded = try await transport.send(
            endpoint: endpoint, apiKey: apiKey, body: body,
            timeout: timeout, extraHeaders: extraHeaders)
        return try normalize(decoded, streamed: false)
    }

    func streamRound(
        body: [String: Any], onEvent: @escaping @Sendable (AIProviderStreamEvent) -> Void
    ) async throws -> ToolRoundOutput {
        let decoded = try await AIProviderStreaming.openAI(
            endpoint: endpoint, apiKey: apiKey, body: body,
            timeout: timeout, extraHeaders: extraHeaders, onEvent: onEvent)
        return try normalize(decoded, streamed: true)
    }

    private func normalize(_ decoded: OpenAIToolResponse, streamed: Bool) throws -> ToolRoundOutput {
        guard let choice = decoded.choices.first else {
            throw AIServiceError.emptyResponse("No response")
        }
        // What the round cost, from the provider's own counters. Streamed rounds report
        // nothing, and that is filed as nothing rather than as zero.
        let usage = decoded.usage.map { u in
            ToolRoundUsage(
                inputTokens: u.prompt_tokens,
                cacheReadTokens: u.prompt_tokens_details?.cached_tokens,
                cacheWriteTokens: nil,
                outputTokens: u.completion_tokens)
        }
        let finishReasons = choice.finish_reason.map { [$0] }
        if let toolCalls = choice.message.tool_calls, !toolCalls.isEmpty {
            var assistantMsg: [String: Any] = ["role": "assistant"]
            if let content = choice.message.content { assistantMsg["content"] = content }
            assistantMsg["tool_calls"] = toolCalls.map { tc -> [String: Any] in
                ["id": tc.id, "type": tc.type,
                 "function": ["name": tc.function.name, "arguments": tc.function.arguments]]
            }
            // Malformed calls (unparseable JSON args) are dropped from dispatch;
            // the assistant turn dict still carries the raw call so the loop history is intact.
            let calls: [NormalizedToolCall] = toolCalls.compactMap { tc in
                guard let argsData = tc.function.arguments.data(using: .utf8),
                      let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                else { return nil }
                return NormalizedToolCall(id: tc.id, name: tc.function.name, arguments: args)
            }
            return ToolRoundOutput(
                outcome: .toolCalls(calls), usage: usage,
                finishReasons: finishReasons, streamed: streamed, assistantTurnDict: assistantMsg)
        }
        return ToolRoundOutput(
            outcome: .finalText(choice.message.content ?? ""), usage: usage,
            finishReasons: finishReasons, streamed: streamed, assistantTurnDict: [:])
    }

    func appendToolResults(
        to messages: [[String: Any]], calls: [NormalizedToolCall],
        results: [(success: Bool, output: String, exitCode: Int32?)]
    ) -> [[String: Any]] {
        // assistantTurnDict already appended by runToolLoop before this call.
        var messages = messages
        for (call, result) in zip(calls, results) {
            messages.append([
                "role": "tool", "tool_call_id": call.id,
                "content": AgentToolTranscript.payload(
                    success: result.success, output: result.output, exitCode: result.exitCode),
            ])
        }
        return messages
    }

    func recordUsage(round: ToolRoundOutput) {
        guard let usage = round.usage else { return }
        // prompt_tokens already includes the cached part, which is what the record means by input.
        // A streamed round reports no usage and is recorded without counts.
        AITokenLedger.shared.record(
            provider: transport.ledgerProvider, model: modelName,
            inputTokens: usage.inputTokens ?? 0,
            outputTokens: usage.outputTokens ?? 0)
    }

    func noteRound(_ recorder: TurnRecorder?, round: ToolRoundOutput, roundStarted: ContinuousClock.Instant) {
        recorder?.noteRound(TurnTrace.Round(
            inputTokens: round.usage?.inputTokens,
            cacheReadTokens: round.usage?.cacheReadTokens,
            outputTokens: round.usage?.outputTokens,
            toolCalls: round.outcome.toolCallNames,
            finishReasons: round.finishReasons,
            streamed: round.streamed,
            duration: TurnRecorder.seconds(since: roundStarted)))
    }
}

// MARK: - Anthropic Adapter

struct AnthropicLoopAdapter: ToolLoopAdapter {
    let apiKey: String
    let modelName: String

    var toolFormat: AgentToolRegistry.SchemaFormat { .anthropic }
    var provider: AIProvider { .anthropic }
    var model: String { modelName }

    func buildMessages(
        contextPrompt: String, message: String, history: [ChatMessage],
        imageAttachments: [URL], recorder: TurnRecorder?
    ) -> [[String: Any]] {
        // System prompt goes in the body, not messages, for Anthropic.
        var messages: [[String: Any]] = []
        let fittedHistory = ChatHistoryBudget.fit(history, provider: .anthropic)
        recorder?.notePromptSections([
            "system": contextPrompt.count,
            "history": fittedHistory.reduce(0) { $0 + $1.content.count },
            "message": message.count,
        ])
        for msg in fittedHistory {
            messages.append(["role": msg.role.rawValue, "content": msg.content])
        }
        // Vision: attach captured/uploaded images as image blocks before the text so the
        // model sees them, not just their OCR text.
        let imageBlocks = AIAttachmentPreparer.imageBlocks(forURLs: imageAttachments)
        if imageBlocks.isEmpty {
            messages.append(["role": "user", "content": message])
        } else {
            var content: [[String: Any]] = imageBlocks.map { block in
                ["type": "image",
                 "source": ["type": "base64", "media_type": block.mediaType, "data": block.data]]
            }
            content.append(["type": "text", "text": message])
            messages.append(["role": "user", "content": content])
        }
        return messages
    }

    func buildBody(messages: [[String: Any]], tools: [[String: Any]], contextPrompt: String) -> [String: Any] {
        // Prompt caching. Every iteration re-sends the same system prompt and tool set
        // plus the whole conversation so far; the breakpoint on the last system block
        // covers tools + system (they render first), and the one on the newest message
        // extends the cached span over the history. Markers go on this copy only —
        // writing them back into `messages` would add one per iteration and blow the
        // 4-breakpoint limit.
        var body: [String: Any] = [
            "model": modelName,
            "system": AnthropicPromptCache.systemBlocks(contextPrompt) ?? contextPrompt,
            "messages": AnthropicPromptCache.markingLastBlock(messages),
            "tools": tools,
            // 1024 was far too small for an agentic loop: on models that think by default
            // it caps thinking AND the reply together, so answers were cut mid-sentence
            // and a truncated tool_use block ended the loop with no error.
            "max_tokens": ToolLoopBudget.maxTokens(for: .anthropic),
        ]
        if AnthropicModelCatalog.supportsAdaptiveThinking(modelName) {
            // Claude decides how much to think per step. `effort` is the depth/spend dial;
            // high is the right floor for tool-driven work.
            body["thinking"] = ["type": "adaptive"]
            body["output_config"] = ["effort": "high"]
        }
        return body
    }

    func sendRound(body: [String: Any]) async throws -> ToolRoundOutput {
        let decoded = try await AnthropicToolProviderAdapter().send(apiKey: apiKey, body: body)
        AnthropicPromptCache.logUsage(decoded.usage, label: "toolLoop")
        return normalize(decoded, streamed: false)
    }

    func streamRound(
        body: [String: Any], onEvent: @escaping @Sendable (AIProviderStreamEvent) -> Void
    ) async throws -> ToolRoundOutput {
        let decoded = try await AIProviderStreaming.anthropic(
            apiKey: apiKey, body: body, onEvent: onEvent)
        AnthropicPromptCache.logUsage(decoded.usage, label: "toolLoop")
        return normalize(decoded, streamed: true)
    }

    private func normalize(_ decoded: AnthropicToolResponse, streamed: Bool) -> ToolRoundOutput {
        let usage = decoded.usage.map { u in
            ToolRoundUsage(
                inputTokens: u.input_tokens,
                cacheReadTokens: u.cache_read_input_tokens,
                cacheWriteTokens: u.cache_creation_input_tokens,
                outputTokens: u.output_tokens)
        }
        let textBlocks = decoded.content.filter { $0.type == "text" }
        let toolUseBlocks = decoded.content.filter { $0.type == "tool_use" }

        // Echo the full assistant content array back. Thinking blocks must round-trip
        // unchanged (signature included) or the next turn is rejected — dropping them is
        // what makes adaptive thinking break a tool loop instead of improving it.
        let assistantBlocks: [[String: Any]] = decoded.content.map { block in
            var d: [String: Any] = ["type": block.type]
            if let t = block.text { d["text"] = t }
            if let id = block.id { d["id"] = id }
            if let n = block.name { d["name"] = n }
            if let input = block.input { d["input"] = input.mapValues { $0.value } }
            if let thinking = block.thinking { d["thinking"] = thinking }
            if let signature = block.signature { d["signature"] = signature }
            if let data = block.data { d["data"] = data }
            return d
        }
        let assistantTurnDict: [String: Any] = ["role": "assistant", "content": assistantBlocks]
        let finishReasons = decoded.stop_reason.map { [$0] }

        // Safety classifiers decline with HTTP 200 + stop_reason "refusal" — content is
        // empty or partial, so reading it as an answer produces a blank or half reply.
        if decoded.stop_reason == "refusal" {
            let partial = textBlocks.compactMap { $0.text }.joined(separator: "\n")
            return ToolRoundOutput(
                outcome: .refusal(partial), usage: usage,
                finishReasons: finishReasons, streamed: streamed, assistantTurnDict: assistantTurnDict)
        }

        if toolUseBlocks.isEmpty {
            let text = textBlocks.compactMap { $0.text }.joined(separator: "\n")
            return ToolRoundOutput(
                outcome: .finalText(text), usage: usage,
                finishReasons: finishReasons, streamed: streamed, assistantTurnDict: assistantTurnDict)
        }

        // Malformed tool blocks (missing id/name/input) are dropped from dispatch.
        let calls: [NormalizedToolCall] = toolUseBlocks.compactMap { block in
            guard let id = block.id, let name = block.name, let inputDict = block.input else {
                return nil
            }
            return NormalizedToolCall(id: id, name: name, arguments: inputDict.mapValues { $0.value })
        }
        return ToolRoundOutput(
            outcome: .toolCalls(calls), usage: usage,
            finishReasons: finishReasons, streamed: streamed, assistantTurnDict: assistantTurnDict)
    }

    func appendToolResults(
        to messages: [[String: Any]], calls: [NormalizedToolCall],
        results: [(success: Bool, output: String, exitCode: Int32?)]
    ) -> [[String: Any]] {
        // assistantTurnDict (with thinking blocks) already appended by runToolLoop.
        var messages = messages
        var resultBlocks: [[String: Any]] = []
        for (call, result) in zip(calls, results) {
            resultBlocks.append([
                "type": "tool_result",
                "tool_use_id": call.id,
                "is_error": !result.success,
                "content": AgentToolTranscript.payload(
                    success: result.success, output: result.output, exitCode: result.exitCode),
            ])
        }
        messages.append(["role": "user", "content": resultBlocks])
        return messages
    }

    func recordUsage(round: ToolRoundOutput) {
        guard let usage = round.usage else { return }
        AITokenLedger.shared.record(
            provider: .anthropic, model: modelName,
            inputTokens: usage.inputTokens ?? 0,
            cachedInputTokens: (usage.cacheReadTokens ?? 0) + (usage.cacheWriteTokens ?? 0),
            outputTokens: usage.outputTokens ?? 0)
    }

    func noteRound(_ recorder: TurnRecorder?, round: ToolRoundOutput, roundStarted: ContinuousClock.Instant) {
        recorder?.noteRound(.anthropicShaped(
            uncachedInput: round.usage?.inputTokens,
            cacheRead: round.usage?.cacheReadTokens,
            cacheWrite: round.usage?.cacheWriteTokens,
            output: round.usage?.outputTokens,
            toolCalls: round.outcome.toolCallNames,
            finishReason: round.finishReasons?.first,
            streamed: round.streamed,
            duration: TurnRecorder.seconds(since: roundStarted)))
    }
}

// MARK: - Gemini Adapter

struct GeminiLoopAdapter: ToolLoopAdapter {
    let apiKey: String

    var toolFormat: AgentToolRegistry.SchemaFormat { .gemini }
    var provider: AIProvider { .googleGemini }
    var model: String { AppSettings.shared.selectedGeminiModel }

    func buildMessages(
        contextPrompt: String, message: String, history: [ChatMessage],
        imageAttachments: [URL], recorder: TurnRecorder?
    ) -> [[String: Any]] {
        var contents: [[String: Any]] = [
            ["role": "user",  "parts": [["text": contextPrompt]]],
            ["role": "model", "parts": [["text": "Understood. I'll help with the context provided."]]]
        ]
        let fittedHistory = ChatHistoryBudget.fit(history, provider: .googleGemini)
        recorder?.notePromptSections([
            "system": contextPrompt.count,
            "history": fittedHistory.reduce(0) { $0 + $1.content.count },
            "message": message.count,
        ])
        for msg in fittedHistory {
            let role = msg.role == .assistant ? "model" : "user"
            contents.append(["role": role, "parts": [["text": msg.content]]])
        }
        // Vision: add inline image parts alongside the text so Gemini sees the captures.
        let imageBlocks = AIAttachmentPreparer.imageBlocks(forURLs: imageAttachments)
        var userParts: [[String: Any]] = [["text": message]]
        for block in imageBlocks {
            userParts.append(["inline_data": ["mime_type": block.mediaType, "data": block.data]])
        }
        contents.append(["role": "user", "parts": userParts])
        return contents
    }

    func buildBody(messages: [[String: Any]], tools: [[String: Any]], contextPrompt: String) -> [String: Any] {
        [
            "contents": messages,
            "tools": [["function_declarations": tools]],
            "generationConfig": [
                "temperature": 0.7,
                "maxOutputTokens": ToolLoopBudget.maxTokens(for: .googleGemini),
            ],
        ]
    }

    func sendRound(body: [String: Any]) async throws -> ToolRoundOutput {
        let geminiModel = AppSettings.shared.selectedGeminiModel
        let decoded = try await GeminiToolProviderAdapter().send(
            apiKey: apiKey, body: body, model: geminiModel)
        return try normalize(decoded, streamed: false)
    }

    func streamRound(
        body: [String: Any], onEvent: @escaping @Sendable (AIProviderStreamEvent) -> Void
    ) async throws -> ToolRoundOutput {
        let geminiModel = AppSettings.shared.selectedGeminiModel
        let decoded = try await AIProviderStreaming.gemini(
            apiKey: apiKey, body: body, model: geminiModel, onEvent: onEvent)
        return try normalize(decoded, streamed: true)
    }

    private func normalize(_ decoded: GeminiToolResponse, streamed: Bool) throws -> ToolRoundOutput {
        guard let candidate = decoded.candidates.first else {
            throw AIServiceError.emptyResponse("No response")
        }
        let usage = decoded.usageMetadata.map { u in
            ToolRoundUsage(
                inputTokens: u.promptTokenCount,
                cacheReadTokens: u.cachedContentTokenCount,
                cacheWriteTokens: nil,
                outputTokens: u.candidatesTokenCount)
        }
        let finishReasons = candidate.finishReason.map { [$0] }
        let textParts = candidate.content.parts.filter { $0.text != nil }
        let functionParts = candidate.content.parts.filter { $0.functionCall != nil }

        // Echo model turn (text + function call parts)
        let modelParts: [[String: Any]] = candidate.content.parts.map { part in
            if let fc = part.functionCall {
                return ["functionCall": ["name": fc.name, "args": fc.args.mapValues { $0.value }]]
            }
            return ["text": part.text ?? ""]
        }
        let assistantTurnDict: [String: Any] = ["role": "model", "parts": modelParts]

        if functionParts.isEmpty {
            let text = textParts.compactMap { $0.text }.joined(separator: "\n")
            return ToolRoundOutput(
                outcome: .finalText(text), usage: usage,
                finishReasons: finishReasons, streamed: streamed, assistantTurnDict: assistantTurnDict)
        }

        let calls: [NormalizedToolCall] = functionParts.compactMap { part in
            guard let fc = part.functionCall else { return nil }
            return NormalizedToolCall(id: fc.name, name: fc.name, arguments: fc.args.mapValues { $0.value })
        }
        return ToolRoundOutput(
            outcome: .toolCalls(calls), usage: usage,
            finishReasons: finishReasons, streamed: streamed, assistantTurnDict: assistantTurnDict)
    }

    func appendToolResults(
        to messages: [[String: Any]], calls: [NormalizedToolCall],
        results: [(success: Bool, output: String, exitCode: Int32?)]
    ) -> [[String: Any]] {
        // assistantTurnDict (model turn) already appended by runToolLoop.
        var messages = messages
        var functionResultParts: [[String: Any]] = []
        for (call, result) in zip(calls, results) {
            functionResultParts.append([
                "functionResponse": [
                    "name": call.name,
                    "response": [
                        "content": AgentToolTranscript.payload(
                            success: result.success, output: result.output, exitCode: result.exitCode)
                    ],
                ]
            ])
        }
        messages.append(["role": "function", "parts": functionResultParts])
        return messages
    }

    func recordUsage(round: ToolRoundOutput) {
        guard let usage = round.usage else { return }
        // promptTokenCount already includes the cached part.
        AITokenLedger.shared.record(
            provider: .googleGemini,
            model: AppSettings.shared.selectedGeminiModel,
            inputTokens: usage.inputTokens ?? 0,
            cachedInputTokens: usage.cacheReadTokens ?? 0,
            outputTokens: usage.outputTokens ?? 0)
    }

    func noteRound(_ recorder: TurnRecorder?, round: ToolRoundOutput, roundStarted: ContinuousClock.Instant) {
        recorder?.noteRound(TurnTrace.Round(
            inputTokens: round.usage?.inputTokens,
            cacheReadTokens: round.usage?.cacheReadTokens,
            outputTokens: round.usage?.outputTokens,
            toolCalls: round.outcome.toolCallNames,
            finishReasons: round.finishReasons,
            streamed: round.streamed,
            duration: TurnRecorder.seconds(since: roundStarted)))
    }
}
