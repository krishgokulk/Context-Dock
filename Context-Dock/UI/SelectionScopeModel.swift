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

    // MARK: Answering in place

    /// The conversation the answer is written into — the one App Chat shows too. The card
    /// shows the part of it that this card asked, in place of its rows.
    let conversation: AppChatConversation
    /// The card is showing an answer (owner, 2026-09-25: answers belong in the Selection
    /// card, not a second card stacked on it).
    @Published private(set) var isShowingAnswer = false
    /// The first question this card asked, once it is in the conversation. Everything from it
    /// on is this card's thread; what came before belongs to the app's earlier chat.
    @Published private(set) var answerAnchorID: UUID?
    private var messageIDsBeforeAsking: Set<UUID> = []
    /// The card's first question, as asked — what its thread is found by.
    private var firstQuestion = ""
    private var conversationSink: AnyCancellable?

    /// Whether Computer Use is on for an app — what lets Replace write into it.
    var computerUseAllowed: (String) -> Bool = { bundleID in
        ComputerUseConsentStore.shared.effectiveMode(for: bundleID).canOperate
    }

    init(conversation: AppChatConversation = .shared) {
        self.conversation = conversation
    }

    /// This card's thread: from its first question to now.
    var answerMessages: [AIChatMessage] {
        guard let anchor = answerAnchorID,
            let start = conversation.messages.firstIndex(where: { $0.id == anchor })
        else { return [] }
        return Array(conversation.messages[start...])
    }

    /// The latest answer — what the end-of-result actions act on.
    var latestAnswer: String? {
        answerMessages.last(where: { $0.role == .assistant && !$0.isError })?.content
    }

    var isAnswering: Bool { isShowingAnswer && conversation.isLoading }

    /// Pure: the card's question in `messages` — a user message that was not there before it
    /// was asked and says what was asked. Matching the words matters: asking can switch the
    /// Dock to the app's own session, which loads that app's earlier chat — its older
    /// questions are "new" to the card too, and the thread latched onto one of them, then
    /// went blank when the session was swapped again.
    static func anchor(in messages: [AIChatMessage], before: Set<UUID>, question: String)
        -> UUID?
    {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return messages.last(where: {
            $0.role == .user && !before.contains($0.id)
                && $0.content.trimmingCharacters(in: .whitespacesAndNewlines) == asked
        })?.id
    }

    private func watchForAnchor() {
        conversationSink = conversation.$messages.sink { [weak self] messages in
            guard let self else { return }
            // Found once, kept — unless a session swap took it away; then it is found again.
            if let anchor = self.answerAnchorID, messages.contains(where: { $0.id == anchor }) {
                return
            }
            self.answerAnchorID = Self.anchor(
                in: messages, before: self.messageIDsBeforeAsking, question: self.firstQuestion)
        }
    }

    /// Pure: whether the card's field acts on Esc itself. While the card holds the corner's
    /// keyboard, the corner's key monitor takes Esc and calls `escapePressed` — and the field
    /// saw the same key press as well, so one Esc stepped back twice: out of Share and then
    /// closed the card.
    static func fieldHandlesEscape(keyboardOwner: CornerKeyboardClaimant) -> Bool {
        keyboardOwner != .selection
    }

    /// Pure: whether the card's field takes the caret back after the card changes what it
    /// shows — only while the card holds the corner's keyboard.
    static func fieldTakesFocus(keyboardOwner: CornerKeyboardClaimant) -> Bool {
        keyboardOwner == .selection
    }

    /// Esc: the share destinations step back to where Share was chosen; an answer steps back
    /// to the rows; the rows close the card.
    func escapePressed() {
        if pendingSend != nil {
            cancelSend()
        } else if pendingApproval != nil {
            cancelApproval()
        } else if pendingConsent != nil {
            cancelConsent()
        } else if isSharing {
            leaveShare()
        } else if isShowingAnswer {
            isShowingAnswer = false
            touch()
        } else {
            close()
        }
    }

    // MARK: End-of-result actions

    /// Where Copy puts the answer, and where Quick Note saves it. Tests replace both so they
    /// never touch the user's clipboard or notes.
    var copyText: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    var saveNote: (String) -> Bool = { QuickNotesStore.shared.add($0) }

    func copyAnswer() {
        guard let answer = latestAnswer else { return }
        copyText(answer)
        say("Copied", true)
    }

    /// Reports an outcome both ways: the corner's feedback, and the line in the card that the
    /// user is looking at.
    private func say(_ line: String, _ success: Bool) {
        reportResult(line, success)
        outcome = success ? "✓ \(line)" : line
    }

    func saveAnswerToQuickNote() {
        guard let answer = latestAnswer else { return }
        let saved = saveNote(answer)
        say(saved ? "Saved to Quick Note" : "Could not save the note", saved)
    }

    /// Share the answer: the destinations open in the card, and Esc comes back to the answer.
    func shareAnswer() {
        guard let answer = latestAnswer else { return }
        openShare(items: [answer], fromAnswer: true)
    }

    // MARK: Share

    /// The card lists share destinations instead of the selection's rows.
    @Published private(set) var isSharing = false
    /// True when the answer is what is being shared (Share at the end of an answer).
    @Published private(set) var isSharingAnswer = false
    private var sharePayload: [Any] = []
    /// The destinations for a payload, filtered by what is typed. Tests replace it.
    var shareRows: ([Any], String) -> [SelectionActionRow] = { items, query in
        SelectionShare.rows(for: items, query: query)
    }
    /// Shares the payload through one destination; false when it is not there. Tests replace
    /// it so nothing is ever sent.
    var performShare: (_ rowID: String, _ items: [Any]) -> Bool = { rowID, items in
        SelectionShare.perform(rowID: rowID, items: items)
    }

    // MARK: Typed "send to …"

    /// Reads what is typed as a send command. Tests replace it.
    var parseSendCommand: (String) -> ShareIntent? = { typed in
        SelectionShare.startsLikeSendCommand(typed) ? ShareIntentRouter.shared.parse(typed) : nil
    }
    /// Runs a send command on the captured selection. Tests replace it so nothing is sent.
    var runSendCommand: (
        ShareIntent, SelectionSnapshot, @escaping ([Any]) -> Void
    ) async -> String = { intent, snapshot, openDestinations in
        await SelectionShare.send(intent, snapshot: snapshot, openDestinations: openDestinations)
    }
    /// What the last row or send command did, said in the card — the card is where the user
    /// is looking, and a row that ran with no word back read as nothing having happened.
    @Published private(set) var outcome: String?
    @Published private(set) var isSending = false
    var showsOutcome: Bool { isSending || outcome != nil }

    /// A send waiting on the user's word: who it goes to, how, and exactly what. Nothing
    /// leaves the Mac until Send (↩ or a click) — a message sent to the wrong person, or
    /// with the wrong text, cannot be taken back.
    struct PendingSend {
        let intent: ShareIntent
        let snapshot: SelectionSnapshot
        var recipient: String
        let channel: String
        /// Exactly what is sent: the captured text, or the files' names.
        let content: String
    }
    @Published private(set) var pendingSend: PendingSend?

    /// Who a send goes to, as the contact lookup names it. Tests replace it.
    var describeRecipient: (ShareIntent) async -> String = { intent in
        await SelectionShare.recipientDescription(for: intent)
    }

    /// Pure: what a send carries, word for word.
    static func sendContent(_ snapshot: SelectionSnapshot) -> String {
        if !snapshot.filePaths.isEmpty {
            return snapshot.filePaths.map { URL(fileURLWithPath: $0).lastPathComponent }
                .joined(separator: ", ")
        }
        return snapshot.text
    }

    /// Choosing a send row: show who, how and what, and wait for Send.
    private func prepareSend() {
        guard let intent = parseSendCommand(query),
            let row = SelectionShare.intentRow(for: intent)
        else { return }
        let captured = snapshot
        let typed = intent.recipientQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
            .capitalized ?? ""
        pendingSend = PendingSend(
            intent: intent, snapshot: captured,
            recipient: typed.isEmpty ? "Choose in the share sheet" : typed,
            channel: SelectionShare.channelName(intent.channelHint) ?? row.title,
            content: Self.sendContent(captured))
        query = ""
        touch()
        Task { @MainActor [weak self] in
            guard let self, intent.recipientQuery != nil else { return }
            let named = await self.describeRecipient(intent)
            guard self.pendingSend?.intent.rawQuery == intent.rawQuery, !named.isEmpty else { return }
            self.pendingSend?.recipient = named
        }
    }

    /// Send (↩ or the button): the one place a send leaves the Mac.
    func confirmSend() {
        guard let pending = pendingSend else { return }
        pendingSend = nil
        send(pending.intent, captured: pending.snapshot)
    }

    func cancelSend() {
        pendingSend = nil
        touch()
    }

    private func send(_ intent: ShareIntent, captured: SelectionSnapshot) {
        isSending = true
        outcome = nil
        touch()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.runSendCommand(intent, captured) { [weak self] items in
                // "Share …" with no person: the destinations open here, not in a system sheet.
                self?.openShare(items: items, fromAnswer: false)
            }
            self.isSending = false
            guard captured == self.snapshot, self.phase.isVisible else { return }
            self.outcome = outcome
            self.touch()
        }
    }

    private func openShare(items: [Any], fromAnswer: Bool) {
        guard !items.isEmpty else {
            reportResult("Nothing to share", false)
            return
        }
        touch()
        sharePayload = items
        isSharingAnswer = fromAnswer
        isSharing = true
        isShowingAnswer = false
        query = ""
        refreshRows()
    }

    private func leaveShare() {
        isSharing = false
        sharePayload = []
        if isSharingAnswer { isShowingAnswer = true }
        isSharingAnswer = false
        query = ""
        touch()
        refreshRows()
    }

    private func share(_ row: SelectionActionRow) {
        if performShare(row.id, sharePayload) {
            // The destination's own sheet takes over; the card has done its job.
            dismiss()
        } else {
            reportResult("\(row.title) is not available", false)
        }
    }

    var replaceRoute: SelectionActions.ReplaceRoute {
        SelectionActions.replaceRoute(
            snapshot: snapshot, computerUseAllowed: computerUseAllowed(snapshot.bundleID))
    }

    /// Replace the selection with the answer where Computer Use allows it; otherwise copy it
    /// and say what would let it replace in place.
    func replaceWithAnswer() {
        guard let answer = latestAnswer else { return }
        switch replaceRoute {
        case .replaceInPlace:
            let done = provider?.replaceSelection(with: answer, for: snapshot) ?? false
            say(done ? "Replaced in \(snapshot.appName)" : "Could not replace", done)
        case .copyInstead:
            copyText(answer)
            say("Copied — Computer Use is off for \(snapshot.appName)", true)
        case .unavailable:
            break
        }
    }

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

    /// How the selection is previewed in the card.
    enum PreviewKind: Equatable {
        case text
        case file(URL)
        case files([URL])
        case folder(URL)
    }

    /// Pure: text reads as text; one file shows itself; several show a strip; one folder
    /// opens its listing — the view the pinned-folder card uses.
    static func previewKind(files: [URL], isDirectory: (URL) -> Bool) -> PreviewKind {
        guard let first = files.first else { return .text }
        if files.count > 1 { return .files(files) }
        return isDirectory(first) ? .folder(first) : .file(first)
    }

    /// The card is showing a folder's listing — it takes more room.
    var showsFolderPreview: Bool {
        guard !isShowingAnswer, !isSharing, case .folder = previewKind else { return false }
        return true
    }

    var previewKind: PreviewKind {
        Self.previewKind(files: files) { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    /// Opens the selected files in the app's own preview window (Quick Look inside DoraX),
    /// stepping through all of them. Tests replace it.
    var presentPreview: (_ url: URL, _ siblings: [URL]) -> Void = { url, siblings in
        PreviewController.shared.present(url: url, siblings: siblings, toggleIfSame: true)
    }

    /// Space on an empty field, or a click on the preview. False when there is no file.
    @discardableResult
    func quickLook(_ url: URL? = nil) -> Bool {
        guard let target = url ?? files.first else { return false }
        touch()
        presentPreview(target, files)
        return true
    }

    /// One line of what was selected, for the card's body.
    var preview: String {
        if isSharingAnswer, let answer = latestAnswer { return answer }
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
        isShowingAnswer = false
        answerAnchorID = nil
        conversationSink = nil
        isSharing = false
        isSharingAnswer = false
        sharePayload = []
        outcome = nil
        isSending = false
        pendingSend = nil
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
        if isSharing {
            // The destinations are one cached system call, asked for when Share was chosen.
            rows = shareRows(sharePayload, query)
            isBuildingRows = false
            return
        }
        // A typed send command leads the list, saying what Return will do.
        let sendRow = parseSendCommand(query).flatMap(SelectionShare.intentRow(for:))
        let generation = rowBuildGeneration
        let captured = snapshot
        let typed = query
        isBuildingRows = true
        scheduleRowBuild { [weak self] in
            guard let self, generation == self.rowBuildGeneration, self.phase.isVisible,
                captured == self.snapshot
            else { return }
            let built = SelectionActions.cornerRows(
                self.provider?.selectionRows(for: captured, query: typed) ?? []
            ).filter {
                SelectionActions.screenGate(
                    $0, snapshot: captured, computerUseAllowed: self.computerUseAllowed) != .hidden
            }
            guard generation == self.rowBuildGeneration else { return }
            self.rows = (sendRow.map { [$0] } ?? []) + built
            self.isBuildingRows = false
        }
    }

    /// The field changed: the list narrows the way the Dock's does.
    func queryChanged() {
        if !query.isEmpty { outcome = nil }
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

    /// Return: the chosen row, or the typed question when none is chosen. With an answer up,
    /// Return asks the follow-up.
    @discardableResult
    func returnPressed() -> Bool {
        // A question in the card is answered by Return: Send, Run, or Allow once.
        if pendingSend != nil {
            confirmSend()
            return true
        }
        if pendingApproval != nil {
            approveRun()
            return true
        }
        if pendingConsent != nil {
            allowOnce()
            return true
        }
        if isShowingAnswer { return submit() }
        if let row = focusedRow {
            run(row)
            return true
        }
        if isSharing {
            // Typing narrows the destinations; Return takes the first. Nothing is asked.
            guard !query.isEmpty, let first = rows.first else { return false }
            run(first)
            return true
        }
        // A typed send command is sent, never asked of the AI.
        if let first = rows.first, first.id == SelectionShare.intentRowID {
            run(first)
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
            if row.id == SelectionShare.entryRowID {
                openShare(items: SelectionShare.items(for: snapshot), fromAnswer: false)
            } else if row.id == SelectionShare.intentRowID {
                prepareSend()
            } else {
                share(row)
            }
        }
    }

    /// Makes the captured files Finder's selection again, then runs `then`. Tests replace it
    /// so they never drive Finder.
    var reselectInFinder: ([URL], @escaping () -> Void) -> Void = { urls, then in
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { then() }
    }

    // MARK: Computer Use consent

    func screenGate(for row: SelectionActionRow) -> SelectionActions.ScreenGate {
        SelectionActions.screenGate(row, snapshot: snapshot, computerUseAllowed: computerUseAllowed)
    }

    /// A row that needs Computer Use for its app, waiting on the user's answer in the card.
    @Published private(set) var pendingConsent: (row: SelectionActionRow, bundleID: String)?
    var grantOnce: (String) -> Void = { ComputerUseConsentStore.shared.grantOnce(for: $0) }
    var grantAlways: (String) -> Void = { ComputerUseConsentStore.shared.grantFromChat(for: $0) }
    /// Spends a one-shot grant; true when there was one.
    var consumeOnce: (String) -> Bool = {
        ComputerUseConsentStore.shared.consumeOneShotGrant(for: $0)
    }

    /// The app name a consent prompt is about.
    var pendingConsentAppName: String {
        guard let bundleID = pendingConsent?.bundleID else { return "" }
        if bundleID == snapshot.bundleID { return snapshot.appName }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? bundleID
    }

    func allowOnce() {
        guard let pending = pendingConsent else { return }
        pendingConsent = nil
        grantOnce(pending.bundleID)
        run(pending.row)
    }

    func allowAlways() {
        guard let pending = pendingConsent else { return }
        pendingConsent = nil
        grantAlways(pending.bundleID)
        run(pending.row)
    }

    func cancelConsent() {
        pendingConsent = nil
        touch()
    }

    /// Whether this row may take the screen now — spending a one-shot grant if that is what
    /// allows it.
    private func mayTakeScreen(_ row: SelectionActionRow) -> Bool {
        switch SelectionActions.screenGate(
            row, snapshot: snapshot, computerUseAllowed: computerUseAllowed)
        {
        case .run: return true
        case .hidden: return false
        case .needsConsent(let bundleID):
            if consumeOnce(bundleID) { return true }
            pendingConsent = (row, bundleID)
            return false
        }
    }

    // MARK: Approval for extensions with side effects

    /// A row waiting on "Run" in the card — the Dock's confirmation, asked here.
    @Published private(set) var pendingApproval: SelectionActionRow?
    private var approvedRowID: String?

    /// The card asks a question (Computer Use or an extension's approval) above its field.
    var isAsking: Bool { pendingConsent != nil || pendingApproval != nil || pendingSend != nil }

    func approveRun() {
        guard let row = pendingApproval else { return }
        pendingApproval = nil
        approvedRowID = row.id
        perform(row)
    }

    func cancelApproval() {
        pendingApproval = nil
        touch()
    }

    private func perform(_ row: SelectionActionRow) {
        if row.approval != nil, approvedRowID != row.id {
            pendingApproval = row
            touch()
            return
        }
        let approved = approvedRowID == row.id
        approvedRowID = nil
        guard mayTakeScreen(row) else { return }
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
            let wasApproved = SelectionActions.runApprovedInCard
            SelectionActions.runApprovedInCard = approved
            defer { SelectionActions.runApprovedInCard = wasApproved }
            let ran = self.provider?.runSelectionRow(id: row.id, query: query, for: captured) ?? false
            self.say(ran ? row.title : "\(row.title) is not available", ran)
        }
        if SelectionActions.mustReselectInFinder(row, snapshot: captured) {
            // A Finder menu command acts on what Finder has selected when it runs: put the
            // captured files back as that selection first.
            reselectInFinder(captured.filePaths.map { URL(fileURLWithPath: $0) }, runIt)
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
        if answerAnchorID == nil {
            // The first question of this card: remember what the conversation already held,
            // so the thread starts at this question and not at the app's older chat.
            messageIDsBeforeAsking = Set(conversation.messages.map(\.id))
            firstQuestion = request.prompt
            watchForAnchor()
        }
        isShowingAnswer = true
        outcome = nil
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
                    "selectionQuestion": true,
                ])
        }
        query = ""
        hasAsked = true
        // This surface chooses a subject; the corner's chat is where an answer is shown. It
        // used to hide itself here and hand over to a chat that was not on screen, so the
        // answer arrived nowhere and pressing Return looked like it had done nothing.
        // The answer is drawn in this card. The App Chat card is not raised for it: two cards
        // for one question was the owner's report (2026-09-25).
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
    /// `holdsAnswer`: an answer is on the card, or it is asking the user something. Neither
    /// closes by itself — the answer went away eight seconds after it arrived, while it was
    /// being read (the card does not take the app's focus, so reading it is not "in use").
    static func mayStandDown(
        isPinned: Bool, pointerInside: Bool, inUse: Bool, holdsAnswer: Bool = false
    ) -> Bool {
        !isPinned && !pointerInside && !inUse && !holdsAnswer
    }

    func dismiss() {
        // A send waiting on its confirmation never outlives the card that asked.
        pendingSend = nil
        cancel()
        isPinned = false
        hasAsked = false
        isShowingAnswer = false
        answerAnchorID = nil
        conversationSink = nil
        set(.hidden)
    }

    private func arm(after delay: TimeInterval) {
        standDownTask?.cancel()
        standDownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            guard Self.mayStandDown(
                isPinned: self.isPinned, pointerInside: self.pointerInside,
                inUse: self.isInUse() || self.isAnswering,
                holdsAnswer: self.isShowingAnswer || self.isAsking)
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
