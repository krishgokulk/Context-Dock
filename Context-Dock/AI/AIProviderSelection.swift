import Foundation

enum AIProviderSelectionSource: String, Codable, Sendable {
    case userSelection
    case explicitOverride
    case fallback
}

enum AIProviderFallbackPolicy: String, Codable, Sendable {
    case never
    case ask
    case automatic
}

struct AIProviderSelection: Equatable, Sendable {
    let requestedProvider: AIProvider
    let effectiveProvider: AIProvider
    let source: AIProviderSelectionSource
    let fallbackPolicy: AIProviderFallbackPolicy

    static func userSelected(
        _ provider: AIProvider,
        fallbackPolicy: AIProviderFallbackPolicy = .never
    ) -> AIProviderSelection {
        AIProviderSelection(
            requestedProvider: provider,
            effectiveProvider: provider,
            source: .userSelection,
            fallbackPolicy: fallbackPolicy
        )
    }

    static func explicit(_ provider: AIProvider) -> AIProviderSelection {
        AIProviderSelection(
            requestedProvider: provider,
            effectiveProvider: provider,
            source: .explicitOverride,
            fallbackPolicy: .never
        )
    }
}

@MainActor
enum AIProviderSelectionResolver {
    static func current() -> AIProviderSelection {
        current(settings: .shared)
    }

    static func current(settings: AppSettings) -> AIProviderSelection {
        .userSelected(settings.selectedAIProvider)
    }
}
