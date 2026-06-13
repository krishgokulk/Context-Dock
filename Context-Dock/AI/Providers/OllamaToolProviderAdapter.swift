import Foundation

struct OllamaToolProviderAdapter: OpenAIToolTransport {
    func send(
        endpoint: String,
        apiKey: String?,
        body: [String: Any],
        timeout: TimeInterval,
        extraHeaders: [String: String]
    ) async throws -> OpenAIToolResponse {
        try await AIProviderToolHTTP.openAI(
            endpoint: endpoint,
            apiKey: nil,
            body: body,
            timeout: max(timeout, 120),
            extraHeaders: extraHeaders
        )
    }
}
