import Foundation
import Testing

@testable import Context_Dock

/// The clipboard in the shell's result board (owner 2026-10-07): opened by the hotkey or an
/// icon, filtered by the field, walked with the arrows, and never raised by a copy.
@MainActor
struct ClipboardBoardTests {
    private func entry(
        _ text: String = "", files: [String] = [], image: Bool = false,
        app: String = "Notes", at date: Date = Date()
    ) -> LauncherView.ClipboardEntry {
        LauncherView.ClipboardEntry(
            text: text, timestamp: date, filePaths: files,
            imageFileName: image ? "clip.png" : nil,
            sourceAppName: app, sourceBundleId: "com.example.\(app.lowercased())")
    }

    /// A store nobody else writes, so `openBoard`'s reload finds nothing on disk.
    private func model() -> ClipboardPanelModel {
        ClipboardPanelModel(
            storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("clipboard-board-\(UUID().uuidString).json"))
    }

    // MARK: Kinds and the type filter

    @Test func eachClipIsTheKindItLooksLike() {
        #expect(ClipboardClipInfo.kind(of: entry("hello there")) == .text)
        #expect(ClipboardClipInfo.kind(of: entry("https://example.com/a?b=1")) == .link)
        #expect(ClipboardClipInfo.kind(of: entry(image: true)) == .image)
        #expect(ClipboardClipInfo.kind(of: entry(files: ["/tmp/report.pdf"])) == .file)
        // A copied picture file is an image, as Raycast's "Images Only" shows it.
        #expect(ClipboardClipInfo.kind(of: entry(files: ["/tmp/wallpaper.png"])) == .image)
    }

    /// Prose that mentions a link is still text.
    @Test func aSentenceWithALinkIsNotALink() {
        #expect(!ClipboardClipInfo.isLink("see https://example.com for more"))
        #expect(!ClipboardClipInfo.isLink("example.com"))
        #expect(ClipboardClipInfo.isLink("  http://example.com/path  "))
    }

    @Test func theTypeFilterNarrowsTheList() {
        let board = model()
        board.entries = [
            entry("note"), entry("https://example.com"), entry(image: true),
            entry(files: ["/tmp/a.pdf"]),
        ]

        board.setKind(.images)
        #expect(board.visibleEntries.count == 1)
        board.setKind(.links)
        #expect(board.visibleEntries.map(\.text) == ["https://example.com"])
        board.setKind(.all)
        #expect(board.visibleEntries.count == 4)
    }

    @Test func tabWalksTheTypesAndWraps() {
        let board = model()
        board.cycleKind(1)
        #expect(board.kindFilter == .text)
        board.cycleKind(-1)
        board.cycleKind(-1)
        #expect(board.kindFilter == .links)
    }

    // MARK: Opening, filtering, closing

    /// The newest clip is chosen as the board opens, so its preview is up and Return
    /// pastes it.
    @Test func openingChoosesTheNewestClip() {
        let board = model()
        board.openBoard()
        board.ingest(entry("older"))
        board.ingest(entry("newest"))
        board.setBoardQuery("")

        #expect(board.isBoardOpen)
        #expect(board.focusedEntry?.text == "newest")
    }

    @Test func typingChoosesTheTopMatch() {
        let board = model()
        board.openBoard()
        board.ingest(entry("apple pie"))
        board.ingest(entry("banana"))
        board.moveEntry(1)

        board.setBoardQuery("apple")

        #expect(board.visibleEntries.map(\.text) == ["apple pie"])
        #expect(board.focusedEntryIndex == 0)
    }

    @Test func closingForgetsTheFilters() {
        let board = model()
        board.openBoard()
        board.setBoardQuery("x")
        board.setKind(.images)

        board.closeBoard()

        #expect(!board.isBoardOpen)
        #expect(board.query.isEmpty)
        #expect(board.kindFilter == .all)
    }

    /// A copy shows the icon for a moment and raises nothing (owner 2026-10-07).
    @Test func aCopyRaisesNoCard() {
        let board = model()
        board.noteCopy(dwell: 60)

        #expect(board.recentlyCopied)
        #expect(board.showsDockIcon)
        #expect(board.phase == .hidden)
        #expect(!board.isBoardOpen)
    }

    // MARK: Keys

    private func key(
        _ code: UInt16, command: Bool = false, shift: Bool = false, filterEmpty: Bool = true
    ) -> ClipboardBoardKey? {
        ClipboardBoardKey.action(
            keyCode: code, command: command, shift: shift, option: false, control: false,
            filterEmpty: filterEmpty)
    }

    @Test func theBoardsKeys() {
        #expect(key(53) == .back)
        #expect(key(53, filterEmpty: false) == .clearFilter)
        #expect(key(125) == .move(1, selecting: false))
        #expect(key(126, shift: true) == .move(-1, selecting: true))
        #expect(key(36) == .paste)
        #expect(key(36, command: true) == .copy)
        #expect(key(48) == .cycleKind(1))
        #expect(key(48, shift: true) == .cycleKind(-1))
        #expect(key(51, command: true) == .delete)
        #expect(key(16, command: true) == .quickLook)
        #expect(key(35, command: true) == .togglePin)
        #expect(key(43, command: true) == .settings)
        // Without ⌘ they are letters for the filter.
        #expect(key(35) == nil)
        #expect(key(43) == nil)
    }

    /// The footer's app pills narrow the list to one app and choose its newest clip.
    @Test func anAppPillNarrowsTheList() {
        let board = model()
        board.openBoard()
        board.ingest(entry("from notes", app: "Notes"))
        board.ingest(entry("from mail", app: "Mail"))

        board.setBoardSource(bundleID: "com.example.notes")

        #expect(board.visibleEntries.map(\.text) == ["from notes"])
        #expect(board.focusedEntryIndex == 0)
        board.setBoardSource(bundleID: "")
        #expect(board.visibleEntries.count == 2)
    }

    /// With something typed, ← and Backspace belong to the filter's text.
    @Test func editingTheFilterIsNotLeaving() {
        #expect(key(51) == .back)
        #expect(key(51, filterEmpty: false) == nil)
        #expect(key(123) == .back)
        #expect(key(123, filterEmpty: false) == nil)
        // Letters are the field's.
        #expect(key(0) == nil)
        #expect(
            ClipboardBoardKey.action(
                keyCode: 125, command: false, shift: false, option: true, control: false,
                filterEmpty: true) == nil)
    }

    // MARK: What the board says

    @Test func theListIsGroupedByDay() {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let sections = ClipboardBoardSection.group(
            [entry("a", at: now), entry("b", at: now), entry("c", at: yesterday)], now: now)

        #expect(sections.map(\.title) == ["Today", "Yesterday"])
        #expect(sections[0].rows.map(\.index) == [0, 1])
        #expect(sections[1].rows.map(\.index) == [2])
    }

    @Test func titlesNameTheClip() {
        let size = CGSize(width: 1200, height: 1000)
        #expect(ClipboardClipInfo.title(of: entry(image: true), pixelSize: size) == "Image (1200 × 1000)")
        #expect(
            ClipboardClipInfo.title(of: entry(files: ["/tmp/magic.png"]), pixelSize: CGSize(width: 640, height: 360))
                == "magic.png (640 × 360)")
        #expect(ClipboardClipInfo.title(of: entry("first line\nsecond")) == "first line")
    }

    @Test func theInformationSection() {
        let image = ClipboardClipInfo.details(
            of: entry(files: ["/tmp/wallpaper.png"], app: "Finder"),
            pixelSize: CGSize(width: 842, height: 420))
        #expect(image.map(\.label) == ["Application", "Content Type", "Path", "Dimensions", "Copied"])
        #expect(image[0].value == "Finder")
        #expect(image[1].value == "Image")
        #expect(image[3].value == "842 × 420")

        let text = ClipboardClipInfo.details(of: entry("two words"))
        #expect(text.map(\.label) == ["Application", "Content Type", "Characters", "Words", "Copied"])
        #expect(text[2].value == "9")
        #expect(text[3].value == "2")
    }

    // MARK: The field it stands over

    /// The board is a deliberate ask: the field does not idle away under it.
    @Test func theFieldStaysWhileTheBoardIsOpen() {
        let prompt = AppChatPromptModel()
        prompt.clipboardBoard = model()
        prompt.summon(app: "TextEdit", bundleID: "com.apple.TextEdit")
        prompt.clipboardBoard.openBoard()

        prompt.standDown()

        #expect(prompt.phase == .prompt)
        #expect(prompt.isClipboardScope)
    }

    /// The field going takes the board with it.
    @Test func dismissingTheFieldClosesTheBoard() {
        let prompt = AppChatPromptModel()
        prompt.clipboardBoard = model()
        prompt.summon(app: "TextEdit", bundleID: "com.apple.TextEdit")
        prompt.clipboardBoard.openBoard()

        prompt.dismiss()

        #expect(!prompt.isClipboardScope)
    }
}
