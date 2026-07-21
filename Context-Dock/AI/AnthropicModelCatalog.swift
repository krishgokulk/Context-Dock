import Foundation

/// Anthropic model IDs used by both plain chat and tool-call paths.
/// Keep this centralized because retired IDs return HTTP 404 even with a valid API key.
enum AnthropicModelCatalog {
    /// Anthropic's documented replacement for retired Claude 3.5 Haiku.
    nonisolated static let defaultModelID = "claude-haiku-4-5-20251001"
}
