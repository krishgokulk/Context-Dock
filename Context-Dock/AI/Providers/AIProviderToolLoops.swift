import Foundation

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
        simulateAllTools: Bool
    ) async throws -> (finalResponse: String, executedCommands: [ExecutedCommand]) {

        var executedCommands: [ExecutedCommand] = []

        // Subscription bridges serve a coding agent with its own sandboxed tools; without this
        // it "checks" the wrong filesystem instead of using the tools we hand it below.
        var messages: [[String: Any]] = [
            ["role": "system", "content": contextPrompt + OpenAICompatibleProviderAdapter.hostRuntimeNote]
        ]
        for msg in history.suffix(10).filter({ $0.role != .system }) {
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

        for _ in 0..<maxIterations {
            var body: [String: Any] = [
                "model": model,
                "messages": messages,
                "tools": allTools,
                "tool_choice": "auto",
                // No temperature: newer Claude models served through OpenAI-compatible
                // proxies reject sampling parameters with HTTP 400.
                "max_tokens": 1000
            ]
            if apiKey == nil { body["stream"] = false; body.removeValue(forKey: "max_tokens") }
            let decoded = try await transport.send(
                endpoint: endpoint,
                apiKey: apiKey,
                body: body,
                timeout: timeout,
                extraHeaders: extraHeaders
            )
            guard let choice = decoded.choices.first else { throw AIServiceError.emptyResponse("No response") }

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
                        context: AgentToolContext(commandExecutor: commandExecutor)
                    ) {
                        success = result.success
                        output = result.output
                        exitCode = result.exitCode
                        executedCommands.append(ExecutedCommand(
                            command: result.displayCommand, output: output, success: success))
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
            } else {
                return (choice.message.content ?? "(no response)", executedCommands)
            }
        }
        return ("Commands completed.", executedCommands)
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
        simulateAllTools: Bool
    ) async throws -> (finalResponse: String, executedCommands: [ExecutedCommand]) {

        var executedCommands: [ExecutedCommand] = []

        var messages: [[String: Any]] = []
        for msg in history.suffix(10).filter({ $0.role != .system }) {
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

        for _ in 0..<maxIterations {
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
            let decoded = try await AnthropicToolProviderAdapter().send(apiKey: apiKey, body: body)
            AnthropicPromptCache.logUsage(decoded.usage, label: "toolLoop")
            let textBlocks   = decoded.content.filter { $0.type == "text" }
            let toolUseBlocks = decoded.content.filter { $0.type == "tool_use" }

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
                    context: AgentToolContext(commandExecutor: commandExecutor)
                ) {
                    success = result.success
                    output = result.output
                    exitCode = result.exitCode
                    executedCommands.append(ExecutedCommand(
                        command: result.displayCommand, output: output, success: success))
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
        }
        return ("Commands completed.", executedCommands)
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
        simulateAllTools: Bool
    ) async throws -> (finalResponse: String, executedCommands: [ExecutedCommand]) {

        var executedCommands: [ExecutedCommand] = []

        var contents: [[String: Any]] = [
            ["role": "user",  "parts": [["text": contextPrompt]]],
            ["role": "model", "parts": [["text": "Understood. I'll help with the context provided."]]]
        ]
        for msg in history.suffix(10).filter({ $0.role != .system }) {
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

        for _ in 0..<maxIterations {
            let body: [String: Any] = [
                "contents": contents,
                "tools": [["function_declarations": registryTools]]
                    + customTools.map { ["function_declarations": [$0]] },
                "generationConfig": ["temperature": 0.7, "maxOutputTokens": 1000]
            ]
            let decoded = try await GeminiToolProviderAdapter().send(apiKey: apiKey, body: body)
            guard let candidate = decoded.candidates.first else { throw AIServiceError.emptyResponse("No response") }

            let textParts     = candidate.content.parts.filter { $0.text != nil }
            let functionParts = candidate.content.parts.filter { $0.functionCall != nil }

            if functionParts.isEmpty {
                let text = textParts.compactMap { $0.text }.joined(separator: "\n")
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
                    context: AgentToolContext(commandExecutor: commandExecutor)
                ) {
                    success = result.success
                    output = result.output
                    exitCode = result.exitCode
                    executedCommands.append(ExecutedCommand(
                        command: result.displayCommand, output: output, success: success))
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
        }
        return ("Commands completed.", executedCommands)
    }
}
