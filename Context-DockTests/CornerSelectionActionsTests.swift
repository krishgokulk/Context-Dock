// Context-DockTests/CornerSelectionActionsTests.swift
//
// The corner's Selection card lists and runs the Dock's Selection rows through
// SelectionActionProviding (00-DOCK-AND-CORNER §4a, interim bridge). These tests are the
// safety net for extracting SelectionActionSource out of LauncherView: whatever type ends up
// conforming must keep every one of them green.

import Foundation
import Testing

@testable import Context_Dock

/// A provider that behaves like the Dock: rows for the selection it is handed, including the
/// per-destination Share rows the corner lists in its own share view instead — and a live selection of its own that can change under
/// an open card.
@MainActor
private final class FakeDock: SelectionActionProviding {
    var liveSelection: SelectionSnapshot?
    private(set) var builtFor: [SelectionSnapshot] = []
    private(set) var ran: [(id: String, snapshot: SelectionSnapshot)] = []

    func selectionRows(for snapshot: SelectionSnapshot, query: String) -> [SelectionActionRow] {
        builtFor.append(snapshot)
        return Self.rows(for: snapshot).filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
        }
    }

    private(set) var approvedAtRun: [Bool] = []
    func runSelectionRow(id: String, query: String, for snapshot: SelectionSnapshot) -> Bool {
        ran.append((id, snapshot))
        approvedAtRun.append(SelectionActions.runApprovedInCard)
        return true
    }

    private(set) var replaced: [(text: String, snapshot: SelectionSnapshot)] = []
    func replaceSelection(with text: String, for snapshot: SelectionSnapshot) -> Bool {
        replaced.append((text, snapshot))
        return true
    }

    /// The Dock's Selection list for a text and a file selection, in the Dock's order.
    static func rows(for snapshot: SelectionSnapshot) -> [SelectionActionRow] {
        func row(_ id: String, _ title: String, _ kind: SelectionActionRow.Kind) -> SelectionActionRow {
            SelectionActionRow(
                id: id, title: title, icon: "sparkles", badge: "Selection", accentColorName: nil,
                kind: kind)
        }
        if snapshot.filePaths.isEmpty {
            return [
                row("selection-ask-ai", "Ask AI — what would you like to do?", .ask(prompt: "")),
                row("selection-copy", "Copy Text", .perform),
                row("selection-workflow-ai-rewrite", "Rewrite",
                    .ask(prompt: "Rewrite this clearly. Return only the replacement text.")),
                row("selection-share", "Share…", .share),
                row("shortcut-action-make-gif", "Make GIF", .perform),
                SelectionActionRow(
                    id: "custom-selection-ext-plain", title: "Copy as Plain Text",
                    icon: "doc.on.clipboard", badge: "Extension", accentColorName: nil,
                    kind: .perform, approval: "change files, the clipboard, or another app"),
                row("share-dest-messages", "Messages", .share),
            ]
        }
        return [
            row("selection-ask-ai", "Ask AI — what would you like to do?", .ask(prompt: "")),
            row("selection-copy", "Copy File", .perform),
            row("finder-menu-compress", "Compress", .perform),
            row("selection-share", "Share Selection", .share),
            row("sharing-action-airdrop", "AirDrop", .share),
            row("selection-file-reveal", "Reveal in Finder", .perform),
        ]
    }
}

@Suite("Corner Selection actions")
@MainActor
struct CornerSelectionActionsTests {
    private let text = SelectionSnapshot(
        text: "The quarterly numbers look fine.", filePaths: [], appName: "TextEdit",
        bundleID: "com.apple.TextEdit")
    private let file = SelectionSnapshot(
        text: "", filePaths: ["/tmp/report.pdf"], appName: "Finder",
        bundleID: "com.apple.finder")

    private func card(_ snapshot: SelectionSnapshot, dock: FakeDock) -> SelectionScopeModel {
        let model = SelectionScopeModel()
        model.providerOverride = dock
        model.reportResult = { _, _ in }
        model.scheduleRowBuild = { $0() }
        model.computerUseAllowed = { _ in false }
        model.reselectInFinder = { _, then in then() }
        var context = AXContext(appName: snapshot.appName, bundleId: snapshot.bundleID, pid: 1)
        context.selectedText = snapshot.text.isEmpty ? nil : snapshot.text
        context.selectedFilePaths = snapshot.filePaths
        model.summon(from: context)
        return model
    }

    // MARK: Same rows as the Dock

    @Test("A text selection lists the Dock's rows, in order; Share is one row")
    func textRowsAreTheDocksWithOneShareRow() {
        let dock = FakeDock()
        let model = card(text, dock: dock)
        #expect(model.rows == SelectionActions.cornerRows(FakeDock.rows(for: text)))
        #expect(model.rows.map(\.id)
            == ["selection-ask-ai", "selection-copy", "selection-workflow-ai-rewrite",
                "selection-share", "shortcut-action-make-gif", "custom-selection-ext-plain"])
    }

    @Test("A Finder file selection lists the Dock's rows, in order; Share is one row")
    func fileRowsAreTheDocksWithOneShareRow() {
        let dock = FakeDock()
        let model = card(file, dock: dock)
        #expect(model.rows.map(\.id)
            == ["selection-ask-ai", "selection-copy", "finder-menu-compress", "selection-share",
                "selection-file-reveal"])
        #expect(model.rows.filter { $0.kind == .share }.map(\.id) == [SelectionShare.entryRowID])
    }

    @Test("The real Dock's rows reach the card unchanged, with Share Selection")
    func theDocksOwnRowsReachTheCard() {
        // The Dock itself, registered when its view appeared at launch — the cold path: this
        // host never opened ⌥⌥.
        guard let dock = SelectionActions.provider else {
            Issue.record("LauncherView did not register as the Selection provider at launch")
            return
        }
        for snapshot in [text, file] {
            let docks = dock.selectionRows(for: snapshot, query: "")
            #expect(docks.first?.id == "selection-ask-ai")
            let model = SelectionScopeModel()
            model.reportResult = { _, _ in }
            model.scheduleRowBuild = { $0() }
            var context = AXContext(appName: snapshot.appName, bundleId: snapshot.bundleID, pid: 1)
            context.selectedText = snapshot.text.isEmpty ? nil : snapshot.text
            context.selectedFilePaths = snapshot.filePaths
            model.summon(from: context)
            #expect(model.rows == SelectionActions.cornerRows(docks))
            #expect(docks.contains { $0.id == SelectionShare.entryRowID })
            // The corner asks without the per-destination share lists, which are most of the
            // build's cost. Leaving them out must change nothing else.
            if let launcher = dock as? LauncherView {
                let full = launcher.selectionRows(for: snapshot, query: "", includeShare: true)
                #expect(SelectionActions.cornerRows(full) == docks)
            }
        }
    }

    // MARK: Running goes through the provider, with the captured selection

    @Test("Running a row goes through the provider")
    func runningGoesThroughTheProvider() {
        let dock = FakeDock()
        let model = card(text, dock: dock)
        let copy = model.rows.first { $0.id == "selection-copy" }!
        model.run(copy)
        #expect(dock.ran.map(\.id) == ["selection-copy"])
        #expect(dock.ran.first?.snapshot == text)
    }

    @Test("A row runs on the selection the card captured, not the Dock's current one")
    func aRowRunsOnTheCapturedSelection() {
        let dock = FakeDock()
        dock.liveSelection = text
        let model = card(text, dock: dock)
        // The Dock moves on to another selection while the card is open.
        dock.liveSelection = SelectionSnapshot(
            text: "something else entirely", filePaths: [], appName: "Notes",
            bundleID: "com.apple.Notes")
        model.run(model.rows.first { $0.id == "shortcut-action-make-gif" }!)
        #expect(dock.ran.first?.snapshot == text)
    }

    @Test("The Dock's selection is swapped in for one call and put back")
    func theSwapIsScopedToOneCall() {
        var dockPayload: String? = "B"
        var seen: String?
        var scopedInside = false
        SelectionActions.withSwapped(
            "A" as String?, get: { dockPayload }, set: { dockPayload = $0 }
        ) {
            seen = dockPayload
            scopedInside = SelectionActions.isScopedToCapturedSelection
        }
        #expect(seen == "A")
        #expect(scopedInside)
        #expect(dockPayload == "B")
        #expect(!SelectionActions.isScopedToCapturedSelection)
    }

    @Test("A Writing Tools row refuses when the app's selection has changed")
    func aChangedLiveSelectionIsNotActedOn() {
        let dock = FakeDock()
        let model = card(text, dock: dock)
        var reported: [(String, Bool)] = []
        model.reportResult = { reported.append(($0, $1)) }
        model.liveSelectedText = { _ in "a different paragraph" }
        // Computer Use is on for the app: what stops the row is the changed selection.
        model.computerUseAllowed = { _ in true }
        model.run(SelectionActionRow(
            id: "selection-writing-tool-1-proofread", title: "Proofread", icon: "pencil",
            badge: nil, accentColorName: nil, kind: .perform))
        #expect(dock.ran.isEmpty)
        #expect(reported.first?.1 == false)
    }

    @Test("Rows that act on a live selection are known by their id")
    func liveSelectionRowsAreRecognised() {
        func row(_ id: String) -> SelectionActionRow {
            SelectionActionRow(
                id: id, title: id, icon: "", badge: nil, accentColorName: nil, kind: .perform)
        }
        #expect(SelectionActions.mustReselectInFinder(row("finder-menu-compress"), snapshot: file))
        #expect(!SelectionActions.mustReselectInFinder(row("finder-menu-compress"), snapshot: text))
        #expect(!SelectionActions.mustReselectInFinder(row("selection-copy"), snapshot: file))
        #expect(SelectionActions.liveTextStillMatches(captured: " a b ", live: "a b"))
        #expect(!SelectionActions.liveTextStillMatches(captured: "a", live: "b"))
        #expect(!SelectionActions.liveTextStillMatches(captured: "a", live: nil))
    }

    // MARK: One request for one selection and prompt

    @Test("The Dock and the corner build the identical request for a preset")
    func bothShellsBuildTheSameRequest() {
        let preset = "Rewrite this clearly. Return only the replacement text."
        for snapshot in [text, file] {
            // What the Dock's selection chat reads: the payload the bridge swaps in.
            let dockSide = SelectionSnapshot.fromFrozen(
                snapshot.asFrozenPayload, appName: snapshot.appName, bundleID: snapshot.bundleID)
            #expect(dockSide == snapshot)
            #expect(SelectionAskRequest.make(prompt: preset, snapshot: dockSide)
                == SelectionAskRequest.make(prompt: preset, snapshot: snapshot))
        }
        // And the corner's ask path sends exactly that.
        let dock = FakeDock()
        let model = card(text, dock: dock)
        var asked: [SelectionAskRequest] = []
        model.askHandler = { asked.append($0) }
        model.run(model.rows.first { $0.id == "selection-workflow-ai-rewrite" }!)
        #expect(asked == [SelectionAskRequest.make(prompt: preset, snapshot: text)])
        #expect(asked.first?.selectedText == text.text)
        #expect(asked.first?.appName == "TextEdit")
        #expect(dock.ran.isEmpty)
    }

    @Test("A Dock row carrying a prompt is an ask; Share rows are Share")
    func dockRowsAreClassified() {
        var ai = DockPill(id: "selection-workflow-ai-rewrite", name: "Rewrite", icon: "", accentColorName: nil, badge: nil, execute: {})
        ai.selectionAIPrompt = "Rewrite this."
        var shared = DockPill(id: "x", name: "Share", icon: "", accentColorName: nil, badge: nil, execute: {})
        shared.isShareAction = true
        let dest = DockPill(id: "share-dest-mail", name: "Mail", icon: "", accentColorName: nil, badge: nil, execute: {})
        let copy = DockPill(id: "selection-copy", name: "Copy", icon: "", accentColorName: nil, badge: nil, execute: {})
        #expect(LauncherView.selectionRow(from: ai).kind == .ask(prompt: "Rewrite this."))
        #expect(LauncherView.selectionRow(from: shared).kind == .share)
        #expect(LauncherView.selectionRow(from: dest).kind == .share)
        #expect(LauncherView.selectionRow(from: copy).kind == .perform)
    }

    // MARK: Keys and closing

    @Test("↑/↓ choose a row and Return runs it; with none chosen Return asks the question")
    func keysChooseAndRun() {
        let dock = FakeDock()
        let model = card(text, dock: dock)
        var asked: [SelectionAskRequest] = []
        model.askHandler = { asked.append($0) }
        #expect(model.moveFocus(by: 1))
        #expect(model.moveFocus(by: 1))
        #expect(model.focusedRow?.id == "selection-copy")
        model.returnPressed()
        #expect(dock.ran.map(\.id) == ["selection-copy"])

        model.query = "summarise this"
        model.queryChanged()
        #expect(model.focusedRow == nil)
        model.returnPressed()
        #expect(asked.map(\.prompt) == ["summarise this"])
    }

    @Test("The close button and Esc close the card")
    func closeAndEscapeClose() {
        let model = card(text, dock: FakeDock())
        #expect(model.phase == .showing)
        model.close()  // what both the ✕ and Esc call
        #expect(model.phase == .hidden)
    }

    @Test("The card grows by its rows, up to six")
    func theCardIsSizedByItsRows() {
        let none = SelectionScopeMetrics.size(rows: 0).height
        #expect(SelectionScopeMetrics.size(rows: 3).height
            == none + 3 * SelectionScopeMetrics.rowHeight)
        #expect(SelectionScopeMetrics.size(rows: 20).height
            == SelectionScopeMetrics.size(rows: 6).height)
    }

    // MARK: Opening fast, staying open, and the hotkey

    @Test("The card is up before its rows are built, and only the latest build lands")
    func theCardOpensBeforeItsRows() {
        let dock = FakeDock()
        let model = SelectionScopeModel()
        model.providerOverride = dock
        var pending: [@MainActor () -> Void] = []
        model.scheduleRowBuild = { pending.append($0) }
        var context = AXContext(appName: "TextEdit", bundleId: "com.apple.TextEdit", pid: 1)
        context.selectedText = text.text
        model.summon(from: context)
        #expect(model.phase == .showing)
        #expect(model.rows.isEmpty)
        #expect(model.isBuildingRows)

        // Typing before the first build ran: that build is stale and must not land.
        model.query = "copy"
        model.queryChanged()
        pending.forEach { $0() }
        #expect(dock.builtFor.count == 1)
        #expect(model.rows.map(\.id) == ["selection-copy", "custom-selection-ext-plain"])
        #expect(!model.isBuildingRows)
    }

    @Test("The idle clock never closes a card that is pinned, pointed at or in use")
    func theCardStaysWhileInUse() {
        #expect(SelectionScopeModel.mayStandDown(isPinned: false, pointerInside: false, inUse: false))
        #expect(!SelectionScopeModel.mayStandDown(isPinned: true, pointerInside: false, inUse: false))
        #expect(!SelectionScopeModel.mayStandDown(isPinned: false, pointerInside: true, inUse: false))
        #expect(!SelectionScopeModel.mayStandDown(isPinned: false, pointerInside: false, inUse: true))
        // An answer on the card stays until it is closed.
        #expect(!SelectionScopeModel.mayStandDown(
            isPinned: false, pointerInside: false, inUse: false, holdsAnswer: true))
    }

    @Test("The hotkey closes the card only for the same selection; a new one replaces it")
    func theHotkeyReplacesANewSelection() {
        let other = SelectionSnapshot(
            text: "DoraX", filePaths: [], appName: "TextEdit", bundleID: "com.apple.TextEdit")
        let none = SelectionSnapshot(text: "", filePaths: [], appName: "Mail", bundleID: "")
        typealias M = SelectionScopeModel
        #expect(M.hotkeyAction(isVisible: false, captured: text, incoming: text) == .open)
        #expect(M.hotkeyAction(isVisible: true, captured: text, incoming: text) == .close)
        #expect(M.hotkeyAction(isVisible: true, captured: text, incoming: other) == .replace)
        #expect(M.hotkeyAction(isVisible: false, captured: text, incoming: none) == .nothingSelected)
        #expect(M.hotkeyAction(isVisible: true, captured: text, incoming: none) == .close)
    }

    @Test("A new selection on the hotkey replaces the card; nothing selected says so")
    func theHotkeyOnTheModel() {
        let dock = FakeDock()
        let model = card(text, dock: dock)
        var context = AXContext(appName: "TextEdit", bundleId: "com.apple.TextEdit", pid: 1)
        context.selectedText = "DoraX"
        model.toggle(from: context)
        #expect(model.phase == .showing)
        #expect(model.snapshot.text == "DoraX")

        model.dismiss()
        var said: [String] = []
        model.reportNothingSelected = { said.append($0) }
        model.toggle(from: AXContext(appName: "Mail", bundleId: "com.apple.mail", pid: 1))
        #expect(model.phase == .hidden)
        #expect(said == ["Mail"])
    }

    // MARK: The answer in the card

    private func answeringCard(
        _ snapshot: SelectionSnapshot, dock: FakeDock, conversation: AppChatConversation
    ) -> SelectionScopeModel {
        let model = SelectionScopeModel(conversation: conversation)
        model.providerOverride = dock
        model.reportResult = { _, _ in }
        model.scheduleRowBuild = { $0() }
        model.askHandler = { request in
            // Stands in for the Dock's turn: the question lands in the conversation.
            conversation.messages.append(AIChatMessage(role: .user, content: request.prompt))
        }
        var context = AXContext(appName: snapshot.appName, bundleId: snapshot.bundleID, pid: 1)
        context.selectedText = snapshot.text.isEmpty ? nil : snapshot.text
        context.selectedFilePaths = snapshot.filePaths
        model.summon(from: context)
        return model
    }

    @Test("An AI row answers in the card, from its own question on")
    func theAnswerIsDrawnInTheCard() {
        let conversation = AppChatConversation()
        // The app's earlier chat is already in the conversation; it is not this card's.
        conversation.messages = [
            AIChatMessage(role: .user, content: "an older question"),
            AIChatMessage(role: .assistant, content: "an older answer"),
        ]
        let model = answeringCard(text, dock: FakeDock(), conversation: conversation)
        model.run(model.rows.first { $0.id == "selection-workflow-ai-rewrite" }!)
        #expect(model.isShowingAnswer)
        conversation.messages.append(AIChatMessage(role: .assistant, content: "The rewrite."))
        #expect(model.answerMessages.map(\.content)
            == ["Rewrite this clearly. Return only the replacement text.", "The rewrite."])
        #expect(model.latestAnswer == "The rewrite.")
    }

    @Test("The thread starts at the question even when older chat loads in around it")
    func theAnchorIsTheNewQuestion() {
        let old = AIChatMessage(role: .user, content: "old")
        let new = AIChatMessage(role: .user, content: "new")
        let reply = AIChatMessage(role: .assistant, content: "reply")
        #expect(SelectionScopeModel.anchor(
            in: [old, reply, new], before: [old.id], question: "new") == new.id)
        #expect(SelectionScopeModel.anchor(in: [old, reply], before: [old.id], question: "new") == nil)
        // The app's earlier chat, loaded when asking switched sessions: its older question is
        // new to the card, but it is not the card's question.
        let loaded = AIChatMessage(role: .user, content: "Summarize this")
        #expect(SelectionScopeModel.anchor(
            in: [loaded, reply], before: [], question: "Make a table") == nil)
        let asked = AIChatMessage(role: .user, content: "Make a table")
        #expect(SelectionScopeModel.anchor(
            in: [loaded, reply, asked], before: [], question: "Make a table") == asked.id)
    }

    @Test("Return asks a follow-up; Esc goes answer → actions → closed")
    func followUpsAndEscape() {
        let conversation = AppChatConversation()
        let model = answeringCard(text, dock: FakeDock(), conversation: conversation)
        model.query = "first"
        model.returnPressed()
        model.query = "and shorter?"
        #expect(model.returnPressed())
        #expect(conversation.messages.map(\.content) == ["first", "and shorter?"])
        #expect(model.answerMessages.count == 2)

        model.escapePressed()
        #expect(!model.isShowingAnswer)
        #expect(model.phase == .showing)
        model.escapePressed()
        #expect(model.phase == .hidden)
    }

    @Test("Replace writes back only with Computer Use; otherwise it copies and says why")
    func replaceFollowsComputerUse() {
        #expect(SelectionActions.replaceRoute(snapshot: text, computerUseAllowed: true)
            == .replaceInPlace)
        #expect(SelectionActions.replaceRoute(snapshot: text, computerUseAllowed: false)
            == .copyInstead)
        #expect(SelectionActions.replaceRoute(snapshot: file, computerUseAllowed: true)
            == .unavailable)

        for allowed in [true, false] {
            let conversation = AppChatConversation()
            let dock = FakeDock()
            let model = answeringCard(text, dock: dock, conversation: conversation)
            var copied: [String] = []
            model.copyText = { copied.append($0) }
            model.computerUseAllowed = { _ in allowed }
            model.query = "fix grammar"
            model.returnPressed()
            conversation.messages.append(AIChatMessage(role: .assistant, content: "Fixed."))
            model.replaceWithAnswer()
            if allowed {
                #expect(dock.replaced.map(\.text) == ["Fixed."])
                #expect(dock.replaced.first?.snapshot == text)
                #expect(copied.isEmpty)
            } else {
                #expect(dock.replaced.isEmpty)
                #expect(copied == ["Fixed."])
            }
        }
    }

    @Test("Copy and Quick Note act on the latest answer")
    func copyAndSaveTheAnswer() {
        let conversation = AppChatConversation()
        let model = answeringCard(text, dock: FakeDock(), conversation: conversation)
        var copied: [String] = []
        var saved: [String] = []
        model.copyText = { copied.append($0) }
        model.saveNote = { saved.append($0); return true }
        model.query = "summarise"
        model.returnPressed()
        conversation.messages.append(AIChatMessage(role: .assistant, content: "Summary."))
        model.copyAnswer()
        model.saveAnswerToQuickNote()
        #expect(copied == ["Summary."])
        #expect(saved == ["Summary."])
        #expect(model.outcome == "✓ Saved to Quick Note")
    }

    @Test("Answering, the card has room for the answer and its actions")
    func theAnsweringCardSize() {
        let answering = SelectionScopeMetrics.size(rows: 6, answering: true)
        #expect(answering.height > SelectionScopeMetrics.size(rows: 6).height)
        #expect(answering == SelectionScopeMetrics.size(rows: 0, answering: true))
    }

    // MARK: Screen-taking rows and Computer Use (surface-cost spec)

    private func row(_ id: String) -> SelectionActionRow {
        SelectionActionRow(
            id: id, title: id, icon: "", badge: nil, accentColorName: nil, kind: .perform)
    }

    @Test("Rows that drive an app's UI run only with Computer Use for that app")
    func screenRowsFollowComputerUse() {
        let off: (String) -> Bool = { _ in false }
        let on: (String) -> Bool = { _ in true }
        let finderRow = row("finder-menu-compress")
        let writing = row("selection-writing-tool-42-proofread")
        #expect(SelectionActions.screenGate(finderRow, snapshot: file, computerUseAllowed: on) == .run)
        #expect(SelectionActions.screenGate(finderRow, snapshot: file, computerUseAllowed: off)
            == .needsConsent(bundleID: "com.apple.finder"))
        // Writing Tools without Computer Use: the provider's AI rows do the same job.
        #expect(SelectionActions.screenGate(writing, snapshot: text, computerUseAllowed: off) == .hidden)
        #expect(SelectionActions.screenGate(writing, snapshot: text, computerUseAllowed: on) == .run)
        #expect(SelectionActions.screenGate(row("selection-copy"), snapshot: text, computerUseAllowed: off)
            == .run)
        #expect(writing.screenApp(for: text) == "com.apple.TextEdit")
    }

    @Test("Without Computer Use a Finder menu row asks first; Allow once runs it once")
    func consentIsAskedInTheCard() {
        let dock = FakeDock()
        let model = card(file, dock: dock)
        var once: Set<String> = []
        model.grantOnce = { once.insert($0) }
        model.consumeOnce = { once.remove($0) != nil }
        let compress = model.rows.first { $0.id == "finder-menu-compress" }!

        model.run(compress)
        #expect(dock.ran.isEmpty)
        #expect(model.pendingConsent?.bundleID == "com.apple.finder")

        model.allowOnce()
        #expect(model.pendingConsent == nil)
        #expect(dock.ran.map(\.id) == ["finder-menu-compress"])
        #expect(once.isEmpty)  // spent

        model.run(compress)  // asked again: once was once
        #expect(model.pendingConsent != nil)
        model.cancelConsent()
        #expect(dock.ran.count == 1)
    }

    @Test("Allow always grants the app and runs the row")
    func allowAlwaysGrants() {
        let dock = FakeDock()
        let model = card(file, dock: dock)
        var always: [String] = []
        model.grantAlways = { always.append($0) }
        model.run(model.rows.first { $0.id == "finder-menu-compress" }!)
        model.computerUseAllowed = { _ in !always.isEmpty }
        model.allowAlways()
        #expect(always == ["com.apple.finder"])
        #expect(dock.ran.map(\.id) == ["finder-menu-compress"])
    }

    // MARK: Share inside the card (the Dock's route 1: native destinations)

    private func dest(_ title: String) -> SelectionActionRow {
        SelectionActionRow(
            id: "share-dest-\(title.lowercased())", title: title, icon: "square.and.arrow.up",
            badge: "Share", accentColorName: "blue", kind: .share)
    }

    /// A card whose share destinations are fixed and whose sharing is recorded, never sent.
    private func sharingCard(
        _ snapshot: SelectionSnapshot, shared: @escaping (String, [Any]) -> Void
    ) -> SelectionScopeModel {
        let model = card(snapshot, dock: FakeDock())
        let all = [dest("AirDrop"), dest("Mail"), dest("Messages"), dest("Notes")]
        model.shareRows = { _, query in
            all.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        }
        model.performShare = { id, items in
            shared(id, items)
            return true
        }
        return model
    }

    @Test("Share Selection opens the destinations in the card and shares the captured text")
    func shareSelectionInTheCard() {
        var sent: [(String, [Any])] = []
        let model = sharingCard(text) { sent.append(($0, $1)) }
        model.run(model.rows.first { $0.id == SelectionShare.entryRowID }!)
        #expect(model.isSharing)
        #expect(model.rows.map(\.title) == ["AirDrop", "Mail", "Messages", "Notes"])
        #expect(model.phase.isVisible)

        model.run(model.rows[1])
        #expect(sent.map(\.0) == ["share-dest-mail"])
        #expect(sent.first?.1 as? [String] == [text.text])
        // The destination's own sheet takes over.
        #expect(!model.phase.isVisible)
    }

    @Test("Typing finds a destination; Return shares with it and never asks the AI")
    func typingNarrowsTheDestinations() {
        var sent: [String] = []
        var asked: [SelectionAskRequest] = []
        let model = sharingCard(text) { id, _ in sent.append(id) }
        model.askHandler = { asked.append($0) }
        model.run(model.rows.first { $0.id == SelectionShare.entryRowID }!)
        model.query = "mess"
        model.queryChanged()
        #expect(model.rows.map(\.title) == ["Messages"])
        model.returnPressed()
        #expect(sent == ["share-dest-messages"])
        #expect(asked.isEmpty)
    }

    @Test("Esc steps back from the destinations to the actions")
    func escLeavesShare() {
        let model = sharingCard(text) { _, _ in }
        let actions = model.rows
        model.run(model.rows.first { $0.id == SelectionShare.entryRowID }!)
        model.escapePressed()
        #expect(!model.isSharing)
        #expect(model.rows == actions)
        #expect(model.phase.isVisible)
    }

    @Test("A destination that is gone says so and the card stays")
    func aMissingDestinationSaysSo() {
        let model = sharingCard(text) { _, _ in }
        var reported: [(String, Bool)] = []
        model.reportResult = { reported.append(($0, $1)) }
        model.performShare = { _, _ in false }
        model.run(model.rows.first { $0.id == SelectionShare.entryRowID }!)
        model.run(model.rows[0])
        #expect(reported.first?.1 == false)
        #expect(model.phase.isVisible && model.isSharing)
    }

    @Test("Share at the end of an answer shares the answer; Esc returns to it")
    func shareTheAnswer() {
        let conversation = AppChatConversation()
        let model = answeringCard(text, dock: FakeDock(), conversation: conversation)
        var sent: [[Any]] = []
        model.shareRows = { _, _ in [self.dest("Notes")] }
        model.performShare = { _, items in sent.append(items); return true }
        model.query = "summarise"
        model.returnPressed()
        conversation.messages.append(AIChatMessage(role: .assistant, content: "Summary."))

        model.shareAnswer()
        #expect(model.isSharing && model.isSharingAnswer && !model.isShowingAnswer)
        #expect(model.preview == "Summary.")
        model.escapePressed()
        #expect(model.isShowingAnswer && !model.isSharing)

        model.shareAnswer()
        model.run(model.rows[0])
        #expect(sent.first as? [String] == ["Summary."])
    }

    @Test("What is shared: the captured files, else the captured text")
    func shareItemsFollowTheRouter() {
        #expect(SelectionShare.items(for: text) as? [String] == [text.text])
        #expect(SelectionShare.items(for: file) as? [URL] == [URL(fileURLWithPath: "/tmp/report.pdf")])
    }

    @Test("Destinations rank by use, then the system's order; the filter is the Dock's")
    func destinationsRankTheDocksWay() {
        let destinations = [
            SelectionShare.Destination(title: "AirDrop", image: nil, usage: 0),
            SelectionShare.Destination(title: "Mail", image: nil, usage: 0),
            SelectionShare.Destination(title: "Messages", image: nil, usage: 2),
        ]
        #expect(SelectionShare.rows(destinations, query: "").map(\.title)
            == ["Messages", "AirDrop", "Mail"])
        #expect(SelectionShare.rows(destinations, query: "ma").map(\.title) == ["Mail"])
        #expect(SelectionShare.rows(destinations, query: "").first?.id == "share-dest-messages")
    }

    @Test("One Esc steps back once: the field leaves Esc to the corner's monitor while the card has the keys")
    func oneEscapeStepsBackOnce() {
        #expect(!SelectionScopeModel.fieldHandlesEscape(keyboardOwner: .selection))
        #expect(SelectionScopeModel.fieldHandlesEscape(keyboardOwner: .none))
        // The field takes the caret back after the answer appears — only while the card has
        // the keys.
        #expect(SelectionScopeModel.fieldTakesFocus(keyboardOwner: .selection))
        #expect(!SelectionScopeModel.fieldTakesFocus(keyboardOwner: .chat))
    }

    // MARK: Typed "send to …" (the Dock's route 3)

    @Test("A typed send command is read the Dock's way and says what Return will do")
    func typedSendCommandRow() {
        let intent = ShareIntentRouter.shared.parse("send this to gokula kannan j via messages")
        #expect(intent?.channelHint == .messages)
        #expect(intent?.recipientQuery == "gokula kannan j")
        #expect(intent.flatMap(SelectionShare.intentRow(for:))?.title
            == "Send to Gokula Kannan J via Messages")
        #expect(SelectionShare.intentRow(for: ShareIntent(
            rawQuery: "email this", channelHint: .mail, recipientQuery: nil))?.title
            == "Send via Mail")
        #expect(SelectionShare.intentRow(for: ShareIntent(
            rawQuery: "share to notes", channelHint: .picker, recipientQuery: "notes"))?.title
            == "Share to Notes")
        // A bare "share" is the Share Selection row's job.
        #expect(SelectionShare.intentRow(for: ShareIntent(
            rawQuery: "share", channelHint: .picker, recipientQuery: nil)) == nil)
    }

    @Test("Return sends a typed command on the captured selection and never asks the AI")
    func returnSendsTheTypedCommand() async {
        let model = card(text, dock: FakeDock())
        var asked: [SelectionAskRequest] = []
        var sent: [(String, SelectionSnapshot)] = []
        model.askHandler = { asked.append($0) }
        model.runSendCommand = { intent, snapshot, _ in
            sent.append((intent.recipientQuery ?? "", snapshot))
            return "✅ Sent text to Gokula Kannan J via Messages"
        }
        model.query = "send this to gokula kannan j via messages"
        model.queryChanged()
        #expect(model.rows.first?.id == SelectionShare.intentRowID)

        model.returnPressed()
        for _ in 0..<20 { await Task.yield() }
        #expect(asked.isEmpty)
        #expect(sent.map(\.0) == ["gokula kannan j"])
        #expect(sent.first?.1 == text)
        #expect(model.outcome == "✅ Sent text to Gokula Kannan J via Messages")
        #expect(model.query.isEmpty)
        #expect(SelectionScopeMetrics.size(rows: 3, outcome: true).height
            == SelectionScopeMetrics.size(rows: 3).height + SelectionScopeMetrics.outcomeHeight)
    }

    @Test("A send command that needs the destinations opens them in the card")
    func sendCommandOpensDestinationsHere() async {
        let model = sharingCard(text) { _, _ in }
        model.runSendCommand = { _, _, openDestinations in
            openDestinations([self.text.text])
            return "✅ Opening share sheet…"
        }
        model.query = "share this to notes"
        model.queryChanged()
        model.returnPressed()
        for _ in 0..<20 { await Task.yield() }
        #expect(model.isSharing)
        #expect(!model.rows.isEmpty)
    }

    @Test("An ordinary question still goes to the AI")
    func aQuestionIsNotASendCommand() {
        let model = card(text, dock: FakeDock())
        var asked: [String] = []
        model.askHandler = { asked.append($0.prompt) }
        model.query = "what does churn mean here"
        model.queryChanged()
        #expect(model.rows.first?.id != SelectionShare.intentRowID)
        model.returnPressed()
        #expect(asked == ["what does churn mean here"])
    }

    @Test("Filtering the rows is not a send command: \"copy text\" copies")
    func filteringIsNotSending() {
        #expect(!SelectionShare.startsLikeSendCommand("copy text"))
        #expect(!SelectionShare.startsLikeSendCommand("copy as plain text"))
        #expect(SelectionShare.startsLikeSendCommand("text this to mom"))
        #expect(SelectionShare.startsLikeSendCommand("Send this to gokula via messages"))
        let model = SelectionScopeModel()
        #expect(model.parseSendCommand("copy text") == nil)
        #expect(model.parseSendCommand("send this to gokula kannan j via messages") != nil)
    }

    @Test("A question about a selection goes to the AI, never to a saved rule, command or extension")
    func selectionQuestionsSkipCommandRouting() {
        #expect(!LauncherView.triesCommandRouting(
            isSelectionQuestion: true, looksLikeQuestion: false, scopedHasLinkedCLI: false))
        #expect(LauncherView.triesCommandRouting(
            isSelectionQuestion: false, looksLikeQuestion: false, scopedHasLinkedCLI: false))
        #expect(!LauncherView.triesCommandRouting(
            isSelectionQuestion: false, looksLikeQuestion: true, scopedHasLinkedCLI: false))
        #expect(!LauncherView.mayAutoRunExtension(isSelectionQuestion: true))
        #expect(LauncherView.mayAutoRunExtension(isSelectionQuestion: false))
    }

    // MARK: Asking inside the card

    @Test("An extension that may change things asks in the card; Return runs it, approved once")
    func extensionApprovalIsAskedInTheCard() {
        let dock = FakeDock()
        let model = card(text, dock: dock)
        let plain = model.rows.first { $0.id == "custom-selection-ext-plain" }!
        model.run(plain)
        #expect(dock.ran.isEmpty)
        #expect(model.pendingApproval?.id == plain.id)
        #expect(model.isAsking)

        model.returnPressed()
        #expect(model.pendingApproval == nil)
        #expect(dock.ran.map(\.id) == [plain.id])
        #expect(dock.approvedAtRun == [true])
        #expect(!SelectionActions.runApprovedInCard)  // only for that one run

        model.run(plain)  // asked again next time
        #expect(model.pendingApproval != nil)
        model.escapePressed()
        #expect(model.pendingApproval == nil)
        #expect(model.phase.isVisible)
        #expect(dock.ran.count == 1)
    }

    @Test("Rows without side effects run at once, unapproved")
    func plainRowsDoNotAsk() {
        let dock = FakeDock()
        let model = card(text, dock: dock)
        model.run(model.rows.first { $0.id == "selection-copy" }!)
        #expect(model.pendingApproval == nil)
        #expect(dock.approvedAtRun == [false])
    }

    @Test("Return answers the Computer Use question with Allow once; Esc cancels it")
    func consentAnswersFromTheKeyboard() {
        let dock = FakeDock()
        let model = card(file, dock: dock)
        model.grantOnce = { _ in }
        var once = false
        model.grantOnce = { _ in once = true }
        model.consumeOnce = { _ in defer { once = false }; return once }
        let compress = model.rows.first { $0.id == "finder-menu-compress" }!
        model.run(compress)
        model.escapePressed()
        #expect(model.pendingConsent == nil && model.phase.isVisible)
        model.run(compress)
        model.returnPressed()
        #expect(dock.ran.map(\.id) == ["finder-menu-compress"])
    }

    @Test("A row that runs says so in the card")
    func aRunRowSaysSo() {
        let model = card(text, dock: FakeDock())
        model.run(model.rows.first { $0.id == "selection-copy" }!)
        #expect(model.outcome == "✓ Copy Text")
        #expect(model.showsOutcome)
        model.query = "x"
        model.queryChanged()
        #expect(model.outcome == nil)
    }

    // MARK: File preview in the card (part C)

    @Test("Text reads as text; one file shows itself; several a strip; a folder its listing")
    func previewKindFollowsTheSelection() {
        let pdf = URL(fileURLWithPath: "/tmp/report.pdf")
        let png = URL(fileURLWithPath: "/tmp/shot.png")
        let dir = URL(fileURLWithPath: "/tmp/Photos")
        let isDir: (URL) -> Bool = { $0 == dir }
        #expect(SelectionScopeModel.previewKind(files: [], isDirectory: isDir) == .text)
        #expect(SelectionScopeModel.previewKind(files: [pdf], isDirectory: isDir) == .file(pdf))
        #expect(SelectionScopeModel.previewKind(files: [pdf, png], isDirectory: isDir)
            == .files([pdf, png]))
        #expect(SelectionScopeModel.previewKind(files: [dir], isDirectory: isDir) == .folder(dir))
    }

    @Test("Space previews the selected files in the app's preview; text has nothing to preview")
    func spacePreviewsTheFiles() {
        let model = card(file, dock: FakeDock())
        var shown: [(URL, [URL])] = []
        model.presentPreview = { shown.append(($0, $1)) }
        #expect(model.quickLook())
        #expect(shown.first?.0 == URL(fileURLWithPath: "/tmp/report.pdf"))
        #expect(shown.first?.1 == [URL(fileURLWithPath: "/tmp/report.pdf")])

        let textCard = card(text, dock: FakeDock())
        textCard.presentPreview = { _, _ in Issue.record("text has no file to preview") }
        #expect(!textCard.quickLook())
    }

    @Test("A folder's listing makes the card taller, and only while the rows show")
    func folderPreviewSize() {
        let plain = SelectionScopeMetrics.size(rows: 3)
        let folder = SelectionScopeMetrics.size(rows: 3, folderPreview: true)
        #expect(folder.height - plain.height
            == SelectionScopeMetrics.folderPreviewHeight - SelectionScopeMetrics.previewHeight)
        #expect(SelectionScopeMetrics.size(rows: 3, answering: true, folderPreview: true)
            == SelectionScopeMetrics.size(rows: 3, answering: true))
    }
}

