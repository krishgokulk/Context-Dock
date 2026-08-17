import Foundation

struct OpenAICompatibleToolProviderAdapter: OpenAIToolTransport {
    var ledgerProvider: AIProvider { .openAICompatible }

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
