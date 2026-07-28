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
    struct Choice: Codable { let message: Message; let finish_reason: String? }
    struct Message: Codable { let role: String; let content: String?; let tool_calls: [ToolCall]? }
    struct ToolCall: Codable { let id: String; let type: String; let function: FunctionCall }
    struct FunctionCall: Codable { let name: String; let arguments: String }
}

struct AnthropicToolResponse: Codable {
    let content: [ContentBlock]
    let stop_reason: String?
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
        body: [String: Any]
    ) async throws -> GeminiToolResponse {
        try await request(
            endpoint: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent",
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

        let (data, response) = try await AIProviderService.directSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIServiceError.networkError("Invalid provider response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw AIServiceError.authenticationFailed(authenticationError)
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? ""
            throw AIServiceError.networkError("Provider HTTP \(http.statusCode): \(detail)")
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
