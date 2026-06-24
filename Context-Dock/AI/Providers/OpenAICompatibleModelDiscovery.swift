import Foundation

enum OpenAICompatibleModelDiscovery {
    static func discover(endpoint: String, apiKey: String) async throws -> [String] {
        guard let url = modelsURL(from: endpoint) else {
            throw AIServiceError.networkError("Invalid OpenAI-compatible endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

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

    private static func modelsURL(from endpoint: String) -> URL? {
        var value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for suffix in ["/chat/completions", "/completions"] where value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
        }
        return URL(string: "\(value)/models")
    }

    private struct ModelList: Decodable {
        let data: [Model]
        struct Model: Decodable { let id: String }
    }
}
