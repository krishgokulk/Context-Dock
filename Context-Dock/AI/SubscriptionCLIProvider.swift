import Foundation

extension AIProvider {
    var isSubscriptionCLI: Bool { self == .claudeCode || self == .chatGPTSubscription }
}

/// One interception shared by the facade, router, prepared requests and tools fallback.
@MainActor
enum SubscriptionCLIProvider {
    static func send(
        provider: AIProvider, message: String, systemPrompt: String,
        history: [ChatMessage], onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let settings = AppSettings.shared
        switch provider {
        case .claudeCode:
            return try await ClaudeCodeCLIService.send(
                prompt: ClaudeCodeCLIService.promptWithHistory(message: message, history: history),
                systemPrompt: systemPrompt,
                model: settings.claudeCodeModel.isEmpty ? nil : settings.claudeCodeModel,
                onProgress: onProgress)
        case .chatGPTSubscription:
            return try await CodexCLIService.sendSubscription(
                message: message, systemPrompt: systemPrompt, history: history,
                model: settings.chatGPTSubscriptionModel.isEmpty ? nil : settings.chatGPTSubscriptionModel,
                onProgress: onProgress)
        default:
            throw AIServiceError.unsupportedProvider("Provider does not use a subscription CLI")
        }
    }
}
