import Foundation

enum FirstPartyModelDiscovery {
    static func openAI(apiKey: String) async throws -> [String] {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let models = try await fetch(request: request)
        return models.filter { id in
            let value = id.lowercased()
            return value.hasPrefix("gpt-") || value.hasPrefix("chatgpt-")
                || value.range(of: #"^o\d"#, options: .regularExpression) != nil
        }
    }

    static func anthropic(apiKey: String) async throws -> [String] {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return try await fetch(request: request)
    }

    /// Gemini lists models on a different shape: names are path-qualified
    /// ("models/gemini-2.5-pro") and the list includes embedding and vision-only models that
    /// cannot answer a chat turn at all, so it is filtered by the method we actually call.
    static func gemini(apiKey: String) async throws -> [String] {
        var request = URLRequest(
            url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await AIProviderService.directSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIServiceError.networkError("Invalid model discovery response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? ""
            throw AIServiceError.networkError("Model discovery HTTP \(http.statusCode): \(detail)")
        }
        let decoded = try JSONDecoder().decode(GeminiModelList.self, from: data)
        return decoded.models
            .filter { ($0.supportedGenerationMethods ?? []).contains("generateContent") }
            .map { $0.name.replacingOccurrences(of: "models/", with: "") }
            .filter { !$0.isEmpty }
            .sorted()
    }

    private struct GeminiModelList: Decodable {
        let models: [Model]
        struct Model: Decodable {
            let name: String
            let supportedGenerationMethods: [String]?
        }
    }

    private static func fetch(request: URLRequest) async throws -> [String] {
        let (data, response) = try await AIProviderService.directSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIServiceError.networkError("Invalid model discovery response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? ""
            throw AIServiceError.networkError("Model discovery HTTP \(http.statusCode): \(detail)")
        }
        let decoded = try JSONDecoder().decode(ModelList.self, from: data)
        return Array(Set(decoded.data.map(\.id).filter { !$0.isEmpty })).sorted()
    }

    private struct ModelList: Decodable {
        let data: [Model]
        struct Model: Decodable { let id: String }
    }
}
