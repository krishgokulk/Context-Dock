import Foundation

struct GeminiToolProviderAdapter {
    func send(apiKey: String, body: [String: Any]) async throws -> GeminiToolResponse {
        try await AIProviderToolHTTP.gemini(apiKey: apiKey, body: body)
    }
}
