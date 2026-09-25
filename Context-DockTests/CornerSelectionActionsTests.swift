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
/// Share rows the corner leaves out — and a live selection of its own that can change under
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

    func runSelectionRow(id: String, query: String, for snapshot: SelectionSnapshot) -> Bool {
        ran.append((id, snapshot))
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
                row("share-dest-messages", "Messages", .share),
            ]
        }
        return [
            row("selection-ask-ai", "Ask AI — what would you like to do?", .ask(prompt: "")),
            row("selection-copy", "Copy File", .perform),
            row("finder-menu-compress", "Compress", .perform),
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
        var context = AXContext(appName: snapshot.appName, bundleId: snapshot.bundleID, pid: 1)
        context.selectedText = snapshot.text.isEmpty ? nil : snapshot.text
        context.selectedFilePaths = snapshot.filePaths
        model.summon(from: context)
        return model
    }

    // MARK: Same rows as the Dock

    @Test("A text selection lists the Dock's rows, in order, less Share")
    func textRowsAreTheDocksLessShare() {
        let dock = FakeDock()
        let model = card(text, dock: dock)
        let docks = FakeDock.rows(for: text)
        #expect(model.rows == docks.filter { $0.kind != .share })
        #expect(model.rows.map(\.id)
            == ["selection-ask-ai", "selection-copy", "selection-workflow-ai-rewrite",
                "shortcut-action-make-gif"])
    }

    @Test("A Finder file selection lists the Dock's rows, in order, less Share")
    func fileRowsAreTheDocksLessShare() {
        let dock = FakeDock()
        let model = card(file, dock: dock)
        #expect(model.rows == FakeDock.rows(for: file).filter { $0.kind != .share })
        #expect(!model.rows.contains { $0.kind == .share })
    }

    @Test("The real Dock's rows reach the card unchanged, less Share")
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
            var context = AXContext(appName: snapshot.appName, bundleId: snapshot.bundleID, pid: 1)
            context.selectedText = snapshot.text.isEmpty ? nil : snapshot.text
            context.selectedFilePaths = snapshot.filePaths
            model.summon(from: context)
            #expect(model.rows == SelectionActions.cornerRows(docks))
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
}
