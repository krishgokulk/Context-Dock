// SelectionScopeModel.swift
// Context-Dock
//
// The selection, as a card in the corner.
//
// Selection Scope used to open the launcher window drawn as a compact pill
// (`AppDelegate.presentSmartScope`). It looked like a corner surface without being one: it
// could not stack with the clipboard, the shelf or the chat, it pulled the launcher up
// behind it, and it had none of the corner's dwell-and-pin behaviour.
//
// This is the same job as a sibling of those surfaces instead. The selection is read once,
// when the hotkey fires and the source app is still frontmost — reading it later would
// capture whatever is selected in Context Dock's own window, which is nothing.

import AppKit
import Combine
import Foundation

enum SelectionScopePhase: Equatable {
    case hidden
    /// The selection, with a field under it.
    case showing
    var isVisible: Bool { self != .hidden }
}

@MainActor
final class SelectionScopeModel: ObservableObject {
    /// Matches the rest of the corner: nothing here outlives the user's attention.
    static let idleDwell: TimeInterval = 8
    /// Rows shown above the field. The Dock's sheet can hold more; the card is for the few
    /// that match what is typed, and typing narrows them.
    static let maxVisibleActions = 5

    @Published private(set) var phase: SelectionScopePhase = .hidden
    @Published var query = ""
    /// What was selected, captured at summon time.
    @Published private(set) var text = ""
    @Published private(set) var files: [URL] = []
    @Published private(set) var appName = ""
    @Published private(set) var appBundleID = ""
    @Published private(set) var isPinned = false
    /// A question has been asked from this card and its answer is being written elsewhere.
    ///
    /// The card stays up as the subject of that answer, but it stops claiming the keyboard:
    /// the conversation is in the chat now, and a follow-up should be typeable there without
    /// the user having to dismiss the thing their question was about.
    @Published private(set) var hasAsked = false
    /// What can be done with the selection — the Dock's Selection Scope rows for `query`.
    @Published private(set) var actions: [DockPill] = []
    /// The row ↑/↓ has reached. Nil means ↩ asks the question instead.
    @Published private(set) var focusedActionIndex: Int?

    private let source: SelectionActionSource
    /// Set while this card's selection is the Dock's frozen payload, so dismissing gives it
    /// back without clearing a Selection Scope the Dock opened on its own.
    private var lentToDock = false
    private var standDownTask: Task<Void, Never>?

    init(source: SelectionActionSource? = nil) {
        self.source = source ?? .shared
    }

    var onPhaseChange: ((SelectionScopePhase) -> Void)?

    /// How the selection describes itself — the same vocabulary the App Chat field uses,
    /// so one selection is named the same way wherever it is shown.
    var scope: AppChatSelectionScope? {
        if !files.isEmpty { return AppChatSelectionScope(kind: .files(count: files.count)) }
        guard !text.isEmpty else { return nil }
        return AppChatSelectionScope(kind: .text(characters: text.count))
    }

    /// One line of what was selected, for the card's body.
    var preview: String {
        if !files.isEmpty { return files.map(\.lastPathComponent).joined(separator: ", ") }
        return text
    }

    // MARK: - Opening

    /// Show the selection held in `context`. Returns false when there is nothing selected,
    /// so the caller can leave the corner alone rather than raising an empty card.
    @discardableResult
    func summon(from context: AXContext) -> Bool {
        let selectedText = context.selectedText?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectedFiles = context.selectedFilePaths.map { URL(fileURLWithPath: $0) }
        guard !selectedText.isEmpty || !selectedFiles.isEmpty else { return false }

        text = selectedText
        files = selectedFiles
        appName = context.appName
        appBundleID = context.bundleId
        query = ""
        hasAsked = false
        lendSelectionToDock()
        refreshActions()
        set(.showing)
        arm(after: Self.idleDwell)
        return true
    }

    /// The selection as the Dock freezes its own — the same shape
    /// `currentSelectionActivationSnapshot` builds, so the Dock's builders read it unchanged.
    private var activation: GlobalContextActivation {
        if !files.isEmpty {
            return GlobalContextActivation(
                autoActivated: false,
                frozenText: files.map(\.lastPathComponent).joined(separator: ", "),
                frozenIcon: files.count == 1 ? "doc" : "doc.on.doc",
                sourceBundleId: appBundleID,
                frozenFilePaths: files.map(\.path))
        }
        return GlobalContextActivation(
            autoActivated: false,
            frozenText: String(text.prefix(120)),
            frozenFullText: text,
            frozenIcon: "text.cursor",
            sourceBundleId: appBundleID)
    }

    private func lendSelectionToDock() {
        guard let adopt = source.adopt else { return }
        adopt(activation)
        lentToDock = true
    }

    // MARK: - Actions

    /// The typed text changed: narrow the rows to it, and forget a highlight that pointed
    /// into the old list.
    func queryDidChange() {
        touch()
        refreshActions()
    }

    func refreshActions() {
        let rows = source.actions?(query) ?? []
        actions = Array(rows.prefix(Self.maxVisibleActions))
        focusedActionIndex = nil
    }

    /// ↑/↓ over the rows, the Dock's keys. Moving up from the first row returns to the
    /// field (nothing highlighted), the way the Dock's sheet does. Returns false when there
    /// is nothing to move through, so the key can do its ordinary job.
    @discardableResult
    func moveActionFocus(by delta: Int) -> Bool {
        guard !actions.isEmpty else { return false }
        touch()
        guard let current = focusedActionIndex else {
            focusedActionIndex = delta > 0 ? 0 : nil
            return delta > 0
        }
        let next = current + delta
        if next < 0 {
            focusedActionIndex = nil
        } else {
            focusedActionIndex = min(next, actions.count - 1)
        }
        return true
    }

    /// Run a row through the Dock's executor. The work is done by then; the card goes.
    func run(_ pill: DockPill) {
        source.run?(pill)
        dismiss()
    }

    func toggle(from context: AXContext) {
        if phase.isVisible {
            dismiss()
        } else {
            summon(from: context)
        }
    }

    // MARK: - Acting

    /// Ask about the selection. The turn goes to the app the selection came from, through
    /// the same pipeline the corner's App Chat uses — this surface chooses a subject, it
    /// does not run a second kind of turn.
    @discardableResult
    func submit() -> Bool {
        // A highlighted row is what ↩ means — the same as the Dock's sheet.
        if let index = focusedActionIndex, actions.indices.contains(index) {
            run(actions[index])
            return true
        }
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return false }
        // The selected text travels with the question. The pipeline otherwise falls back to
        // reading the live selection, and by the time the turn runs the frontmost app is
        // Context Dock, whose window has nothing selected — so the question about the
        // user's paragraph was asked without the paragraph.
        NotificationCenter.default.post(
            name: .appChatPromptSubmitted,
            object: nil,
            userInfo: [
                "appName": appName,
                "bundleId": appBundleID,
                "query": question,
                "attachments": files.map(\.path),
                "selectedText": text,
            ])
        query = ""
        hasAsked = true
        // This surface chooses a subject; the corner's chat is where an answer is shown. It
        // used to hide itself here and hand over to a chat that was not on screen, so the
        // answer arrived nowhere and pressing Return looked like it had done nothing.
        CornerDockController.shared.chatPresentation.presentAnswer(
            forSelectionIn: appName, bundleID: appBundleID)
        // Stay up while the turn runs: the card is what says which selection this is about.
        cancel()
        return true
    }

    // MARK: - Dwell

    func togglePin() {
        isPinned.toggle()
        if isPinned { cancel() } else { arm(after: Self.idleDwell) }
    }

    func touch() {
        guard !isPinned, phase.isVisible else { return }
        arm(after: Self.idleDwell)
    }

    func dismiss() {
        cancel()
        isPinned = false
        hasAsked = false
        actions = []
        focusedActionIndex = nil
        if lentToDock {
            source.adopt?(nil)
            lentToDock = false
        }
        set(.hidden)
    }

    private func arm(after delay: TimeInterval) {
        standDownTask?.cancel()
        standDownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func cancel() {
        standDownTask?.cancel()
        standDownTask = nil
    }

    private func set(_ next: SelectionScopePhase) {
        guard phase != next else { return }
        phase = next
        onPhaseChange?(next)
    }
}
