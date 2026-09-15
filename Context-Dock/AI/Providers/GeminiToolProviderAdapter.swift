import Foundation

struct GeminiToolProviderAdapter {
    func send(
        apiKey: String, body: [String: Any],
        model: String = GeminiModelCatalog.defaultModelID
    ) async throws -> GeminiToolResponse {
        try await AIProviderToolHTTP.gemini(apiKey: apiKey, body: body, model: model)
    }
}
