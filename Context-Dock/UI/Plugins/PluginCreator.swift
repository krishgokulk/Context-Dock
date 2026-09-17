// Context-Dock
//
// The Plugin Creator: a manifest as text on the left, what it draws on the right, in every
// host it declares. A mode of the General Chat window rather than a window of its own — spec
// §12, and decision 67a1106d.
//
// The editing rule that matters: every keystroke makes JSON briefly invalid, so the preview
// keeps drawing the LAST manifest that parsed. Blanking it on each character makes the editor
// flicker and tells the author nothing about what they are building.

import Combine
import SwiftUI

@MainActor
final class PluginCreatorModel: ObservableObject {
    @Published var text: String { didSet { reparse() } }

    /// What the text says right now, or nil while it does not parse.
    @Published private(set) var manifest: PluginManifest?
    /// What the preview draws: the newest text that parsed, so it survives mid-edit.
    @Published private(set) var previewManifest: PluginManifest?
    @Published private(set) var diagnostics: [PluginDiagnostic] = []
    /// The plugin this was opened on, when it was opened on one.
    let editingID: String?

    /// The AI half. A description goes to the engine; what comes back replaces the text —
    /// the editor is the one place the manifest lives, so the model writes where the person
    /// writes and the preview follows either.
    @Published var request = ""
    @Published private(set) var isDrafting = false
    /// The model's one line about what it built, shown until the next draft or edit.
    @Published private(set) var note: String?
    @Published private(set) var draftError: String?

    /// Injected so a test can drive the round without a provider; the pane passes the live one.
    var makeEngine: (() -> PluginAuthoringEngine)?

    init(text: String, editingID: String? = nil) {
        self.text = text
        self.editingID = editingID
        reparse()
    }

    /// Describe → draft. A non-empty editor is what the description edits; the starter is
    /// treated as empty, so "a pomodoro timer" is a plugin and not a change to "My Plugin".
    func draft() async {
        let request = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isDrafting else { return }
        let engine = makeEngine?() ?? PluginAuthoringEngine.live(
            provider: AppSettings.shared.selectedAIProvider)
        let current = text == PluginCreatorPane.starter ? nil : text
        isDrafting = true
        draftError = nil
        defer { isDrafting = false }
        do {
            let draft = try await engine.draft(request, current: current)
            text = draft.text
            note = draft.note.isEmpty ? nil : draft.note
            self.request = ""
        } catch {
            draftError = error.localizedDescription
        }
    }

    /// The same prompt the engine sends, for a person to paste into any other AI; what
    /// comes back pastes into this editor and validates the same.
    func promptForAnotherAI() -> String {
        let request = request.trimmingCharacters(in: .whitespacesAndNewlines)
        return PluginAuthoringPrompt.exportable(
            request: request.isEmpty ? "<describe the plugin here>" : request)
    }

    convenience init(editing manifest: PluginManifest) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let text = (try? encoder.encode(manifest)).flatMap { String(data: $0, encoding: .utf8) }
            ?? "{}"
        self.init(text: text, editingID: manifest.id)
    }

    /// A warning never blocks a save — "this binding is not in your sample" is advice, and an
    /// editor that refuses to save while a plugin is half-written is an editor nobody uses.
    /// An error does: saving one would install a plugin that cannot work.
    var canSave: Bool {
        manifest != nil && !diagnostics.contains { $0.severity == .error }
    }

    var errors: [PluginDiagnostic] { diagnostics.filter { $0.severity == .error } }
    var warnings: [PluginDiagnostic] { diagnostics.filter { $0.severity == .warning } }

    private func reparse() {
        guard let data = text.data(using: .utf8) else { return }
        do {
            let decoded = try JSONDecoder().decode(PluginManifest.self, from: data)
            manifest = decoded
            previewManifest = decoded
            diagnostics = PluginSchema.validate(decoded)
        } catch {
            manifest = nil
            diagnostics = [PluginDiagnostic(
                severity: .error, path: "manifest",
                message: "not valid JSON yet — \(shortReason(error))")]
        }
    }

    /// Decoding errors are long and structural; the first line is the part an author can act
    /// on, and the rest is a coding path nobody reads while typing.
    private func shortReason(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case .dataCorrupted(let context): return context.debugDescription
            case .keyNotFound(let key, _): return "missing key \"\(key.stringValue)\""
            case .typeMismatch(_, let context): return context.debugDescription
            case .valueNotFound(_, let context): return context.debugDescription
            @unknown default: return error.localizedDescription
            }
        }
        return error.localizedDescription
    }

    @discardableResult
    func save() throws -> Bool {
        guard let manifest, canSave else { return false }
        try PluginInstaller.install(
            [manifest], into: PluginInstaller.userRoot,
            packID: PluginEssentials.packID, packName: PluginEssentials.packName)
        PluginRegistry.shared.reload()
        return true
    }
}
