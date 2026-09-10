// PanelAssistant.swift
// Context-Dock
//
// The assistant that belongs to a panel — an extension, or a Global Command with an
// interface — asked from wherever that panel is being shown.
//
// The prompt is what makes it that panel's assistant rather than the launcher's: without an
// identity of its own the model inherits the app-wide persona and proposes shell commands it
// cannot run inside a converter. That rule lived in the panel's own composer, which meant a
// surface without that composer had no way to ask the same question — the corner mounts the
// panel and puts its field underneath, so it needed exactly this and nothing else.

import Foundation

enum PanelAssistant {

    /// What the model is told it is, before the user's question.
    ///
    /// Kept verbatim from the panel composer it was taken out of: the restrictions are the
    /// point, and a paraphrase would quietly widen what the assistant believes it may do.
    static func scopedPrompt(
        title: String, subtitle: String, extraPrompt: String, attachmentNote: String = ""
    ) -> String {
        """
        You are the assistant inside the "\(title)" panel in Context Dock.
        \(subtitle)
        Stay within this panel's subject, plus anything the user has attached below. \
        You cannot run commands, open apps or touch files — if a request needs that, \
        say so plainly instead of emitting any bracketed command directive.

        Attached context is a live reading taken just now. Answer from it; never \
        invent a tab, link or file that is not listed.

        \(extraPrompt)\(attachmentNote)
        """.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ask that panel's assistant a question.
    static func ask(
        _ question: String,
        title: String,
        subtitle: String,
        extraPrompt: String,
        history: [ChatMessage],
        provider: AIProvider
    ) async throws -> String {
        try await AIProviderService.shared.sendMessage(
            question,
            context: .none,
            provider: provider,
            conversationHistory: history,
            additionalContextPrompt: scopedPrompt(
                title: title, subtitle: subtitle, extraPrompt: extraPrompt),
            surfaceScoped: true
        )
    }
}
