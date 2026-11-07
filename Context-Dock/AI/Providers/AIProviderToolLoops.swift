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

        // A repeated call is only pointless *within* one turn. Asking the same question in
        // the next message is the user asking again, and deserves a fresh reading.
        //
        // The turn also learns what the USER typed (their messages, never the model's) so the
        // outbound gate knows which hosts they pointed it at, and whether untrusted content is
        // already in the prompt.
        let turn = await AgentToolRegistry.shared.beginTurn(
            userText: TurnUserText.resolve(history: history, message: message),
            promptBlocks: [contextPrompt, message],
            startsPrivate: OutboundGate.isPrivateDataApp(
                bundleID: AgentToolRegistry.scopedBundleID(for: chatScope)),
            startsUntrusted: OutboundGate.isThirdPartyContentApp(
                bundleID: AgentToolRegistry.scopedBundleID(for: chatScope)))
        // However this loop leaves — answer, refusal, throw, or step limit — the turn's
        // record goes with it rather than sitting in the registry until age evicts it.
        defer { AgentToolRegistry.shared.endTurn(turn) }
        // This turn's record, if the turn log is on. Read once: it is a task-local.
        let recorder = TurnRecorder.current
        recorder?.notePass()

        var executedCommands: [ExecutedCommand] = []
        /// Set when a streaming attempt fails on an endpoint that turned out not to speak
        /// SSE. Custom endpoints and subscription bridges vary; one buffered round is the
        /// right answer to that, and asking again every round is not.
        var streamingUnavailable = false

        // Subscription bridges serve a coding agent with its own sandboxed tools; without this
        // it "checks" the wrong filesystem instead of using the tools we hand it below.
        var messages: [[String: Any]] = [
            ["role": "system", "content": contextPrompt + OpenAICompatibleProviderAdapter.hostRuntimeNote]
        ]
        // Budgeted by size, not by a fixed count of turns, and told when something was
        // left out — see ChatHistoryBudget.
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
        let openAIImageBlocks = AIAttachmentPreparer.imageBlocks(forURLs: imageAttachments)
        if openAIImageBlocks.isEmpty {
            messages.append(["role": "user", "content": message])
        } else {
            var content: [[String: Any]] = [["type": "text", "text": message]]
            for block in openAIImageBlocks {
                content.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(block.mediaType);base64,\(block.data)"],
                ])
            }
            messages.append(["role": "user", "content": content])
        }

        let allTools = await AgentToolRegistry.shared.schemas(format: .openAI) + customTools
        onStatus?("Found \(allTools.count) available tools; choosing the best route…")
        recorder?.noteModel(model)
        recorder?.noteToolsSent(TurnRecorder.toolNames(in: allTools))
        recorder?.notePromptSections(TurnRecorder.toolSchemaSection(allTools))
        // Whether the endpoint even engages with tools is otherwise unknowable from the
        // outside: a proxy that drops the `tools` field answers in one round with prose, and
        // looks exactly like a model that chose not to call anything. One line per turn says
        // which it was.
        var roundsUsed = 0
        var toolCallsSeen = 0
        var progressTracker = ToolLoopProgressTracker()
        defer {
            AgentTurnDiagnostics.record(
                model: model, toolsOffered: allTools.count,
                rounds: roundsUsed, toolCalls: toolCallsSeen)
        }

        for _ in 0..<maxIterations {
            // Stop is a decision the user already made. Without this check the loop kept
            // going after Stop was pressed — running more tools, spending more tokens, and
            // in a scoped chat still driving the app — because cancellation was only read
            // once the whole loop had returned.
            if Task.isCancelled {
                recorder?.noteStopReason("cancelled")
                return ("Stopped.", executedCommands)
            }
            roundsUsed += 1
            var body: [String: Any] = [
                "model": model,
                "messages": messages,
                "tools": allTools,
                "tool_choice": "auto",
                // No temperature: newer Claude models served through OpenAI-compatible
                // proxies reject sampling parameters with HTTP 400.
                "max_tokens": ToolLoopBudget.maxTokens(for: transport.ledgerProvider)
            ]
            if apiKey == nil { body.removeValue(forKey: "max_tokens") }
            let mayStream = onStream != nil && !streamingUnavailable
            // A buffered round must say so explicitly: Ollama defaults `stream` to true and
            // would otherwise answer a buffered request with an event stream the transport
            // cannot decode.
            if !mayStream { body["stream"] = false }
            let roundStarted = ContinuousClock.now
            var streamed: OpenAIToolResponse?
            if mayStream, let onStream {
                do {
                    streamed = try await AIProviderStreaming.openAI(
                        endpoint: endpoint,
                        apiKey: apiKey,
                        body: body,
                        timeout: timeout,
                        extraHeaders: extraHeaders,
                        onEvent: onStream)
                } catch let error as AIServiceError {
                    // An authentication failure is the endpoint's real answer and is not
                    // improved by asking again without streaming.
                    if case .authenticationFailed = error { throw error }
                    streamingUnavailable = true
                    recorder?.noteFallback("stream_to_buffered")
                }
            }
            let decoded: OpenAIToolResponse
            if let streamed {
                decoded = streamed
            } else {
                decoded = try await transport.send(
                    endpoint: endpoint,
                    apiKey: apiKey,
                    body: body,
                    timeout: timeout,
                    extraHeaders: extraHeaders
                )
            }
            // What the round cost, from the provider's own counters. Streamed rounds report
            // nothing, and that is filed as nothing rather than as zero.
            if let usage = decoded.usage {
                AITokenLedger.shared.record(
                    provider: transport.ledgerProvider, model: model,
                    inputTokens: usage.prompt_tokens ?? 0,
                    outputTokens: usage.completion_tokens ?? 0)
            }
            // prompt_tokens already includes the cached part, which is what the record means
            // by input. A streamed round reports no usage and is recorded without counts.
            recorder?.noteRound(
                TurnTrace.Round(
                    inputTokens: decoded.usage?.prompt_tokens,
                    cacheReadTokens: decoded.usage?.prompt_tokens_details?.cached_tokens,
                    outputTokens: decoded.usage?.completion_tokens,
                    toolCalls: decoded.choices.first?.message.tool_calls?.map(\.function.name) ?? [],
                    finishReasons: decoded.choices.first?.finish_reason.map { [$0] },
                    streamed: streamed != nil,
                    duration: TurnRecorder.seconds(since: roundStarted)))
            guard let choice = decoded.choices.first else { throw AIServiceError.emptyResponse("No response") }

            toolCallsSeen += choice.message.tool_calls?.count ?? 0
            if let toolCalls = choice.message.tool_calls, !toolCalls.isEmpty {
                var assistantMsg: [String: Any] = ["role": "assistant"]
                if let content = choice.message.content { assistantMsg["content"] = content }
                assistantMsg["tool_calls"] = toolCalls.map { tc -> [String: Any] in
                    ["id": tc.id, "type": tc.type, "function": ["name": tc.function.name, "arguments": tc.function.arguments]]
                }
                messages.append(assistantMsg)

                var roundResults: [(success: Bool, output: String)] = []
                for tc in toolCalls {
                    guard let argsData = tc.function.arguments.data(using: .utf8),
                          let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                    else {
                        roundResults.append((success: false, output: "Malformed arguments"))
                        continue
                    }

                    var (success, output): (Bool, String) = (false, "")
                    var exitCode: Int32?
                    // Say what is about to run, before it runs. Everything needed for this
                    // was already here and none of it was published — see AgentToolNarration.
                    if let route = AgentToolNarration.route(tool: tc.function.name, arguments: args) { onStatus?(route) }
                    onStatus?(AgentToolNarration.start(tool: tc.function.name, arguments: args))
                    if simulateAllTools {
                        success = true
                        output = "Simulated \(tc.function.name) tool call"
                        executedCommands.append(ExecutedCommand(command: tc.function.name, output: output, success: true))
                    } else if let result = await AgentToolRegistry.shared.dispatch(
                        name: tc.function.name,
                        arguments: args,
                        context: AgentToolContext(
                            commandExecutor: commandExecutor, userContext: userContext,
                            userRequest: message,
                            attachments: imageAttachments, chatScope: chatScope,
                            grantedApps: grantedApps, turn: turn, onStatus: onStatus)
                    ) {
                        success = result.success
                        output = result.output
                        exitCode = result.exitCode
                        executedCommands.append(ExecutedCommand(
                            command: result.displayCommand,
                            output: output,
                            success: success,
                            isVerification: tc.function.name == "verify_outcome"))
                        onStatus?(
                            AgentToolNarration.finish(
                                displayCommand: result.displayCommand, success: success,
                                output: output))
                    } else {
                        // Not a registered tool — an L2 extension, resolved by name at run time.
                        (success, output) = await dispatchCustomTool(name: tc.function.name, arguments: args, turn: turn, chatScope: chatScope)
                        executedCommands.append(ExecutedCommand(command: "\(tc.function.name)(\(args))", output: output, success: success))
                    }
                    roundResults.append((success: success, output: output))
                    messages.append([
                        "role": "tool", "tool_call_id": tc.id,
                        "content": AgentToolTranscript.payload(
                            success: success, output: output, exitCode: exitCode),
                    ])
                }
                if progressTracker.recordRound(results: roundResults) {
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
            } else {
                onStatus?("Preparing the final response…")
                return (choice.message.content ?? "(no response)", executedCommands)
            }
        }
        // The loop ran out of steps with the model still calling tools. "Commands completed"
        // read as success and hid that: the user was told the work was done when the turn had
        // simply been cut off mid-way. Say which it is, and let the receipts speak for what
        // actually ran.
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

        // A repeated call is only pointless *within* one turn. Asking the same question in
        // the next message is the user asking again, and deserves a fresh reading.
        //
        // The turn also learns what the USER typed (their messages, never the model's) so the
        // outbound gate knows which hosts they pointed it at, and whether untrusted content is
        // already in the prompt.
        let turn = await AgentToolRegistry.shared.beginTurn(
            userText: TurnUserText.resolve(history: history, message: message),
            promptBlocks: [contextPrompt, message],
            startsPrivate: OutboundGate.isPrivateDataApp(
                bundleID: AgentToolRegistry.scopedBundleID(for: chatScope)),
            startsUntrusted: OutboundGate.isThirdPartyContentApp(
                bundleID: AgentToolRegistry.scopedBundleID(for: chatScope)))
        // However this loop leaves — answer, refusal, throw, or step limit — the turn's
        // record goes with it rather than sitting in the registry until age evicts it.
        defer { AgentToolRegistry.shared.endTurn(turn) }
        // This turn's record, if the turn log is on. Read once: it is a task-local.
        let recorder = TurnRecorder.current
        recorder?.notePass()

        var executedCommands: [ExecutedCommand] = []
        var streamingUnavailable = false

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
        let anthropicImageBlocks = AIAttachmentPreparer.imageBlocks(forURLs: imageAttachments)
        if anthropicImageBlocks.isEmpty {
            messages.append(["role": "user", "content": message])
        } else {
            var content: [[String: Any]] = anthropicImageBlocks.map { block in
                [
                    "type": "image",
                    "source": [
                        "type": "base64", "media_type": block.mediaType, "data": block.data,
                    ],
                ]
            }
            content.append(["type": "text", "text": message])
            messages.append(["role": "user", "content": content])
        }

        let usesAdaptiveThinking = AnthropicModelCatalog.supportsAdaptiveThinking(model)

        let registryTools = await AgentToolRegistry.shared.schemas(format: .anthropic)
        onStatus?("Found \(registryTools.count + customTools.count) available tools; choosing the best route…")
        recorder?.noteModel(model)
        recorder?.noteToolsSent(TurnRecorder.toolNames(in: registryTools + customTools))
        recorder?.notePromptSections(TurnRecorder.toolSchemaSection(registryTools + customTools))
        var roundsUsed = 0
        var toolCallsSeen = 0
        var progressTracker = ToolLoopProgressTracker()
        defer {
            AgentTurnDiagnostics.record(
                model: model, toolsOffered: registryTools.count + customTools.count,
                rounds: roundsUsed, toolCalls: toolCallsSeen)
        }

        for _ in 0..<maxIterations {
            // Stop is a decision the user already made. Without this check the loop kept
            // going after Stop was pressed — running more tools, spending more tokens, and
            // in a scoped chat still driving the app — because cancellation was only read
            // once the whole loop had returned.
            if Task.isCancelled {
                recorder?.noteStopReason("cancelled")
                return ("Stopped.", executedCommands)
            }
            // Prompt caching. Every iteration re-sends the same system prompt and tool set
            // plus the whole conversation so far; the breakpoint on the last system block
            // covers tools + system (they render first), and the one on the newest message
            // extends the cached span over the history. Markers go on this copy only —
            // writing them back into `messages` would add one per iteration and blow the
            // 4-breakpoint limit.
            var body: [String: Any] = [
                "model": model,
                "system": AnthropicPromptCache.systemBlocks(contextPrompt) ?? contextPrompt,
                "messages": AnthropicPromptCache.markingLastBlock(messages),
                "tools": registryTools + customTools,
                // 1024 was far too small for an agentic loop: on models that think by default
                // it caps thinking AND the reply together, so answers were cut mid-sentence
                // and a truncated tool_use block ended the loop with no error.
                "max_tokens": ToolLoopBudget.maxTokens(for: .anthropic),
            ]
            if usesAdaptiveThinking {
                // Claude decides how much to think per step. `effort` is the depth/spend dial;
                // high is the right floor for tool-driven work.
                body["thinking"] = ["type": "adaptive"]
                body["output_config"] = ["effort": "high"]
            }
            let roundStarted = ContinuousClock.now
            var streamed: AnthropicToolResponse?
            if onStream != nil, !streamingUnavailable, let onStream {
                do {
                    streamed = try await AIProviderStreaming.anthropic(
                        apiKey: apiKey, body: body, onEvent: onStream)
                } catch let error as AIServiceError {
                    if case .authenticationFailed = error { throw error }
                    streamingUnavailable = true
                    recorder?.noteFallback("stream_to_buffered")
                }
            }
            let decoded: AnthropicToolResponse
            if let streamed {
                decoded = streamed
            } else {
                decoded = try await AnthropicToolProviderAdapter().send(
                    apiKey: apiKey, body: body)
            }
            AnthropicPromptCache.logUsage(decoded.usage, label: "toolLoop")
            if let usage = decoded.usage {
                AITokenLedger.shared.record(
                    provider: .anthropic, model: model,
                    inputTokens: usage.input_tokens ?? 0,
                    cachedInputTokens: (usage.cache_read_input_tokens ?? 0)
                        + (usage.cache_creation_input_tokens ?? 0),
                    outputTokens: usage.output_tokens ?? 0)
            }
            roundsUsed += 1
            let textBlocks   = decoded.content.filter { $0.type == "text" }
            let toolUseBlocks = decoded.content.filter { $0.type == "tool_use" }
            toolCallsSeen += toolUseBlocks.count
            recorder?.noteRound(
                .anthropicShaped(
                    uncachedInput: decoded.usage?.input_tokens,
                    cacheRead: decoded.usage?.cache_read_input_tokens,
                    cacheWrite: decoded.usage?.cache_creation_input_tokens,
                    output: decoded.usage?.output_tokens,
                    toolCalls: toolUseBlocks.compactMap(\.name),
                    finishReason: decoded.stop_reason,
                    streamed: streamed != nil,
                    duration: TurnRecorder.seconds(since: roundStarted)))

            // Safety classifiers decline with HTTP 200 + stop_reason "refusal" — content is
            // empty or partial, so reading it as an answer produces a blank or half reply.
            if decoded.stop_reason == "refusal" {
                recorder?.noteStopReason("refusal")
                let partial = textBlocks.compactMap { $0.text }.joined(separator: "\n")
                return (
                    partial.isEmpty
                        ? "The provider declined this request."
                        : "The provider declined this request partway through:\n\n\(partial)",
                    executedCommands
                )
            }

            if toolUseBlocks.isEmpty {
                let text = textBlocks.compactMap { $0.text }.joined(separator: "\n")
                onStatus?("Preparing the final response…")
                return (text.isEmpty ? "(no response)" : text, executedCommands)
            }

            // Echo the full assistant content array back. Thinking blocks must round-trip
            // unchanged (signature included) or the next turn is rejected — dropping them is
            // what makes adaptive thinking break a tool loop instead of improving it.
            let assistantBlocks: [[String: Any]] = decoded.content.map { block in
                var d: [String: Any] = ["type": block.type]
                if let t = block.text  { d["text"] = t }
                if let id = block.id   { d["id"] = id }
                if let n = block.name  { d["name"] = n }
                if let input = block.input { d["input"] = input.mapValues { $0.value } }
                if let thinking = block.thinking { d["thinking"] = thinking }
                if let signature = block.signature { d["signature"] = signature }
                if let data = block.data { d["data"] = data }
                return d
            }
            messages.append(["role": "assistant", "content": assistantBlocks])

            var roundResults: [(success: Bool, output: String)] = []
            var resultBlocks: [[String: Any]] = []
            for block in toolUseBlocks {
                guard let toolId = block.id,
                      let toolName = block.name,
                      let inputDict = block.input
                else {
                    roundResults.append((success: false, output: "Malformed tool block"))
                    continue
                }

                let args = inputDict.mapValues { $0.value }
                var (success, output): (Bool, String) = (false, "")
                    var exitCode: Int32?

                if let route = AgentToolNarration.route(tool: toolName, arguments: args) { onStatus?(route) }
                    onStatus?(AgentToolNarration.start(tool: toolName, arguments: args))
                if simulateAllTools {
                    success = true
                    output = "Simulated \(toolName) tool call"
                    executedCommands.append(ExecutedCommand(command: toolName, output: output, success: true))
                } else if let result = await AgentToolRegistry.shared.dispatch(
                    name: toolName,
                    arguments: args,
                        context: AgentToolContext(
                            commandExecutor: commandExecutor, userContext: userContext,
                            userRequest: message,
                            attachments: imageAttachments, chatScope: chatScope,
                            grantedApps: grantedApps, turn: turn, onStatus: onStatus)
                ) {
                    success = result.success
                    output = result.output
                    exitCode = result.exitCode
                    executedCommands.append(ExecutedCommand(
                        command: result.displayCommand,
                        output: output,
                        success: success,
                        isVerification: toolName == "verify_outcome"))
                    onStatus?(
                        AgentToolNarration.finish(
                            displayCommand: result.displayCommand, success: success,
                            output: output))
                } else {
                    // Not a registered tool — an L2 extension, resolved by name at run time.
                    (success, output) = await dispatchCustomTool(name: toolName, arguments: args, turn: turn, chatScope: chatScope)
                    executedCommands.append(ExecutedCommand(command: "\(toolName)(\(args))", output: output, success: success))
                }

                roundResults.append((success: success, output: output))
                resultBlocks.append([
                    "type": "tool_result",
                    "tool_use_id": toolId,
                    "is_error": !success,
                    "content": AgentToolTranscript.payload(
                        success: success, output: output, exitCode: exitCode),
                ])
            }
            messages.append(["role": "user", "content": resultBlocks])
            if progressTracker.recordRound(results: roundResults) {
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
        // The loop ran out of steps with the model still calling tools. "Commands completed"
        // read as success and hid that: the user was told the work was done when the turn had
        // simply been cut off mid-way. Say which it is, and let the receipts speak for what
        // actually ran.
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

        // A repeated call is only pointless *within* one turn. Asking the same question in
        // the next message is the user asking again, and deserves a fresh reading.
        //
        // The turn also learns what the USER typed (their messages, never the model's) so the
        // outbound gate knows which hosts they pointed it at, and whether untrusted content is
        // already in the prompt.
        let turn = await AgentToolRegistry.shared.beginTurn(
            userText: TurnUserText.resolve(history: history, message: message),
            promptBlocks: [contextPrompt, message],
            startsPrivate: OutboundGate.isPrivateDataApp(
                bundleID: AgentToolRegistry.scopedBundleID(for: chatScope)),
            startsUntrusted: OutboundGate.isThirdPartyContentApp(
                bundleID: AgentToolRegistry.scopedBundleID(for: chatScope)))
        // However this loop leaves — answer, refusal, throw, or step limit — the turn's
        // record goes with it rather than sitting in the registry until age evicts it.
        defer { AgentToolRegistry.shared.endTurn(turn) }
        // This turn's record, if the turn log is on. Read once: it is a task-local.
        let recorder = TurnRecorder.current
        recorder?.notePass()

        var executedCommands: [ExecutedCommand] = []
        var streamingUnavailable = false

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
        let geminiImageBlocks = AIAttachmentPreparer.imageBlocks(forURLs: imageAttachments)
        var userParts: [[String: Any]] = [["text": message]]
        for block in geminiImageBlocks {
            userParts.append(["inline_data": ["mime_type": block.mediaType, "data": block.data]])
        }
        contents.append(["role": "user", "parts": userParts])

        let registryTools = await AgentToolRegistry.shared.schemas(format: .gemini)
        onStatus?("Found \(registryTools.count + customTools.count) available tools; choosing the best route…")
        recorder?.noteModel(AppSettings.shared.selectedGeminiModel)
        recorder?.noteToolsSent(TurnRecorder.toolNames(in: registryTools + customTools))
        recorder?.notePromptSections(TurnRecorder.toolSchemaSection(registryTools + customTools))
        var progressTracker = ToolLoopProgressTracker()

        for _ in 0..<maxIterations {
            // Stop is a decision the user already made. Without this check the loop kept
            // going after Stop was pressed — running more tools, spending more tokens, and
            // in a scoped chat still driving the app — because cancellation was only read
            // once the whole loop had returned.
            if Task.isCancelled {
                recorder?.noteStopReason("cancelled")
                return ("Stopped.", executedCommands)
            }
            let body: [String: Any] = [
                "contents": contents,
                "tools": [["function_declarations": registryTools]]
                    + customTools.map { ["function_declarations": [$0]] },
                "generationConfig": [
                    "temperature": 0.7, "maxOutputTokens": ToolLoopBudget.maxTokens(for: .googleGemini),
                ],
            ]
            let geminiModel = AppSettings.shared.selectedGeminiModel
            let roundStarted = ContinuousClock.now
            var streamed: GeminiToolResponse?
            if onStream != nil, !streamingUnavailable, let onStream {
                do {
                    streamed = try await AIProviderStreaming.gemini(
                        apiKey: apiKey, body: body, model: geminiModel, onEvent: onStream)
                } catch let error as AIServiceError {
                    if case .authenticationFailed = error { throw error }
                    streamingUnavailable = true
                    recorder?.noteFallback("stream_to_buffered")
                }
            }
            let decoded: GeminiToolResponse
            if let streamed {
                decoded = streamed
            } else {
                decoded = try await GeminiToolProviderAdapter().send(
                    apiKey: apiKey, body: body, model: geminiModel)
            }
            if let usage = decoded.usageMetadata {
                AITokenLedger.shared.record(
                    provider: .googleGemini,
                    model: AppSettings.shared.selectedGeminiModel,
                    inputTokens: usage.promptTokenCount ?? 0,
                    cachedInputTokens: usage.cachedContentTokenCount ?? 0,
                    outputTokens: usage.candidatesTokenCount ?? 0)
            }
            // promptTokenCount already includes the cached part.
            recorder?.noteRound(
                TurnTrace.Round(
                    inputTokens: decoded.usageMetadata?.promptTokenCount,
                    cacheReadTokens: decoded.usageMetadata?.cachedContentTokenCount,
                    outputTokens: decoded.usageMetadata?.candidatesTokenCount,
                    toolCalls: decoded.candidates.first?.content.parts
                        .compactMap { $0.functionCall?.name } ?? [],
                    finishReasons: decoded.candidates.first?.finishReason.map { [$0] },
                    streamed: streamed != nil,
                    duration: TurnRecorder.seconds(since: roundStarted)))
            guard let candidate = decoded.candidates.first else { throw AIServiceError.emptyResponse("No response") }

            let textParts     = candidate.content.parts.filter { $0.text != nil }
            let functionParts = candidate.content.parts.filter { $0.functionCall != nil }

            if functionParts.isEmpty {
                let text = textParts.compactMap { $0.text }.joined(separator: "\n")
                onStatus?("Preparing the final response…")
                return (text.isEmpty ? "(no response)" : text, executedCommands)
            }

            // Echo model turn
            let modelParts: [[String: Any]] = candidate.content.parts.map { part in
                if let fc = part.functionCall {
                    return ["functionCall": ["name": fc.name, "args": fc.args.mapValues { $0.value }]]
                }
                return ["text": part.text ?? ""]
            }
            contents.append(["role": "model", "parts": modelParts])

            var roundResults: [(success: Bool, output: String)] = []
            var functionResultParts: [[String: Any]] = []
            for part in functionParts {
                guard let fc = part.functionCall else { continue }
                let args = fc.args.mapValues { $0.value }

                var (success, output): (Bool, String) = (false, "")
                    var exitCode: Int32?
                if let route = AgentToolNarration.route(tool: fc.name, arguments: args) { onStatus?(route) }
                    onStatus?(AgentToolNarration.start(tool: fc.name, arguments: args))
                if simulateAllTools {
                    success = true
                    output = "Simulated \(fc.name) tool call"
                    executedCommands.append(ExecutedCommand(command: fc.name, output: output, success: true))
                } else if let result = await AgentToolRegistry.shared.dispatch(
                    name: fc.name,
                    arguments: args,
                        context: AgentToolContext(
                            commandExecutor: commandExecutor, userContext: userContext,
                            userRequest: message,
                            attachments: imageAttachments, chatScope: chatScope,
                            grantedApps: grantedApps, turn: turn, onStatus: onStatus)
                ) {
                    success = result.success
                    output = result.output
                    exitCode = result.exitCode
                    executedCommands.append(ExecutedCommand(
                        command: result.displayCommand,
                        output: output,
                        success: success,
                        isVerification: fc.name == "verify_outcome"))
                    onStatus?(
                        AgentToolNarration.finish(
                            displayCommand: result.displayCommand, success: success,
                            output: output))
                } else {
                    // Not a registered tool — an L2 extension, resolved by name at run time.
                    (success, output) = await dispatchCustomTool(name: fc.name, arguments: args, turn: turn, chatScope: chatScope)
                    executedCommands.append(ExecutedCommand(command: "\(fc.name)(\(args))", output: output, success: success))
                }

                roundResults.append((success: success, output: output))
                functionResultParts.append([
                    "functionResponse": [
                        "name": fc.name,
                        "response": [
                            "content": AgentToolTranscript.payload(
                                success: success, output: output, exitCode: exitCode)
                        ],
                    ]
                ])
            }
            contents.append(["role": "function", "parts": functionResultParts])
            if progressTracker.recordRound(results: roundResults) {
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
        // The loop ran out of steps with the model still calling tools. "Commands completed"
        // read as success and hid that: the user was told the work was done when the turn had
        // simply been cut off mid-way. Say which it is, and let the receipts speak for what
        // actually ran.
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
}
