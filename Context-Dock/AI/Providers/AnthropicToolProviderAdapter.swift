import Foundation

struct AnthropicToolProviderAdapter {
    func send(apiKey: String, body: [String: Any]) async throws -> AnthropicToolResponse {
        try await AIProviderToolHTTP.anthropic(apiKey: apiKey, body: body)
    }
}
