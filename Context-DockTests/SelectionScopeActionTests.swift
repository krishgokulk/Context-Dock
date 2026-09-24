// SelectionScopeActionTests.swift
// Context-DockTests
//
// The corner's selection card acts on the selection with the Dock's own rows
// (docs/master/00-DOCK-AND-CORNER.md §4a). A fake Dock stands in for LauncherView: it records
// what it was lent and what it ran, and filters a fixed list of rows by the query.

import Testing

@testable import Context_Dock

@MainActor
private final class FakeDock {
    let source = SelectionActionSource()
    private(set) var payload: GlobalContextActivation?
    private(set) var ran: [String] = []
    private(set) var queries: [String] = []
    var rows: [String] = ["Summarize", "Share…", "Add to Reminders", "Translate", "Copy",
                          "Open in TextEdit", "Rewrite shorter"]

    init() {
        source.adopt = { [unowned self] in payload = $0 }
        source.actions = { [unowned self] query in
            queries.append(query)
            let q = query.lowercased()
            return rows
                .filter { q.isEmpty || $0.lowercased().contains(q) }
                .map { name in DockPill(id: name, name: name, icon: "bolt.fill", badge: nil, execute: {}) }
        }
        source.run = { [unowned self] pill in ran.append(pill.name) }
    }
}

@Suite("Selection scope actions")
@MainActor
struct SelectionScopeActionTests {
    private func context(text: String? = "a paragraph worth acting on", files: [String] = [])
        -> AXContext
    {
        var ctx = AXContext(appName: "TextEdit", bundleId: "com.apple.TextEdit", pid: 1)
        ctx.selectedText = text
        ctx.selectedFilePaths = files
        return ctx
    }

    @Test("Opening lends the selection to the Dock and lists its rows")
    func summonLendsAndLists() {
        let dock = FakeDock()
        let model = SelectionScopeModel(source: dock.source)

        model.summon(from: context())

        #expect(dock.payload?.frozenFullText == "a paragraph worth acting on")
        #expect(dock.payload?.sourceBundleId == "com.apple.TextEdit")
        #expect(model.actions.map(\.name).first == "Summarize")
        #expect(model.actions.count == SelectionScopeModel.maxVisibleActions)
    }

    @Test("Selected files are lent as files, the shape the Dock freezes")
    func filesAreLentAsFiles() {
        let dock = FakeDock()
        let model = SelectionScopeModel(source: dock.source)

        model.summon(from: context(text: nil, files: ["/tmp/a.pdf"]))

        #expect(dock.payload?.frozenFilePaths == ["/tmp/a.pdf"])
        #expect(dock.payload?.frozenText == "a.pdf")
    }

    @Test("Typing narrows the rows to the Dock's matches")
    func typingFilters() {
        let dock = FakeDock()
        let model = SelectionScopeModel(source: dock.source)
        model.summon(from: context())

        model.query = "tra"
        model.queryDidChange()

        #expect(model.actions.map(\.name) == ["Translate"])
        #expect(dock.queries.last == "tra")
    }

    @Test("↓ reaches the first row, ↑ from it returns to the field")
    func arrowsWalkTheRows() {
        let dock = FakeDock()
        let model = SelectionScopeModel(source: dock.source)
        model.summon(from: context())

        #expect(model.moveActionFocus(by: 1))
        #expect(model.focusedActionIndex == 0)
        #expect(model.moveActionFocus(by: 1))
        #expect(model.focusedActionIndex == 1)
        #expect(model.moveActionFocus(by: -1))
        #expect(model.moveActionFocus(by: -1))
        #expect(model.focusedActionIndex == nil)
    }

    @Test("↓ stops at the last row rather than wrapping")
    func arrowsStopAtTheEnd() {
        let dock = FakeDock()
        dock.rows = ["Summarize", "Share…"]
        let model = SelectionScopeModel(source: dock.source)
        model.summon(from: context())

        for _ in 0..<5 { model.moveActionFocus(by: 1) }

        #expect(model.focusedActionIndex == 1)
    }

    @Test("With no rows the arrows are not claimed")
    func arrowsPassThroughWithoutRows() {
        let dock = FakeDock()
        dock.rows = []
        let model = SelectionScopeModel(source: dock.source)
        model.summon(from: context())

        #expect(model.moveActionFocus(by: 1) == false)
    }

    @Test("↩ on a highlighted row runs it through the Dock and closes the card")
    func returnRunsTheFocusedRow() {
        let dock = FakeDock()
        let model = SelectionScopeModel(source: dock.source)
        model.summon(from: context())
        model.moveActionFocus(by: 1)
        model.moveActionFocus(by: 1)

        #expect(model.submit())

        #expect(dock.ran == ["Share…"])
        #expect(model.phase == .hidden)
    }

    @Test("↩ with nothing highlighted runs no row")
    func returnWithoutFocusRunsNothing() {
        let dock = FakeDock()
        let model = SelectionScopeModel(source: dock.source)
        model.summon(from: context())

        #expect(model.submit() == false)  // empty field: nothing to ask either

        #expect(dock.ran.isEmpty)
    }

    @Test("Typing forgets a highlight that pointed into the old list")
    func typingClearsTheHighlight() {
        let dock = FakeDock()
        let model = SelectionScopeModel(source: dock.source)
        model.summon(from: context())
        model.moveActionFocus(by: 1)

        model.query = "copy"
        model.queryDidChange()

        #expect(model.focusedActionIndex == nil)
    }

    @Test("Closing gives the selection back to the Dock")
    func dismissClearsTheLoan() {
        let dock = FakeDock()
        let model = SelectionScopeModel(source: dock.source)
        model.summon(from: context())

        model.dismiss()

        #expect(dock.payload == nil)
        #expect(model.actions.isEmpty)
    }

    @Test("With no Dock connected the card still opens, with no rows")
    func noDockMeansNoRows() {
        let model = SelectionScopeModel(source: SelectionActionSource())

        #expect(model.summon(from: context()))
        #expect(model.actions.isEmpty)
    }

    @Test("The card's height grows by exactly its rows")
    func sizeFollowsTheRows() {
        let bare = SelectionScopeMetrics.size(actionRows: 0).height
        let three = SelectionScopeMetrics.size(actionRows: 3).height

        #expect(three - bare
            == 3 * SelectionScopeMetrics.actionRowHeight + SelectionScopeMetrics.actionsBottomPadding)
    }
}
