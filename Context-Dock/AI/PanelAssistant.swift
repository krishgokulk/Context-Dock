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
        You may READ through DoraX capabilities — find_capability to see what exists, \
        run_capability to run one that reports something. You cannot run shell commands, \
        drive apps or write files here: anything that would change something is refused \
        on this surface, so say plainly what you would change instead of attempting it, \
        and never emit a bracketed command directive.

        Attached context is a live reading taken just now. Answer from it; never \
        invent a tab, link or file that is not listed.

        \(extraPrompt)\(attachmentNote)
        """.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a panel's assistant may reach.
    ///
    /// Discovery and reading, and nothing that acts. The panel used to be handed no tools
    /// at all, so a question it could have answered from the clipboard, the current page or
    /// one of DoraX's own skills was answered with a refusal — the model was not wrong, it
    /// simply had nothing to look with.
    static let tools: Set<String> = ["find_capability", "run_capability", "read_tool_result"]

    /// Ask that panel's assistant a question.
    ///
    /// `refusesChanges` is the half that makes the prompt above true. Narrowing the tool
    /// list keeps the shell, the menus and the keystrokes away, but `run_capability` reaches
    /// every registered capability by id, so the boundary is enforced where the call lands
    /// rather than trusted to a sentence.
    static func ask(
        _ question: String,
        title: String,
        subtitle: String,
        extraPrompt: String,
        attachmentNote: String = "",
        history: [ChatMessage],
        provider: AIProvider
    ) async throws -> String {
        let rawKey = AppSettings.shared.getAPIKey(for: provider)
        let (reply, _) = try await AIProviderService.shared.sendWithTools(
            question,
            context: .none,
            provider: provider,
            apiKey: rawKey.isEmpty ? nil : rawKey,
            conversationHistory: history,
            // A panel never runs a command. The executor exists because the signature wants
            // one; refusing here means a model that tries anyway is told no by the surface
            // rather than by a sheet the user has to read and dismiss.
            commandExecutor: { command, _, _ in
                (false, "This panel cannot run commands. Nothing ran: \(command)", 1)
            },
            additionalSystemPrompt: scopedPrompt(
                title: title, subtitle: subtitle, extraPrompt: extraPrompt,
                attachmentNote: attachmentNote),
            allowedToolNames: tools,
            refusesChanges: true
        )
        return reply
    }
}
