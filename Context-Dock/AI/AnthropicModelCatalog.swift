import Foundation

/// Anthropic model IDs used by both plain chat and tool-call paths.
/// Keep this centralized because retired IDs return HTTP 404 even with a valid API key.
enum AnthropicModelCatalog {
    /// Current default. Opus 5 is the strongest model for the agentic, tool-calling work
    /// DoraX does; the user can pick a cheaper one in Settings.
    nonisolated static let defaultModelID = "claude-opus-5"

    /// Current, non-retired IDs — no date suffixes except where the ID carries one.
    nonisolated static let selectableModelIDs = [
        "claude-opus-5",
        "claude-opus-4-8",
        "claude-sonnet-5",
        "claude-sonnet-4-6",
        "claude-haiku-4-5",
    ]

    /// Adaptive thinking (`{"type": "adaptive"}`) plus `output_config.effort`. Sending these
    /// to a model that predates them is a 400, so gate on the ID rather than sending blind.
    /// Haiku 4.5 is deliberately excluded — it is on the older fixed-budget thinking API.
    nonisolated static func supportsAdaptiveThinking(_ modelID: String) -> Bool {
        let id = modelID.lowercased()
        if id.contains("haiku") { return false }
        return id.hasPrefix("claude-opus-5")
            || id.hasPrefix("claude-fable-5")
            || id.hasPrefix("claude-mythos-5")
            || id.hasPrefix("claude-sonnet-5")
            || id.hasPrefix("claude-opus-4-8")
            || id.hasPrefix("claude-opus-4-7")
            || id.hasPrefix("claude-opus-4-6")
            || id.hasPrefix("claude-sonnet-4-6")
    }
}
