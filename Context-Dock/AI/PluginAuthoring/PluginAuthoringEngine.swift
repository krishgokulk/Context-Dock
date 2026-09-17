// Context-Dock
//
// Engine A of the Creator (spec §12): describe a plugin in words, get a manifest back. One
// turn to the configured provider, the reply read for its JSON block, the block validated
// with the same `PluginSchema` the Save button uses, and one repair turn when it fails —
// the validator's own errors go back verbatim, so the model fixes what will be checked.
//
// The send is injected. The engine's job is the round — read, validate, retry — and that
// is what the tests hold; which provider answers is `AIProviderService`'s business.

import Foundation

/// What the person gets back: the manifest as text for the editor, the model's one line
/// about it, and how it validated.
struct PluginAuthoringDraft {
    let text: String
    let note: String
    let manifest: PluginManifest?
    let diagnostics: [PluginDiagnostic]

    var errors: [PluginDiagnostic] { diagnostics.filter { $0.severity == .error } }
}

enum PluginAuthoringError: Error, LocalizedError, Equatable {
    /// The model answered with no JSON object in it — a refusal or a question.
    case noManifest(reply: String)

    var errorDescription: String? {
        switch self {
        case .noManifest(let reply):
            let line = reply.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return line.isEmpty ? "The model sent no manifest." : "No manifest — it said: \(line)"
        }
    }
}

/// Reads a model's reply: the manifest is the ```json block if there is one, else the
/// outermost `{ … }`; the note is whatever came before it.
enum PluginAuthoringReply {
    static func parse(_ reply: String) -> (json: String, note: String)? {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let open = text.range(of: "```json") ?? text.range(of: "```"),
            let close = text.range(of: "```", range: open.upperBound..<text.endIndex)
        {
            let json = String(text[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let note = String(text[..<open.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard json.hasPrefix("{") else { return nil }
            return (json, lastLine(of: note))
        }

        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"),
            open < close
        else { return nil }
        let json = String(text[open...close])
        let note = String(text[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (json, lastLine(of: note))
    }

    /// The note is one line; a model that wrote three keeps the one nearest the block.
    private static func lastLine(of note: String) -> String {
        note.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    }
}

final class PluginAuthoringEngine {
    typealias Send = (_ user: String, _ system: String) async throws -> String

    private let send: Send

    init(send: @escaping Send) {
        self.send = send
    }

    /// One draft: the request, the manifest it edits when there is one, and a repair turn if
    /// the first reply does not validate. Two rounds at most — a model that cannot fix its
    /// own validator errors in one go is not going to in three, and every round is paid for.
    func draft(_ request: String, current: String?) async throws -> PluginAuthoringDraft {
        let system = PluginAuthoringPrompt.system
        var turn = PluginAuthoringPrompt.userTurn(request: request, current: current)
        var last: PluginAuthoringDraft?

        for _ in 0..<2 {
            let reply = try await send(turn, system)
            guard let read = PluginAuthoringReply.parse(reply) else {
                if let last { return last }
                throw PluginAuthoringError.noManifest(reply: reply)
            }
            let draft = Self.validate(read.json, note: read.note)
            if draft.errors.isEmpty { return draft }
            last = draft
            turn = PluginAuthoringPrompt.repairTurn(errors: draft.errors)
        }
        // Still wrong after the repair turn: hand it over anyway. The editor shows the
        // errors and the person can fix the last few by hand, which beats nothing.
        return last!
    }

    /// The same two checks the editor runs on every keystroke, so a draft that comes back
    /// clean is one the Save button accepts.
    static func validate(_ json: String, note: String) -> PluginAuthoringDraft {
        guard let data = json.data(using: .utf8),
            let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data)
        else {
            return PluginAuthoringDraft(
                text: json, note: note, manifest: nil,
                diagnostics: [PluginDiagnostic(
                    severity: .error, path: "manifest",
                    message: "not a manifest the app can decode")])
        }
        return PluginAuthoringDraft(
            text: json, note: note, manifest: manifest,
            diagnostics: PluginSchema.validate(manifest))
    }
}

extension PluginAuthoringEngine {
    /// The app's engine: the configured provider, no tools, nothing it can change. A model
    /// writing a manifest has no reason to reach the shell or the menus.
    @MainActor
    static func live(provider: AIProvider) -> PluginAuthoringEngine {
        PluginAuthoringEngine { user, system in
            let rawKey = AppSettings.shared.getAPIKey(for: provider)
            let (reply, _) = try await AIProviderService.shared.sendWithTools(
                user,
                context: .none,
                provider: provider,
                apiKey: rawKey.isEmpty ? nil : rawKey,
                conversationHistory: [],
                commandExecutor: { command, _, _ in
                    (false, "The Creator cannot run commands. Nothing ran: \(command)", 1)
                },
                maxIterations: 1,
                // The whole prompt, not an addendum: the launcher's persona proposes
                // commands and asks about the frontmost app, neither of which writes JSON.
                systemPromptOverride: system,
                allowedToolNames: [],
                refusesChanges: true
            )
            return reply
        }
    }
}
