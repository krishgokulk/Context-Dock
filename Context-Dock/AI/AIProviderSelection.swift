import Foundation

enum AIProviderSelectionSource: String, Codable, Sendable {
    case userSelection
    case explicitOverride
}

/// Which model answers, and on whose authority.
///
/// There was a `fallbackPolicy` here — never / ask / automatic — that nothing ever read. It
/// described a feature this app deliberately does not have: the provider shown in the UI is
/// the provider that answers, and silently rerouting a question to a different model (a
/// different privacy boundary, a different bill) because the chosen one was busy is not a
/// convenience, it is a lie about what just happened. Retries handle a busy provider; when it
/// is truly unavailable the honest outcome is to say so and let the user switch.
///
/// Deleted rather than left in place. A type that names a policy nobody enforces reads, to
/// the next person, as a policy that is enforced somewhere they have not looked yet.
struct AIProviderSelection: Equatable, Sendable {
    let requestedProvider: AIProvider
    let effectiveProvider: AIProvider
    let source: AIProviderSelectionSource

    static func userSelected(_ provider: AIProvider) -> AIProviderSelection {
        AIProviderSelection(
            requestedProvider: provider,
            effectiveProvider: provider,
            source: .userSelection
        )
    }

    static func explicit(_ provider: AIProvider) -> AIProviderSelection {
        AIProviderSelection(
            requestedProvider: provider,
            effectiveProvider: provider,
            source: .explicitOverride
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
