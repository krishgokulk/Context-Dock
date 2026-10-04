// Context-DockTests/DropShelfRowTests.swift
//
// The Drop Shelf is the last item of every dock row (issue #147): in the Dock and the
// Corner, in every scope, with or without pins. The rule is one pure function the strip draws
// from and the shell is measured by; the keys reach it as the row's last pill.
//
// Hermetic: no process-wide singleton is driven. Presentations are private instances and
// shelf stores sit in temporary directories.

import AppKit
import Foundation
import Testing

@testable import Context_Dock

@Suite("Drop Shelf — the end of the dock row")
@MainActor
struct DropShelfRowTests {

    typealias M = AppChatPromptMetrics

    @Test("An empty scope's row is the shelf and nothing else")
    func anEmptyScopeStillHasTheShelf() {
        let row = DockTools.row(
            showsTabBar: false, clipboard: false, selection: false, feedback: false)
        #expect(row == [.shelf])
    }

    @Test("A scope with everything showing still ends with the shelf")
    func aBusyScopeEndsWithTheShelf() {
        let row = DockTools.row(
            showsTabBar: false, clipboard: true, selection: true, feedback: true)
        #expect(row == [.clipboard, .selection, .feedback, .shelf])
        #expect(row.last == .shelf)
    }

    @Test("An app's bar keeps no action result, and still ends with the shelf")
    func anAppBarEndsWithTheShelf() {
        let row = DockTools.row(
            showsTabBar: true, clipboard: true, selection: true, feedback: true)
        #expect(row == [.clipboard, .selection, .shelf])
    }

    @Test("Whatever else shows, the shelf is last and there is exactly one")
    func theShelfIsAlwaysLastAndAlone() {
        for tabBar in [false, true] {
            for clipboard in [false, true] {
                for selection in [false, true] {
                    for feedback in [false, true] {
                        let row = DockTools.row(
                            showsTabBar: tabBar, clipboard: clipboard, selection: selection,
                            feedback: feedback)
                        #expect(row.last == .shelf)
                        #expect(row.filter { $0 == .shelf }.count == 1)
                    }
                }
            }
        }
    }

    @Test("Global with nothing pinned and nothing running still measures a row for the shelf")
    func theEmptyStripIsMeasuredForTheShelf() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summonGlobalContext()

        let tools = model.dockToolCount(clipboardVisible: false)
        #expect(tools == 1)
        #expect(model.dockTools(clipboardVisible: false) == [.shelf])

        // The strip is wider for it: a divider and one icon past what it was.
        let without = M.dockLayout(running: 0, pinned: 0, tools: 0)
        let with = M.dockLayout(running: 0, pinned: 0, tools: tools)
        #expect(with.tools == 1)
        #expect(with.width == without.width + M.dockDividerSpan + M.dockIconSize)
    }

    @Test("A pinned scope's row ends with the shelf, after the pins")
    func aPinnedScopeEndsWithTheShelf() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summonGlobalContext()

        let tools = model.dockToolCount(clipboardVisible: true)
        #expect(model.dockTools(clipboardVisible: true).last == .shelf)

        // Pinned items are never dropped to make room: the layout keeps all of them and
        // counts the shelf among the tools after them.
        let layout = M.dockLayout(running: 4, pinnedApps: 2, pinned: 3, tools: tools)
        #expect(layout.tools == tools)
        #expect(tools >= 2)
    }

    // MARK: Keyboard: the shelf is the row's last pill

    private static func icon(_ id: String) -> MatchDockIcon {
        MatchDockIcon(
            id: id, bundleID: id, title: id, icon: NSImage(), isRunning: true,
            isExpandable: false, score: 0, isExactAppPrefix: false)
    }

    @Test("With no app running the pill row is just the shelf, and Tab reaches it")
    func tabReachesTheShelfWhenNothingElseIsThere() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summonGlobalContext()
        model.setGlobalTyping(top: nil, running: [])
        let shelf = DropShelfPresentation()

        #expect(model.pillRowIsAvailable)
        #expect(model.applyPillRowKey(.tab, shelf: shelf))
        #expect(model.isShelfFocused)
        #expect(model.focusedPill == nil)
        // Tab again leaves the row, as it does after any pill.
        #expect(model.applyPillRowKey(.tab, shelf: shelf))
        #expect(model.focusedPillIndex == nil)
    }

    @Test("Return on the focused shelf opens it, as a click does; again closes it")
    func returnTogglesTheShelf() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summonGlobalContext()
        model.setGlobalTyping(top: nil, running: ["a", "b"].map(Self.icon))
        let shelf = DropShelfPresentation()

        // Tab, → → : a, b, then the shelf.
        #expect(model.applyPillRowKey(.tab, shelf: shelf))
        #expect(model.applyPillRowKey(.right, shelf: shelf))
        #expect(model.applyPillRowKey(.right, shelf: shelf))
        #expect(model.isShelfFocused)

        #expect(model.applyPillRowKey(.returnKey, shelf: shelf))
        #expect(shelf.phase == .expanded)
        #expect(model.focusedPillIndex == nil)

        #expect(model.applyPillRowKey(.tab, shelf: shelf))
        #expect(model.applyPillRowKey(.left, shelf: shelf))
        #expect(model.applyPillRowKey(.right, shelf: shelf))
        #expect(model.isShelfFocused)
        #expect(model.applyPillRowKey(.returnKey, shelf: shelf))
        #expect(shelf.phase == .collapsed)
    }

    @Test("Return on an app pill still opens the app and leaves the shelf alone")
    func returnOnAnAppIsNotTheShelf() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summonGlobalContext()
        model.setGlobalTyping(top: nil, running: ["a"].map(Self.icon))
        let shelf = DropShelfPresentation()

        #expect(model.applyPillRowKey(.tab, shelf: shelf))
        #expect(model.focusedPill?.id == "a")
        #expect(!model.isShelfFocused)
        #expect(model.applyPillRowKey(.returnKey, shelf: shelf))
        #expect(shelf.phase == .collapsed)
    }
}

// MARK: - What a drop files

@Suite("Drop Shelf — a drop from item providers")
@MainActor
struct DropShelfProviderIngestTests {
    private let app = (name: "Finder", bundleId: "com.apple.finder")

    private func store() -> DropShelfStore {
        DropShelfStore(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("shelf-\(UUID().uuidString)"))
    }

    private func file(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("src-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? "x".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func aDroppedFileIsFiledAndItsPathAsTextIsNot() {
        let store = store()

        // A dragged file also offers its own path as text: reading that would file a note
        // about the file instead of the file.
        let taken = store.ingest(
            urls: [file("passports.csv")], text: "/tmp/passports.csv", source: app)

        #expect(taken == 1)
        #expect(store.items.map(\.originalName) == ["passports.csv"])
    }

    @Test func droppedTextBecomesAFileOfItsOwn() {
        let store = store()

        let taken = store.ingest(urls: [], text: "remember the milk", source: app)

        #expect(taken == 1)
        #expect(store.items.first?.kind == .text)
    }

    @Test func aDroppedLinkBecomesAWebloc() throws {
        let store = store()

        let taken = store.ingest(
            urls: [try #require(URL(string: "https://example.com/page"))], text: nil,
            source: app)

        #expect(taken == 1)
        #expect(store.items.first?.kind == .links)
    }

    @Test func nothingDroppedFilesNothing() {
        let store = store()

        #expect(store.ingest(urls: [], text: nil, source: app) == 0)
        #expect(store.ingest(urls: [], text: "  \n", source: app) == 0)
        #expect(store.items.isEmpty)
    }
}
