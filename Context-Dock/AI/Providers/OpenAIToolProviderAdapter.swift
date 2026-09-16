import Foundation

protocol OpenAIToolTransport {
    /// Which provider a round through this transport should be filed under in the token
    /// ledger. The loop is shared by five providers, so the response alone cannot say.
    var ledgerProvider: AIProvider { get }

    func send(
        endpoint: String,
        apiKey: String?,
        body: [String: Any],
        timeout: TimeInterval,
        extraHeaders: [String: String]
    ) async throws -> OpenAIToolResponse
}

struct OpenAIToolProviderAdapter: OpenAIToolTransport {
    var ledgerProvider: AIProvider { .openAI }

    func send(
        endpoint: String,
        apiKey: String?,
        body: [String: Any],
        timeout: TimeInterval,
        extraHeaders: [String: String]
    ) async throws -> OpenAIToolResponse {
        try await AIProviderToolHTTP.openAI(
            endpoint: endpoint,
            apiKey: apiKey,
            body: body,
            timeout: timeout,
            extraHeaders: extraHeaders
        )
    }
}
