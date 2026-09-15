import Foundation

/// How much room a tool loop leaves the model to answer in.
///
/// This was 1000 for every OpenAI-shaped provider — which is Kimi, Ollama, any custom
/// endpoint, and both subscription bridges. Those bridges serve a coding agent that narrates
/// before it acts, so a thousand tokens ran out mid-sentence; and a `tool_use` block cut in
/// half is not a malformed call the loop can report, it is a turn that ends having done
/// nothing while claiming to be finished. Anthropic's own loop was raised to 16000 for
/// exactly this reason and the others were left behind.
private enum ToolLoopBudget {
    /// Providers whose models think before they write spend part of this budget before the
    /// first visible token, so it has to cover both.
    static let maxTokens = 8192
}

extension AIProviderService {
    // MARK: - Tool Definitions

    /// Dispatch a custom L2 extension tool call. Returns (success, output).
    private func dispatchCustomTool(name: String, arguments: [String: Any]) async -> (Bool, String) {
        let (success, output) = await L2ExtensionManager.shared.execute(toolName: name, arguments: arguments)
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
        let turn = await AgentToolRegistry.shared.beginTurn()
        // However this loop leaves — answer, refusal, throw, or step limit — the turn's
        // record goes with it rather than sitting in the registry until age evicts it.
        defer { AgentToolRegistry.shared.endTurn(turn) }

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
        for msg in ChatHistoryBudget.fit(history, provider: .openAI) {
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
        // Whether the endpoint even engages with tools is otherwise unknowable from the
        // outside: a proxy that drops the `tools` field answers in one round with prose, and
        // looks exactly like a model that chose not to call anything. One line per turn says
        // which it was.
        var roundsUsed = 0
        var toolCallsSeen = 0
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
                "max_tokens": ToolLoopBudget.maxTokens
            ]
            if apiKey == nil { body.removeValue(forKey: "max_tokens") }
            let mayStream = onStream != nil && !streamingUnavailable
            // A buffered round must say so explicitly: Ollama defaults `stream` to true and
            // would otherwise answer a buffered request with an event stream the transport
            // cannot decode.
            if !mayStream { body["stream"] = false }
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
            guard let choice = decoded.choices.first else { throw AIServiceError.emptyResponse("No response") }

            toolCallsSeen += choice.message.tool_calls?.count ?? 0
            if let toolCalls = choice.message.tool_calls, !toolCalls.isEmpty {
                var assistantMsg: [String: Any] = ["role": "assistant"]
                if let content = choice.message.content { assistantMsg["content"] = content }
                assistantMsg["tool_calls"] = toolCalls.map { tc -> [String: Any] in
                    ["id": tc.id, "type": tc.type, "function": ["name": tc.function.name, "arguments": tc.function.arguments]]
                }
                messages.append(assistantMsg)

                for tc in toolCalls {
                    guard let argsData = tc.function.arguments.data(using: .utf8),
                          let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                    else { continue }

                    var (success, output): (Bool, String) = (false, "")
                    var exitCode: Int32?
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
                    } else {
                        // Not a registered tool — an L2 extension, resolved by name at run time.
                        (success, output) = await dispatchCustomTool(name: tc.function.name, arguments: args)
                        executedCommands.append(ExecutedCommand(command: "\(tc.function.name)(\(args))", output: output, success: success))
                    }
                    messages.append([
                        "role": "tool", "tool_call_id": tc.id,
                        "content": AgentToolTranscript.payload(
                            success: success, output: output, exitCode: exitCode),
                    ])
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
        let turn = await AgentToolRegistry.shared.beginTurn()
        // However this loop leaves — answer, refusal, throw, or step limit — the turn's
        // record goes with it rather than sitting in the registry until age evicts it.
        defer { AgentToolRegistry.shared.endTurn(turn) }

        var executedCommands: [ExecutedCommand] = []
        var streamingUnavailable = false

        var messages: [[String: Any]] = []
        for msg in ChatHistoryBudget.fit(history, provider: .anthropic) {
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
        var roundsUsed = 0
        var toolCallsSeen = 0
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
                "max_tokens": 16000,
            ]
            if usesAdaptiveThinking {
                // Claude decides how much to think per step. `effort` is the depth/spend dial;
                // high is the right floor for tool-driven work.
                body["thinking"] = ["type": "adaptive"]
                body["output_config"] = ["effort": "high"]
            }
            var streamed: AnthropicToolResponse?
            if onStream != nil, !streamingUnavailable, let onStream {
                do {
                    streamed = try await AIProviderStreaming.anthropic(
                        apiKey: apiKey, body: body, onEvent: onStream)
                } catch let error as AIServiceError {
                    if case .authenticationFailed = error { throw error }
                    streamingUnavailable = true
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

            // Safety classifiers decline with HTTP 200 + stop_reason "refusal" — content is
            // empty or partial, so reading it as an answer produces a blank or half reply.
            if decoded.stop_reason == "refusal" {
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

            var resultBlocks: [[String: Any]] = []
            for block in toolUseBlocks {
                guard let toolId = block.id,
                      let toolName = block.name,
                      let inputDict = block.input
                else { continue }

                let args = inputDict.mapValues { $0.value }
                var (success, output): (Bool, String) = (false, "")
                    var exitCode: Int32?

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
                } else {
                    // Not a registered tool — an L2 extension, resolved by name at run time.
                    (success, output) = await dispatchCustomTool(name: toolName, arguments: args)
                    executedCommands.append(ExecutedCommand(command: "\(toolName)(\(args))", output: output, success: success))
                }

                resultBlocks.append([
                    "type": "tool_result",
                    "tool_use_id": toolId,
                    "is_error": !success,
                    "content": AgentToolTranscript.payload(
                        success: success, output: output, exitCode: exitCode),
                ])
            }
            messages.append(["role": "user", "content": resultBlocks])
            onStatus?("Understanding the returned tool data…")
        }
        // The loop ran out of steps with the model still calling tools. "Commands completed"
        // read as success and hid that: the user was told the work was done when the turn had
        // simply been cut off mid-way. Say which it is, and let the receipts speak for what
        // actually ran.
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
        let turn = await AgentToolRegistry.shared.beginTurn()
        // However this loop leaves — answer, refusal, throw, or step limit — the turn's
        // record goes with it rather than sitting in the registry until age evicts it.
        defer { AgentToolRegistry.shared.endTurn(turn) }

        var executedCommands: [ExecutedCommand] = []
        var streamingUnavailable = false

        var contents: [[String: Any]] = [
            ["role": "user",  "parts": [["text": contextPrompt]]],
            ["role": "model", "parts": [["text": "Understood. I'll help with the context provided."]]]
        ]
        for msg in ChatHistoryBudget.fit(history, provider: .googleGemini) {
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

        for _ in 0..<maxIterations {
            // Stop is a decision the user already made. Without this check the loop kept
            // going after Stop was pressed — running more tools, spending more tokens, and
            // in a scoped chat still driving the app — because cancellation was only read
            // once the whole loop had returned.
            if Task.isCancelled {
                return ("Stopped.", executedCommands)
            }
            let body: [String: Any] = [
                "contents": contents,
                "tools": [["function_declarations": registryTools]]
                    + customTools.map { ["function_declarations": [$0]] },
                "generationConfig": [
                    "temperature": 0.7, "maxOutputTokens": ToolLoopBudget.maxTokens,
                ],
            ]
            let geminiModel = AppSettings.shared.selectedGeminiModel
            var streamed: GeminiToolResponse?
            if onStream != nil, !streamingUnavailable, let onStream {
                do {
                    streamed = try await AIProviderStreaming.gemini(
                        apiKey: apiKey, body: body, model: geminiModel, onEvent: onStream)
                } catch let error as AIServiceError {
                    if case .authenticationFailed = error { throw error }
                    streamingUnavailable = true
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

            var functionResultParts: [[String: Any]] = []
            for part in functionParts {
                guard let fc = part.functionCall else { continue }
                let args = fc.args.mapValues { $0.value }

                var (success, output): (Bool, String) = (false, "")
                    var exitCode: Int32?
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
                } else {
                    // Not a registered tool — an L2 extension, resolved by name at run time.
                    (success, output) = await dispatchCustomTool(name: fc.name, arguments: args)
                    executedCommands.append(ExecutedCommand(command: "\(fc.name)(\(args))", output: output, success: success))
                }

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
            onStatus?("Understanding the returned tool data…")
        }
        // The loop ran out of steps with the model still calling tools. "Commands completed"
        // read as success and hid that: the user was told the work was done when the turn had
        // simply been cut off mid-way. Say which it is, and let the receipts speak for what
        // actually ran.
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
