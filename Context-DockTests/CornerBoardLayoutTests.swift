// Context-DockTests/CornerBoardLayoutTests.swift
//
// The split result board (#191): the list stays over the field at the field's width, and the
// highlighted row's panel opens beside it — a file's preview, an app, a menu command.

import AppKit
import Foundation
import Testing

@testable import Context_Dock

@Suite("Split result board")
@MainActor
struct CornerBoardLayoutTests {
    typealias L = CornerBoardLayout

    private func doc(
        _ id: String, title: String = "T", bundleId: String = "", filePath: String? = nil,
        action: GlobalSearchService.ActionSpec
    ) -> GlobalSearchService.SearchDocument {
        GlobalSearchService.SearchDocument(
            id: id, title: title, subtitle: "", bundleId: bundleId, filePath: filePath,
            normalizedTitle: title.lowercased(), titleWords: [title.lowercased()],
            acronym: "t", aliases: [], aliasWords: [], sourceKind: .installed,
            rankingBoost: 0, icon: nil, usageTrackingKey: id, action: action)
    }

    @Test("No highlighted row, no panel")
    func nothingHighlightedShowsNoPanel() {
        #expect(L.preview(for: nil) == nil)
        let list = CGSize(width: 600, height: 230)
        #expect(L.boardSize(list: list, preview: nil) == list)
        #expect(L.anchorOffset(board: list, preview: nil) == nil)
    }

    @Test("A file, a folder and an image preview as files")
    func filesPreviewAsFiles() {
        let file = URL(fileURLWithPath: "/tmp/report.pdf")
        #expect(L.preview(for: .file(file)) == .file(file))
        let folder = URL(fileURLWithPath: "/Users/x/Documents")
        #expect(L.preview(for: .file(folder)) == .file(folder))
        // A Global result standing for a file.
        let image = doc("img", filePath: "/tmp/photo.png", action: .launchPath("/tmp/photo.png"))
        #expect(L.preview(for: .global(image)) == .file(URL(fileURLWithPath: "/tmp/photo.png")))
        // A Dock row whose path is a file.
        var pill = DockPill(id: "p", name: "notes.md", icon: "doc", badge: nil, execute: {})
        pill.previewPath = "/tmp/notes.md"
        #expect(L.preview(for: .dock(pill)) == .file(URL(fileURLWithPath: "/tmp/notes.md")))
    }

    @Test("An app previews as the app, never as its bundle on disk")
    func appsPreviewAsApps() {
        let safari = doc(
            "com.apple.Safari", title: "Safari", bundleId: "com.apple.Safari",
            filePath: "/Applications/Safari.app",
            action: .launchBundleId("com.apple.Safari", path: "/Applications/Safari.app"))
        #expect(L.preview(for: .global(safari)) == .app(bundleID: "com.apple.Safari", name: "Safari"))
        let running = doc(
            "run", title: "Notes",
            action: .activatePID(42, bundleId: "com.apple.Notes", path: nil))
        #expect(L.preview(for: .global(running)) == .app(bundleID: "com.apple.Notes", name: "Notes"))
        // The Corner's Global rows are the Dock's pills: resolved through their document.
        var pill = DockPill(id: "d", name: "Safari", icon: "app", badge: nil, execute: {})
        pill.searchDocumentID = "com.apple.Safari"
        #expect(
            L.preview(for: .dock(pill), lookup: { $0 == "com.apple.Safari" ? safari : nil })
                == .app(bundleID: "com.apple.Safari", name: "Safari"))
    }

    @Test("A menu command previews as where it lives")
    func commandsPreviewTheirPath() {
        let menu = doc(
            "m", title: "Duplicate",
            action: .cachedMenu(
                bundleId: "com.apple.TextEdit", appName: "TextEdit",
                path: ["File", "Duplicate"], shortcutChar: "s", shortcutModifiers: 1))
        #expect(
            L.preview(for: .global(menu))
                == .command(
                    title: "Duplicate", path: ["File", "Duplicate"], appName: "TextEdit",
                    bundleID: "com.apple.TextEdit"))
    }

    @Test("Rows with nothing to show take no panel")
    func actionsAndToolsTakeNoPanel() {
        #expect(L.preview(for: .cliSuggestion("status")) == nil)
        let cli = doc("cli://git", action: .cliScope(command: "git", displayName: "git"))
        #expect(L.preview(for: .global(cli)) == nil)
        let bare = DockPill(id: "b", name: "Sleep", icon: "moon", badge: nil, execute: {})
        #expect(L.preview(for: .dock(bare)) == nil)
    }

    @Test("The panel widens the board beside the list; the list keeps the field's width")
    func thePanelSitsBesideTheList() {
        let list = CGSize(width: 600, height: 230)
        let preview = CornerBoardPreview.file(URL(fileURLWithPath: "/tmp/a.pdf"))
        let board = L.boardSize(list: list, preview: preview)
        #expect(board.height == list.height)
        #expect(board.width == list.width + L.gap + L.panelWidth)

        // Placed by the window: the board's leading edge — the list's — on the field's.
        let prompt = CGSize(width: 600, height: 56)
        for anchor in CornerDockAnchor.allCases {
            let slots = CornerDockLayout.slots(
                list: board, prompt: prompt,
                listAnchorOffset: L.anchorOffset(board: board, preview: preview),
                anchor: anchor, panelWidth: 3000)
            guard let listRect = slots.list, let promptRect = slots.prompt else {
                Issue.record("no slots for \(anchor)")
                continue
            }
            if anchor == .right {
                // Against the right edge the board steps left to stay on the screen.
                #expect(listRect.maxX <= 3000 - CornerDockLayout.pad)
                #expect(listRect.minX <= promptRect.minX)
            } else {
                #expect(listRect.minX == promptRect.minX, "anchor \(anchor)")
            }
            #expect(listRect.width == board.width)
        }
    }

    @Test("The model's panel follows the arrows and the window reserves the same board")
    func theModelFollowsTheHighlight() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        #expect(model.boardPreview == nil)
        #expect(model.boardSize == AppChatListMetrics.size(
            rows: model.listRowCount, width: AppChatPromptMetrics.boardWidth(for: model)))
    }
}
