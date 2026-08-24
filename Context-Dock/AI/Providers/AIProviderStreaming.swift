// AIProviderStreaming.swift
// Context-Dock
//
// Answers that arrive as they are written.
//
// Every cloud turn in DoraX was a block: the request went out, the tool loop ran, and
// nothing reached the screen until the final token had been generated. On a scoped chat that
// runs three tools and writes six paragraphs, that is thirty seconds of "Thinking…" — the
// user cannot tell a working turn from a hung one, and the app looked slower than the same
// model does in a browser. Apple Intelligence streamed from the start; the cloud providers
// were the ones left behind.
//
// This decodes the providers' server-sent events back into the exact response shapes the
// tool loops already handle, so the loops keep their logic and gain only a callback. Text
// deltas are handed out as they arrive; tool calls are accumulated and delivered whole,
// because a half-decoded set of arguments is not something you can run.

import Foundation

/// What a streaming round reports while it is still in flight.
enum AIProviderStreamEvent: Sendable {
    /// A fragment of the answer the user is reading.
    case text(String)
    /// The model has started calling a tool. Named so a surface can say what is happening
    /// instead of showing an idle spinner.
    case toolCallStarted(String)
}

enum AIProviderStreaming {

    /// Whether a provider's endpoint is one we know speaks SSE.
    ///
    /// Bridges and custom endpoints are unknown quantities — some proxies do not implement
    /// streaming at all — so the caller treats a stream failure as a reason to fall back
    /// rather than a reason to fail the turn.
    static func isKnownStreamingProvider(_ provider: AIProvider) -> Bool {
        switch provider {
        case .anthropic, .openAI, .kimi, .openAICompatible, .claudeBridge, .chatGPTBridge,
            .googleGemini, .ollama:
            return true
        case .onDevice, .shortcuts, .claudeCode:
            // On-device streams through FoundationModels' own API, not SSE. Shortcuts runs a
            // shortcut and returns its result; there is nothing to stream. Claude Code is a
            // process that prints one JSON object when it is done.
            return false
        }
    }

    // MARK: - Gemini

    /// Streams `:streamGenerateContent?alt=sse` and rebuilds a `GeminiToolResponse`.
    ///
    /// Gemini streams the same envelope in pieces rather than a delta format of its own: each
    /// event carries a whole candidate whose parts continue the previous one. Text parts are
    /// concatenated; a function call arrives complete in a single part, so it is taken as it
    /// stands rather than accumulated.
    static func gemini(
        apiKey: String,
        body: [String: Any],
        model: String,
        onEvent: @escaping @Sendable (AIProviderStreamEvent) -> Void
    ) async throws -> GeminiToolResponse {
        let endpoint =
            "https://generativelanguage.googleapis.com/v1beta/models/"
            + "\(GeminiModelCatalog.normalized(model)):streamGenerateContent?alt=sse"
        guard let url = URL(string: endpoint) else {
            throw AIServiceError.networkError("Invalid Gemini streaming endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var text = ""
        var functionParts: [GeminiToolResponse.Part] = []
        var finishReason: String?
        var usage: GeminiToolResponse.UsageMetadata?

        for try await line in try await eventLines(for: request, label: "Gemini") {
            guard let payload = jsonPayload(of: line) else { continue }
            if let raw = payload["usageMetadata"],
                let data = try? JSONSerialization.data(withJSONObject: raw)
            {
                usage = try? JSONDecoder().decode(
                    GeminiToolResponse.UsageMetadata.self, from: data)
            }
            guard let candidate = (payload["candidates"] as? [[String: Any]])?.first else {
                continue
            }
            finishReason = candidate["finishReason"] as? String ?? finishReason
            let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]]
            for part in parts ?? [] {
                if let fragment = part["text"] as? String, !fragment.isEmpty {
                    text += fragment
                    onEvent(.text(fragment))
                }
                if let call = part["functionCall"] as? [String: Any],
                    let name = call["name"] as? String
                {
                    let arguments = call["args"] as? [String: Any] ?? [:]
                    guard let data = try? JSONSerialization.data(withJSONObject: arguments),
                        let decoded = try? JSONDecoder().decode(
                            [String: AIProviderAnyCodable].self, from: data)
                    else { continue }
                    onEvent(.toolCallStarted(name))
                    functionParts.append(
                        GeminiToolResponse.Part(
                            text: nil,
                            functionCall: GeminiToolResponse.FunctionCall(
                                name: name, args: decoded)))
                }
            }
        }

        var parts = functionParts
        if !text.isEmpty {
            parts.insert(GeminiToolResponse.Part(text: text, functionCall: nil), at: 0)
        }
        guard !parts.isEmpty else {
            throw AIServiceError.emptyResponse("The provider streamed no content.")
        }
        return GeminiToolResponse(
            candidates: [
                GeminiToolResponse.Candidate(
                    content: GeminiToolResponse.Content(parts: parts, role: "model"),
                    finishReason: finishReason)
            ],
            usageMetadata: usage)
    }

    // MARK: - Anthropic

    /// Streams `/v1/messages` and rebuilds the same `AnthropicToolResponse` the buffered
    /// path returns. Thinking blocks are reassembled with their signatures intact — the
    /// loop echoes those back verbatim next round, and a dropped signature is rejected.
    static func anthropic(
        apiKey: String,
        body: [String: Any],
        onEvent: @escaping @Sendable (AIProviderStreamEvent) -> Void
    ) async throws -> AnthropicToolResponse {
        var streamingBody = body
        streamingBody["stream"] = true

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: streamingBody)

        /// One content block under construction. Anthropic sends a `content_block_start`
        /// with the block's shape, then deltas that append to exactly one of its fields.
        struct PartialBlock {
            var type: String
            var text = ""
            var id: String?
            var name: String?
            /// tool_use arguments arrive as JSON text in fragments, and are only parseable
            /// once the block closes.
            var partialJSON = ""
            var thinking = ""
            var signature: String?
            var data: String?
        }

        var blocks: [Int: PartialBlock] = [:]
        var stopReason: String?
        var usage: AnthropicUsage?

        for try await line in try await eventLines(for: request, label: "Anthropic") {
            guard let payload = jsonPayload(of: line) else { continue }
            let type = payload["type"] as? String ?? ""

            switch type {
            case "content_block_start":
                let index = payload["index"] as? Int ?? 0
                let block = payload["content_block"] as? [String: Any] ?? [:]
                var partial = PartialBlock(type: block["type"] as? String ?? "text")
                partial.id = block["id"] as? String
                partial.name = block["name"] as? String
                partial.text = block["text"] as? String ?? ""
                blocks[index] = partial
                if partial.type == "tool_use", let name = partial.name {
                    onEvent(.toolCallStarted(name))
                }

            case "content_block_delta":
                let index = payload["index"] as? Int ?? 0
                guard let delta = payload["delta"] as? [String: Any] else { continue }
                switch delta["type"] as? String {
                case "text_delta":
                    let fragment = delta["text"] as? String ?? ""
                    blocks[index, default: PartialBlock(type: "text")].text += fragment
                    if !fragment.isEmpty { onEvent(.text(fragment)) }
                case "input_json_delta":
                    blocks[index, default: PartialBlock(type: "tool_use")].partialJSON
                        += delta["partial_json"] as? String ?? ""
                case "thinking_delta":
                    // Not surfaced: the user asked a question, not for the model's notes.
                    // Kept because the block has to be echoed back intact.
                    blocks[index, default: PartialBlock(type: "thinking")].thinking
                        += delta["thinking"] as? String ?? ""
                case "signature_delta":
                    blocks[index, default: PartialBlock(type: "thinking")].signature =
                        (blocks[index]?.signature ?? "") + (delta["signature"] as? String ?? "")
                default:
                    break
                }

            case "message_delta":
                if let delta = payload["delta"] as? [String: Any] {
                    stopReason = delta["stop_reason"] as? String ?? stopReason
                }
                if let raw = payload["usage"],
                    let data = try? JSONSerialization.data(withJSONObject: raw)
                {
                    usage = try? JSONDecoder().decode(AnthropicUsage.self, from: data)
                }

            case "error":
                let detail = (payload["error"] as? [String: Any])?["message"] as? String
                    ?? "The provider ended the stream with an error."
                throw AIServiceError.networkError(detail)

            default:
                break
            }
        }

        let content: [AnthropicToolResponse.ContentBlock] = blocks
            .sorted { $0.key < $1.key }
            .map { _, partial in
                var input: [String: AIProviderAnyCodable]?
                if partial.type == "tool_use" {
                    // An empty argument object arrives as no delta at all, which is a valid
                    // call with no arguments rather than a broken one.
                    let json = partial.partialJSON.isEmpty ? "{}" : partial.partialJSON
                    input =
                        (try? JSONDecoder().decode(
                            [String: AIProviderAnyCodable].self,
                            from: Data(json.utf8))) ?? [:]
                }
                return AnthropicToolResponse.ContentBlock(
                    type: partial.type,
                    text: partial.type == "text" ? partial.text : nil,
                    id: partial.id,
                    name: partial.name,
                    input: input,
                    thinking: partial.thinking.isEmpty ? nil : partial.thinking,
                    signature: partial.signature,
                    data: partial.data)
            }

        guard !content.isEmpty else {
            throw AIServiceError.emptyResponse("The provider streamed no content.")
        }
        return AnthropicToolResponse(content: content, stop_reason: stopReason, usage: usage)
    }

    // MARK: - OpenAI-shaped

    /// Streams any `chat/completions` endpoint and rebuilds an `OpenAIToolResponse`.
    ///
    /// Tool-call fragments are keyed by the index the provider assigns, not by arrival
    /// order: a model calling two tools in one round interleaves their argument fragments,
    /// and concatenating them in the order they land produces two corrupt calls.
    static func openAI(
        endpoint: String,
        apiKey: String?,
        body: [String: Any],
        timeout: TimeInterval,
        extraHeaders: [String: String],
        onEvent: @escaping @Sendable (AIProviderStreamEvent) -> Void
    ) async throws -> OpenAIToolResponse {
        guard let url = URL(string: endpoint) else {
            throw AIServiceError.networkError("Invalid endpoint: \(endpoint)")
        }
        var streamingBody = body
        streamingBody["stream"] = true

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        extraHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: streamingBody)

        struct PartialToolCall {
            var id = ""
            var type = "function"
            var name = ""
            var arguments = ""
        }

        var text = ""
        var toolCalls: [Int: PartialToolCall] = [:]
        var announced = Set<Int>()
        var finishReason: String?

        for try await line in try await eventLines(for: request, label: "provider") {
            guard let payload = jsonPayload(of: line) else { continue }
            guard let choice = (payload["choices"] as? [[String: Any]])?.first else { continue }
            finishReason = choice["finish_reason"] as? String ?? finishReason
            guard let delta = choice["delta"] as? [String: Any] else { continue }

            if let fragment = delta["content"] as? String, !fragment.isEmpty {
                text += fragment
                onEvent(.text(fragment))
            }
            for raw in (delta["tool_calls"] as? [[String: Any]]) ?? [] {
                let index = raw["index"] as? Int ?? 0
                var call = toolCalls[index] ?? PartialToolCall()
                if let id = raw["id"] as? String, !id.isEmpty { call.id = id }
                if let type = raw["type"] as? String, !type.isEmpty { call.type = type }
                if let function = raw["function"] as? [String: Any] {
                    if let name = function["name"] as? String, !name.isEmpty {
                        call.name = name
                    }
                    call.arguments += function["arguments"] as? String ?? ""
                }
                toolCalls[index] = call
                if !call.name.isEmpty, announced.insert(index).inserted {
                    onEvent(.toolCallStarted(call.name))
                }
            }
        }

        let calls: [OpenAIToolResponse.ToolCall] = toolCalls
            .sorted { $0.key < $1.key }
            .compactMap { index, call in
                guard !call.name.isEmpty else { return nil }
                return OpenAIToolResponse.ToolCall(
                    // Some proxies omit the id on streamed calls; the loop only needs it to
                    // pair the result back, so a stable synthetic one does the job.
                    id: call.id.isEmpty ? "call_\(index)" : call.id,
                    type: call.type,
                    function: OpenAIToolResponse.FunctionCall(
                        name: call.name,
                        arguments: call.arguments.isEmpty ? "{}" : call.arguments))
            }

        guard !text.isEmpty || !calls.isEmpty else {
            throw AIServiceError.emptyResponse("The provider streamed no content.")
        }
        return OpenAIToolResponse(
            choices: [
                OpenAIToolResponse.Choice(
                    message: OpenAIToolResponse.Message(
                        role: "assistant",
                        content: text.isEmpty ? nil : text,
                        tool_calls: calls.isEmpty ? nil : calls),
                    finish_reason: finishReason)
            ])
    }

    // MARK: - Transport

    /// Opens the request and yields one `data:` payload per line, after checking the
    /// response is actually a stream. A proxy that answers a streaming request with a
    /// buffered JSON body would otherwise be read as an empty stream and reported as an
    /// empty answer; throwing here is what lets the caller retry without streaming.
    private static func eventLines(
        for request: URLRequest,
        label: String
    ) async throws -> AsyncThrowingStream<String, Error> {
        let (bytes, response) = try await AIProviderService.directSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIServiceError.networkError("Invalid \(label) response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw AIServiceError.authenticationFailed("\(label) authentication failed")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AIServiceError.networkError("Provider HTTP \(http.statusCode)")
        }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard contentType.contains("event-stream") else {
            throw AIServiceError.networkError("\(label) did not return a stream")
        }
        if let host = request.url?.host {
            await AIProviderUsageStore.shared.record(host: host, headers: http.allHeaderFields)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The JSON object carried by one `data:` line, or nil for the framing lines
    /// (`event:` names, keep-alives, blank separators, and the `[DONE]` sentinel).
    private static func jsonPayload(of line: String) -> [String: Any]? {
        guard line.hasPrefix("data:") else { return nil }
        let body = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty, body != "[DONE]" else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
    }
}
