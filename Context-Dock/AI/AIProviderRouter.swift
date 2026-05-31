import Foundation

struct AIProviderRequest {
    var message: String
    var context: UserContext
    var conversationHistory: [ChatMessage] = []
    var additionalContextPrompt = ""
}

protocol AIProviderAdapter {
    var provider: AIProvider { get }

    func send(
        _ request: AIProviderRequest,
        service: AIProviderService,
        settings: AppSettings
    ) async throws -> String
}

extension AIProviderAdapter {
    func send(
        _ request: AIProviderRequest,
        service: AIProviderService,
        settings: AppSettings
    ) async throws -> String {
        try await service.sendMessage(
            request.message,
            context: request.context,
            provider: provider,
            apiKey: settings.getAPIKey(for: provider),
            conversationHistory: request.conversationHistory,
            additionalContextPrompt: request.additionalContextPrompt
        )
    }
}

struct OpenAIProvider: AIProviderAdapter {
    let provider: AIProvider = .openAI
}

struct ClaudeProvider: AIProviderAdapter {
    let provider: AIProvider = .anthropic
}

struct GeminiProvider: AIProviderAdapter {
    let provider: AIProvider = .googleGemini
}

struct LocalModelProvider: AIProviderAdapter {
    let provider: AIProvider = .ollama
}

struct OnDeviceProvider: AIProviderAdapter {
    let provider: AIProvider = .onDevice
}

struct ShortcutsProvider: AIProviderAdapter {
    let provider: AIProvider = .shortcuts
}

@MainActor
final class AIProviderRouter {
    static let shared = AIProviderRouter()

    private let providerService: AIProviderService
    private let settings: AppSettings

    init(
        providerService: AIProviderService = .shared,
        settings: AppSettings = .shared
    ) {
        self.providerService = providerService
        self.settings = settings
    }

    func send(_ request: AIProviderRequest) async throws -> String {
        let provider = settings.selectedAIProvider
        return try await adapter(for: provider).send(
            request,
            service: providerService,
            settings: settings
        )
    }

    private func adapter(for provider: AIProvider) -> any AIProviderAdapter {
        switch provider {
        case .openAI: return OpenAIProvider()
        case .anthropic: return ClaudeProvider()
        case .googleGemini: return GeminiProvider()
        case .ollama: return LocalModelProvider()
        case .onDevice: return OnDeviceProvider()
        case .shortcuts: return ShortcutsProvider()
        }
    }
}

@MainActor
final class AIActionPlanner {
    static let shared = AIActionPlanner()

    private init() {}

    func prompt(for manifest: ExtensionManifest, context: ExtensionContext) -> String {
        var lines = [
            "Extension: \(manifest.name)",
            "Task: \(manifest.summary)",
        ]
        if !context.selectedText.isEmpty {
            lines.append("Selected text:\n\(context.selectedText)")
        }
        if !context.selectedFiles.isEmpty {
            let fileList = context.selectedFiles.map(\.path).joined(separator: "\n")
            lines.append("Selected files:\n\(fileList)")
        }
        if let url = context.selectedURL {
            lines.append("URL: \(url)")
        }
        return lines.joined(separator: "\n\n")
    }
}
