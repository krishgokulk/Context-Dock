import Foundation

/// Why this turn could not run anything, when the reason is the provider.
///
/// Claude Code and Apple's on-device model are run deliberately without DoraX's tools — they
/// answer, the app acts. A request to *do* something under one of them therefore cannot run,
/// and the model has no way to know why: it was handed no tools and no explanation, so it
/// guessed. "My toolset lacks run_menu_command." "Not granted this session." Both were
/// attempts to describe a rule nobody had told it, and one of them described a permission
/// system that does not exist.
///
/// The app knows the reason exactly. Saying it is cheaper than leaving the model to invent it,
/// and it points at the setting that changes the outcome.
enum ProviderActionNotice {
    static func note(provider: AIProvider, intent: FrontmostAppTaskPlan.Intent) -> String? {
        guard intent == .act || intent == .workflow else { return nil }
        guard !provider.supportsNativeTools else { return nil }

        return "\n\n---\n**\(name(for: provider)) can answer here, but not act.** It runs with "
            + "its own toolset, so this chat's app actions — menu commands, adapter actions, "
            + "linked tools — are not available to it. Pick a provider that carries them in "
            + "Settings → AI Providers to run this from here."
    }

    /// Named precisely, because `shortName` calls both the Anthropic API and the Claude Code
    /// CLI "Claude" — and telling someone "Claude cannot act" while they are using Claude is
    /// the exact confusion this notice exists to end.
    private static func name(for provider: AIProvider) -> String {
        switch provider {
        case .claudeCode: return "Claude Code"
        case .onDevice: return "Apple Intelligence (on-device)"
        default: return provider.shortName
        }
    }
}
