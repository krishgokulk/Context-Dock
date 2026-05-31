import Combine
import Foundation

@MainActor
final class AIChatEngine: ObservableObject {
    static let shared = AIChatEngine()

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isLoading = false

    private let router: AIProviderRouter

    init(router: AIProviderRouter = .shared) {
        self.router = router
    }

    func send(_ message: String, context: UserContext) async throws -> String {
        let userMessage = ChatMessage(role: .user, content: message)
        messages.append(userMessage)
        isLoading = true
        defer { isLoading = false }

        let response = try await router.send(
            AIProviderRequest(message: message, context: context, conversationHistory: messages)
        )
        messages.append(ChatMessage(role: .assistant, content: response))
        return response
    }
}
