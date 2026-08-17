// GeminiModelCatalog.swift
// Context-Dock
//
// Where Gemini's model id lives.
//
// Gemini puts the model in the request path rather than in the body, so the id was written
// into two URL literals and nowhere else — no setting, no picker, and no way for a user to
// move off gemini-2.0-flash. Both call sites now build the URL from here.

import Foundation

enum GeminiModelCatalog {
    /// Used when nothing has been chosen. Fast and cheap, which is the right default for a
    /// launcher answering short questions.
    static let defaultModelID = "gemini-2.0-flash"

    /// The buffered endpoint for a model id, accepting either the bare id or the
    /// path-qualified form the models list returns ("models/gemini-2.5-pro").
    static func generateContentEndpoint(model: String) -> String {
        "https://generativelanguage.googleapis.com/v1beta/models/\(normalized(model)):generateContent"
    }

    static func normalized(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultModelID }
        return trimmed.hasPrefix("models/")
            ? String(trimmed.dropFirst("models/".count)) : trimmed
    }
}
