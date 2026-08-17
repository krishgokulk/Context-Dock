import Foundation

struct AIProviderAnyCodable: Codable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self.value = value; return }
        if let value = try? container.decode(Int.self) { self.value = value; return }
        if let value = try? container.decode(Double.self) { self.value = value; return }
        if let value = try? container.decode(String.self) { self.value = value; return }
        if let value = try? container.decode([String: AIProviderAnyCodable].self) { self.value = value; return }
        if let value = try? container.decode([AIProviderAnyCodable].self) { self.value = value; return }
        value = ()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let value as Bool: try container.encode(value)
        case let value as Int: try container.encode(value)
        case let value as Double: try container.encode(value)
        case let value as String: try container.encode(value)
        case let value as [String: AIProviderAnyCodable]: try container.encode(value)
        case let value as [AIProviderAnyCodable]: try container.encode(value)
        default: try container.encodeNil()
        }
    }
}

struct OpenAIToolResponse: Codable {
    let choices: [Choice]
    /// Token counts, when the endpoint reports them. Optional because a streamed round and
    /// several proxies omit the block entirely — a missing count is not an error, it is
    /// simply nothing to file.
    var usage: Usage?
    struct Usage: Codable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
    }
    struct Choice: Codable { let message: Message; let finish_reason: String? }
    struct Message: Codable { let role: String; let content: String?; let tool_calls: [ToolCall]? }
    struct ToolCall: Codable { let id: String; let type: String; let function: FunctionCall }
    struct FunctionCall: Codable { let name: String; let arguments: String }
}

struct AnthropicToolResponse: Codable {
    let content: [ContentBlock]
    let stop_reason: String?
    /// Carries the prompt-cache counters. Without decoding these there is no way to tell
    /// a cache hit from a full-price re-read — both return HTTP 200 with the same shape.
    let usage: AnthropicUsage?
    struct ContentBlock: Codable {
        let type: String
        let text: String?
        let id: String?
        let name: String?
        let input: [String: AIProviderAnyCodable]?
        // Thinking blocks must be echoed back VERBATIM on the next turn of a tool loop —
        // signature included. Anthropic rejects modified or dropped thinking blocks, so a
        // decoder that silently loses these fields makes adaptive thinking unusable.
        let thinking: String?
        let signature: String?
        let data: String?
    }
}

struct GeminiToolResponse: Codable {
    let candidates: [Candidate]
    var usageMetadata: UsageMetadata?
    struct UsageMetadata: Codable {
        let promptTokenCount: Int?
        let candidatesTokenCount: Int?
        let cachedContentTokenCount: Int?
    }
    struct Candidate: Codable { let content: Content; let finishReason: String? }
    struct Content: Codable { let parts: [Part]; let role: String? }
    struct Part: Codable { let text: String?; let functionCall: FunctionCall? }
    struct FunctionCall: Codable { let name: String; let args: [String: AIProviderAnyCodable] }
}

enum AIProviderToolHTTP {
    static func openAI(
        endpoint: String,
        apiKey: String?,
        body: [String: Any],
        timeout: TimeInterval,
        extraHeaders: [String: String]
    ) async throws -> OpenAIToolResponse {
        var headers = extraHeaders
        if let apiKey { headers["Authorization"] = "Bearer \(apiKey)" }
        return try await request(
            endpoint: endpoint,
            headers: headers,
            body: body,
            timeout: timeout,
            authenticationError: "Invalid API key"
        )
    }

    static func anthropic(
        apiKey: String,
        body: [String: Any]
    ) async throws -> AnthropicToolResponse {
        try await request(
            endpoint: "https://api.anthropic.com/v1/messages",
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
            ],
            body: body,
            timeout: 60,
            authenticationError: "Invalid Anthropic API key"
        )
    }

    static func gemini(
        apiKey: String,
        body: [String: Any],
        model: String = GeminiModelCatalog.defaultModelID
    ) async throws -> GeminiToolResponse {
        try await request(
            endpoint: GeminiModelCatalog.generateContentEndpoint(model: model),
            headers: ["x-goog-api-key": apiKey],
            body: body,
            timeout: 60,
            authenticationError: "Invalid Google Gemini API key"
        )
    }

    private static func request<Response: Decodable>(
        endpoint: String,
        headers: [String: String],
        body: [String: Any],
        timeout: TimeInterval,
        authenticationError: String
    ) async throws -> Response {
        guard let url = URL(string: endpoint) else {
            throw AIServiceError.networkError("Invalid endpoint: \(endpoint)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Retried rather than surfaced: a 429 mid-loop used to end a turn that had already
        // run tools, and the user saw "Provider HTTP 429" where an answer belonged. Nothing
        // has been executed at this point in the round — only the send is repeated.
        for attempt in 1...AIProviderRetry.maxAttempts {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await AIProviderService.directSession.data(for: request)
            } catch {
                guard let delay = AIProviderRetry.delay(forTransport: error, attempt: attempt),
                    await AIProviderRetry.wait(delay)
                else { throw error }
                continue
            }
            guard let http = response as? HTTPURLResponse else {
                throw AIServiceError.networkError("Invalid provider response")
            }
            if let host = url.host {
                await AIProviderUsageStore.shared.record(
                    host: host, headers: http.allHeaderFields)
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw AIServiceError.authenticationFailed(authenticationError)
            }
            guard (200..<300).contains(http.statusCode) else {
                let detail = String(data: data, encoding: .utf8)
                    .map { String($0.prefix(300)) } ?? ""
                if let delay = AIProviderRetry.delay(
                    forStatus: http.statusCode, headers: http.allHeaderFields, attempt: attempt),
                    await AIProviderRetry.wait(delay)
                {
                    continue
                }
                throw AIServiceError.networkError(
                    "Provider HTTP \(http.statusCode): \(detail)")
            }
            return try JSONDecoder().decode(Response.self, from: data)
        }
        throw AIServiceError.networkError(
            "The provider was busy and did not answer after \(AIProviderRetry.maxAttempts) tries.")
    }
}
