// SelectionScopeModelTests.swift
// Context-DockTests

import Testing

@testable import Context_Dock

@Suite("Selection scope")
@MainActor
struct SelectionScopeModelTests {

    private func context(
        app: String = "Code", bundleID: String = "com.microsoft.VSCode",
        text: String? = nil, files: [String] = []
    ) -> AXContext {
        var ctx = AXContext(appName: app, bundleId: bundleID, pid: 1)
        ctx.selectedText = text
        ctx.selectedFilePaths = files
        return ctx
    }

    @Test("Selected text raises the card and is described by length")
    func textSelectionOpens() {
        let model = SelectionScopeModel()

        #expect(model.summon(from: context(text: "let x = 1")))
        #expect(model.phase == .showing)
        #expect(model.scope?.kind == .text(characters: 9))
        #expect(model.appName == "Code")
    }

    @Test("Nothing selected raises nothing — an empty card is worse than no card")
    func emptySelectionDoesNotOpen() {
        let model = SelectionScopeModel()

        #expect(model.summon(from: context(text: "   ")) == false)
        #expect(model.phase == .hidden)
    }

    @Test("Selected files are named, not counted at the user")
    func filePreviewNamesTheFiles() {
        let model = SelectionScopeModel()
        model.summon(from: context(files: ["/tmp/notes.md", "/tmp/plan.txt"]))

        #expect(model.scope?.kind == .files(count: 2))
        #expect(model.preview == "notes.md, plan.txt")
    }

    @Test("The hotkey toggles: a second press puts it away")
    func toggleClosesWhatItOpened() {
        let model = SelectionScopeModel()
        model.toggle(from: context(text: "hello"))
        #expect(model.phase == .showing)

        model.toggle(from: context(text: "hello"))
        #expect(model.phase == .hidden)
    }

    @Test("An empty question is not a turn")
    func emptyQuestionDoesNotSubmit() {
        let model = SelectionScopeModel()
        model.summon(from: context(text: "hello"))
        model.query = "   "

        #expect(model.submit() == false)
        #expect(model.phase == .showing)
    }

    /// This asserted the opposite — that asking put the card away — with no reason given
    /// for it. From the user's side that reads as Return doing nothing: the card vanishes
    /// and the answer lands in a chat that was never on screen. The card is what says which
    /// selection the answer is about, so it stays while the turn runs.
    @Test("Asking sends the turn and keeps the card up")
    func submitKeepsTheCardUp() {
        let model = SelectionScopeModel()
        model.summon(from: context(text: "hello"))
        model.query = "translate this"

        #expect(model.submit())
        #expect(model.phase == .showing)
        #expect(model.query.isEmpty)
    }

    @Test("Pinning stops the clock; unpinning starts it again")
    func pinningHoldsTheCard() {
        let model = SelectionScopeModel()
        model.summon(from: context(text: "hello"))

        model.togglePin()
        #expect(model.isPinned)

        model.togglePin()
        #expect(model.isPinned == false)
        #expect(model.phase == .showing)
    }
}
