// QuickNoteBoardCard.swift
// Context-Dock
//
// Quick Note, in the shell's result board (issue #247, inventory D11).
//
// The Dock drew the Quick Note command (`provider:notepad`) as a split editor in its sheet:
// the notes on the left, the chosen note's editor on the right, ⌘N for a new note, and
// Return in the field asking the AI and writing its answer into the note. The Corner steps
// into the same command from Global search and draws the same view, `NotepadScopeView`, in
// a board like every other scope's — one card over the field, not a second container.
//
// The notes are `QuickNotesStore`'s. The field is the prompt; the board's own state — which
// note is open, what is attached to the next prompt — is `QuickNoteBoardModel`'s, because
// the field's keys and the board both read it.

import AppKit
import Combine
import SwiftUI

// MARK: - Rules shared with the Dock

enum QuickNoteAI {
    /// The command's `provider:` name, which the board answers for.
    static let provider = "notepad"

    /// What the model is asked: the typed request, or — with nothing typed — a note written
    /// from what is attached, then captured screen text, all behind the frontmost window's
    /// context when the user attached it.
    static func request(prompt: String, capturedText: String, frontmostContext: String?)
        -> String
    {
        var request = prompt.isEmpty
            ? "Write a note from the attached image(s), file(s), or captured text."
            : prompt
        if !capturedText.isEmpty {
            request += "\n\nCaptured screen text:\n\(capturedText)"
        }
        guard let frontmostContext else { return request }
        return "Context from the user's frontmost window:\n\(frontmostContext)\n\n---\n\nRequest: \(request)"
    }

    /// The window the user came from — app, title, URL, selection — for the next prompt.
    @MainActor
    static func frontmostContext() -> (label: String, context: String) {
        let ctx = AXContextReader.shared.current
        let appName = ctx.appName.isEmpty
            ? (AppDelegate.shared?.previousFrontmostApp?.localizedName ?? "Frontmost app")
            : ctx.appName
        var parts: [String] = ["Frontmost app: \(appName)"]
        if let title = ctx.windowTitle, !title.isEmpty { parts.append("Window: \(title)") }
        if let url = ctx.currentURL, !url.isEmpty { parts.append("URL: \(url)") }
        if let selection = ctx.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
            !selection.isEmpty
        {
            parts.append("Selected text:\n\(selection)")
        }
        return (appName, parts.joined(separator: "\n"))
    }
}

extension SystemCommand {
    /// The Global Command the Quick Note board stands for.
    var isQuickNoteBoard: Bool { provider == QuickNoteAI.provider }

    /// A command the Corner draws as a board of its own rather than as its list panel.
    var hasOwnCornerBoard: Bool { isNotificationsBoard || isQuickNoteBoard }
}

// MARK: - The board's state

@MainActor
final class QuickNoteBoardModel: ObservableObject {
    static let shared = QuickNoteBoardModel()

    @Published var selectedNoteID: UUID?
    @Published private(set) var isGenerating = false
    @Published private(set) var frontmostLabel: String?
    private var frontmostContext: String?
    @Published var capturedText: String?

    private let store: QuickNotesStore
    /// How the question is asked. The Corner's panel assistant; a test hands in its own.
    var ask: @MainActor (String) async throws -> String = { request in
        try await PanelAssistant.ask(
            request, title: "Quick Note", subtitle: "Capture and search quick notes",
            extraPrompt: "Reply with the note's text only — it is written into the user's note as it is.",
            history: [], provider: AppSettings.shared.selectedAIProvider)
    }

    init(store: QuickNotesStore = .shared) {
        self.store = store
    }

    /// ⌘N: a blank note, chosen.
    func newNote() {
        selectedNoteID = store.create()
    }

    /// ↑/↓ in the field: through the notes, newest first.
    func move(down: Bool) -> Bool {
        let ids = store.notes.map { $0.id.uuidString }
        guard let next = NotificationsBoard.moved(
            from: selectedNoteID?.uuidString, in: ids, down: down)
        else { return false }
        selectedNoteID = UUID(uuidString: next)
        return true
    }

    func toggleFrontmostContext() {
        if frontmostContext != nil {
            frontmostContext = nil
            frontmostLabel = nil
            return
        }
        let frontmost = QuickNoteAI.frontmostContext()
        frontmostContext = frontmost.context
        frontmostLabel = frontmost.label
    }

    /// Return in the field: ask, and write the answer into the open note — a new one when
    /// none is open. False when there is nothing to ask, so the field keeps its Return.
    @discardableResult
    func submit(_ prompt: String) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let captured = capturedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !(trimmed.isEmpty && captured.isEmpty), !isGenerating else { return false }

        let target: UUID
        if let id = selectedNoteID, store.notes.contains(where: { $0.id == id }) {
            target = id
        } else {
            target = store.create()
            selectedNoteID = target
        }
        let request = QuickNoteAI.request(
            prompt: trimmed, capturedText: captured, frontmostContext: frontmostContext)
        frontmostContext = nil
        frontmostLabel = nil
        capturedText = nil
        isGenerating = true

        Task { @MainActor in
            let reply: String
            do {
                reply = try await ask(request)
            } catch {
                reply = "⚠️ AI error: \(error.localizedDescription)"
            }
            store.insertAssistantReply(reply, into: target)
            isGenerating = false
        }
        return true
    }
}

// MARK: - The board

enum QuickNoteBoardMetrics {
    static let headerHeight: CGFloat = 36
    static let footerHeight: CGFloat = 38

    /// The clipboard's board size: the boards are the same kind of thing.
    static var size: CGSize { ClipboardBoardMetrics.size }
    static var editorHeight: CGFloat { size.height - headerHeight - 1 - footerHeight }
}

struct QuickNoteBoardCard: View {
    /// The field the board stands over: what is typed there is the prompt.
    @ObservedObject var prompt: AppChatPromptModel
    @ObservedObject private var board = QuickNoteBoardModel.shared
    @ObservedObject private var store = QuickNotesStore.shared

    private var size: CGSize { QuickNoteBoardMetrics.size }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            NotepadScopeView(
                selectedNoteID: $board.selectedNoteID,
                isDark: true,
                isGenerating: board.isGenerating,
                aiProviderName: AppSettings.shared.selectedAIProvider.shortName,
                frontmostLabel: board.frontmostLabel,
                hasCapturedText: board.capturedText != nil,
                onAttachFrontmost: { board.toggleFrontmostContext() },
                onCaptureText: {
                    ChatAttachmentCapture.captureScreenText { board.capturedText = $0 }
                },
                onRemoveCapturedText: { board.capturedText = nil },
                onExit: { _ = prompt.leaveScopeForGlobal() },
                onEditorFocusChanged: { PluginKeyboardClaim.shared.fieldFocusChanged($0) },
                listWidth: CornerBoardLayout.listWidth(
                    board: size.width, preview: .file(URL(fileURLWithPath: "/"))),
                height: QuickNoteBoardMetrics.editorHeight)
            footer
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .modifier(BoardGlass())
        .onHover { _ in prompt.touch() }
        .onAppear { registerKeys() }
        .onDisappear {
            ScopedListKeyBridge.shared.move = nil
            ScopedListKeyBridge.shared.run = nil
        }
    }

    /// The field keeps the keyboard for the prompt and forwards ↑/↓ and Return here, as it
    /// does for every command's list (`ScopedListKeyBridge`).
    private func registerKeys() {
        let bridge = ScopedListKeyBridge.shared
        bridge.move = { down in
            prompt.touch()
            return board.move(down: down)
        }
        // Always taken: Return here asks into the note, or does nothing — it never falls
        // through to the panel assistant, whose answer this board does not draw.
        bridge.run = {
            if board.submit(prompt.query) {
                prompt.query = ""
            }
            return true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "note.text")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.indigo.opacity(0.9), in: RoundedRectangle(cornerRadius: 5))
            Text("Quick Note")
                .font(.system(size: 12, weight: .semibold))
            Text("\(store.notes.count)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .frame(height: QuickNoteBoardMetrics.headerHeight)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            BoardFooter.pill {
                BoardFooter.action(
                    "Ask \(AppSettings.shared.selectedAIProvider.shortName) into note",
                    keys: ["↩"], dimmed: prompt.query.isEmpty)
            }
            BoardFooter.pill {
                BoardFooter.button("square.and.pencil", keys: ["⌘", "N"], help: "New note (⌘N)") {
                    board.newNote()
                }
            }
            BoardFooter.pill {
                BoardFooter.button("xmark", keys: ["⌫"], help: "Back to Global Context (⌫)") {
                    _ = prompt.leaveScopeForGlobal()
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: QuickNoteBoardMetrics.footerHeight)
    }
}
