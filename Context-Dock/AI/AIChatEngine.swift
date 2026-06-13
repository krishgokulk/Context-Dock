import Combine
import Foundation

@MainActor
final class AIChatEngine: ObservableObject {
    static let shared = AIChatEngine()

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isLoading = false

    private let router: AIProviderRouter

    init(router: AIProviderRouter? = nil) {
        self.router = router ?? .shared
    }

    func send(_ message: String, context: UserContext) async throws -> String {
        let userMessage = ChatMessage(role: .user, content: message)
        messages.append(userMessage)
        isLoading = true
        defer { isLoading = false }

        let response = try await router.send(
            AIRequest(text: message, context: context, history: messages, source: .aiChat)
        )
        messages.append(ChatMessage(role: .assistant, content: response))
        return response
    }
}
