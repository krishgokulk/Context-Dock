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

    /// The selection this card is about, captured at summon. Every row it builds or runs is
    /// for this copy — never the Dock's live selection, which can change under an open card.
    @Published private(set) var snapshot = SelectionSnapshot(
        text: "", filePaths: [], appName: "", bundleID: "")
    /// What can be done with it: the Dock's Selection rows, less Share, in the Dock's order.
    @Published private(set) var rows: [SelectionActionRow] = []
    /// The row ↑/↓ landed on. Nil: Return asks the typed question.
    @Published private(set) var focusedIndex: Int?

    /// Where the rows come from. Nil in production means "whoever is registered" — the Dock,
    /// today; a test gives its own.
    var providerOverride: (any SelectionActionProviding)?
    private var provider: (any SelectionActionProviding)? {
        providerOverride ?? SelectionActions.provider
    }
    /// How a question reaches a chat. The default hands it to the pipeline App Chat uses.
    var askHandler: ((SelectionAskRequest) -> Void)?
    /// The source app's live selected text, for rows that act on it. Tests replace it.
    var liveSelectedText: (String) -> String? = { bundleID in
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first
        else { return nil }
        AXContextReader.shared.refresh(from: app)
        return AXContextReader.shared.current.selectedText
    }
    /// When the rows are built. The card draws first and the rows follow a turn later: the
    /// Dock's builders read Finder's menus over Accessibility, and waiting for them held a
    /// file selection's card back by half a second. Tests run it at once.
    var scheduleRowBuild: (@escaping @MainActor () -> Void) -> Void = { build in
        DispatchQueue.main.async { MainActor.assumeIsolated { build() } }
    }
    /// The rows are being built for what is on the card now.
    @Published private(set) var isBuildingRows = false
    private var rowBuildGeneration = 0
    /// Whether the user is on the card right now — the pointer over it, or its field holding
    /// the keyboard while Context Dock is the active app. The idle clock does not run then.
    var isInUse: () -> Bool = {
        NSApp.isActive && CornerDockController.shared.keyboardState.owner == .selection
    }
    private(set) var pointerInside = false
    /// Said when the hotkey finds nothing selected, rather than doing nothing silently.
    var reportNothingSelected: (String) -> Void = { appName in
        AppToast.show(
            appName.isEmpty ? "Nothing selected" : "Nothing selected in \(appName)",
            icon: "text.cursor")
    }

    /// A short line the corner shows when a row has run, or could not.
    var reportResult: (_ title: String, _ success: Bool) -> Void = { title, success in
        DockActionFeedback.showResult(
            title, icon: success ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
            success: success)
    }

    private var standDownTask: Task<Void, Never>?

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
        snapshot = SelectionSnapshot(
            text: selectedText, filePaths: selectedFiles.map(\.path),
            appName: context.appName, bundleID: context.bundleId)
        rows = []
        focusedIndex = nil
        set(.showing)
        refreshRows()
        arm(after: Self.idleDwell)
        return true
    }

    enum HotkeyAction: Equatable { case open, close, replace, nothingSelected }

    /// Pure: what the Selection hotkey does. It closes the card only when the card is already
    /// about this selection. A new selection replaces it — pressing the hotkey on something new
    /// used to close the old card, and read as the hotkey not working.
    static func hotkeyAction(
        isVisible: Bool, captured: SelectionSnapshot, incoming: SelectionSnapshot
    ) -> HotkeyAction {
        if incoming.isEmpty { return isVisible ? .close : .nothingSelected }
        guard isVisible else { return .open }
        let same = incoming.text == captured.text && incoming.filePaths == captured.filePaths
        return same ? .close : .replace
    }

    func toggle(from context: AXContext) {
        let incoming = SelectionSnapshot(
            text: context.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            filePaths: context.selectedFilePaths, appName: context.appName,
            bundleID: context.bundleId)
        switch Self.hotkeyAction(
            isVisible: phase.isVisible, captured: snapshot, incoming: incoming)
        {
        case .close: dismiss()
        case .open, .replace: summon(from: context)
        case .nothingSelected: reportNothingSelected(context.appName)
        }
    }

    // MARK: - Rows

    /// Rebuild the rows for the captured selection and what is typed — a turn later, and only
    /// the latest request lands: a build started for an earlier keystroke is dropped.
    func refreshRows() {
        focusedIndex = nil
        rowBuildGeneration += 1
        let generation = rowBuildGeneration
        let captured = snapshot
        let typed = query
        isBuildingRows = true
        scheduleRowBuild { [weak self] in
            guard let self, generation == self.rowBuildGeneration, self.phase.isVisible,
                captured == self.snapshot
            else { return }
            let built = SelectionActions.cornerRows(
                self.provider?.selectionRows(for: captured, query: typed) ?? [])
            guard generation == self.rowBuildGeneration else { return }
            self.rows = built
            self.isBuildingRows = false
        }
    }

    /// The field changed: the list narrows the way the Dock's does.
    func queryChanged() {
        refreshRows()
        touch()
    }

    /// ↑/↓. Runs off the top back to the field. False when there is nothing to move through.
    @discardableResult
    func moveFocus(by delta: Int) -> Bool {
        guard !rows.isEmpty else { return false }
        touch()
        guard let current = focusedIndex else {
            focusedIndex = delta > 0 ? 0 : nil
            return delta > 0
        }
        let next = current + delta
        focusedIndex = next < 0 ? nil : min(next, rows.count - 1)
        return true
    }

    var focusedRow: SelectionActionRow? {
        focusedIndex.flatMap { rows.indices.contains($0) ? rows[$0] : nil }
    }

    /// Return: the chosen row, or the typed question when none is chosen.
    @discardableResult
    func returnPressed() -> Bool {
        if let row = focusedRow {
            run(row)
            return true
        }
        return submit()
    }

    /// Esc, and the card's ✕.
    func close() {
        dismiss()
    }

    func run(_ row: SelectionActionRow) {
        touch()
        switch row.kind {
        case .ask(let prompt):
            let request = SelectionAskRequest.make(prompt: prompt, snapshot: snapshot)
            // "Ask AI" with nothing typed has no question yet: the field is where it is asked.
            guard !request.prompt.isEmpty else { return }
            ask(request)
        case .perform:
            perform(row)
        case .share:
            break  // not offered in the corner (cornerRows); tracked with the extraction
        }
    }

    private func perform(_ row: SelectionActionRow) {
        let captured = snapshot
        let query = self.query
        if row.actsOnLiveTextSelection,
            !SelectionActions.liveTextStillMatches(
                captured: captured.text, live: liveSelectedText(captured.bundleID))
        {
            // Writing Tools act on the app's live selection, and text cannot be put back the
            // way files can. A changed selection is refused, never acted on.
            reportResult("The selection changed — select it again", false)
            return
        }
        let runIt = { [weak self] in
            guard let self else { return }
            let ran = self.provider?.runSelectionRow(id: row.id, query: query, for: captured) ?? false
            self.reportResult(ran ? row.title : "\(row.title) is not available", ran)
        }
        if SelectionActions.mustReselectInFinder(row, snapshot: captured) {
            // A Finder menu command acts on what Finder has selected when it runs: put the
            // captured files back as that selection first.
            NSWorkspace.shared.activateFileViewerSelecting(
                captured.filePaths.map { URL(fileURLWithPath: $0) })
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { runIt() }
        } else {
            runIt()
        }
    }

    // MARK: - Acting

    /// Ask about the selection. The turn goes to the app the selection came from, through
    /// the same pipeline the corner's App Chat uses — this surface chooses a subject, it
    /// does not run a second kind of turn.
    @discardableResult
    func submit() -> Bool {
        let request = SelectionAskRequest.make(prompt: query, snapshot: snapshot)
        guard !request.prompt.isEmpty else { return false }
        ask(request)
        return true
    }

    /// Hands a question about the captured selection to the chat, and shows the answer here.
    private func ask(_ request: SelectionAskRequest) {
        if let askHandler {
            askHandler(request)
        } else {
            // The selected text travels with the question. The pipeline otherwise falls back
            // to reading the live selection, and by the time the turn runs the frontmost app
            // is Context Dock, whose window has nothing selected — so the question about the
            // user's paragraph was asked without the paragraph.
            NotificationCenter.default.post(
                name: .appChatPromptSubmitted,
                object: nil,
                userInfo: [
                    "appName": request.appName,
                    "bundleId": request.bundleID,
                    "query": request.prompt,
                    "attachments": request.filePaths,
                    "selectedText": request.selectedText ?? "",
                ])
        }
        query = ""
        hasAsked = true
        // This surface chooses a subject; the corner's chat is where an answer is shown. It
        // used to hide itself here and hand over to a chat that was not on screen, so the
        // answer arrived nowhere and pressing Return looked like it had done nothing.
        if askHandler == nil {
            CornerDockController.shared.chatPresentation.presentAnswer(
                forSelectionIn: request.appName, bundleID: request.bundleID)
        }
        // Stay up while the turn runs: the card is what says which selection this is about.
        cancel()
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

    func pointerChanged(inside: Bool) {
        pointerInside = inside
        touch()
    }

    /// Pure: whether the idle clock may put the card away. Never while it is pinned, being
    /// pointed at, or typed into — it used to close after eight seconds while the user was
    /// still reading its rows.
    static func mayStandDown(isPinned: Bool, pointerInside: Bool, inUse: Bool) -> Bool {
        !isPinned && !pointerInside && !inUse
    }

    func dismiss() {
        cancel()
        isPinned = false
        hasAsked = false
        set(.hidden)
    }

    private func arm(after delay: TimeInterval) {
        standDownTask?.cancel()
        standDownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            guard Self.mayStandDown(
                isPinned: self.isPinned, pointerInside: self.pointerInside, inUse: self.isInUse())
            else {
                // Still in use: look again later rather than closing under the user.
                self.arm(after: Self.idleDwell)
                return
            }
            self.dismiss()
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
