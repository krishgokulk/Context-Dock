import AppKit
import Foundation
import Testing

@testable import Context_Dock

/// The card above a hovered pin: how big it is, and where it opens.
@MainActor
struct DockPinPreviewTests {
    private func pin(_ kind: DockPinKind, _ title: String, order: Int) -> DockPin {
        DockPin(id: UUID(), kind: kind, title: title, order: order, documentID: nil)
    }

    private func icon(_ bundleID: String, _ title: String) -> MatchDockIcon {
        MatchDockIcon(
            id: "app:\(bundleID)", bundleID: bundleID, title: title, icon: NSImage(),
            isRunning: true, isExpandable: true, score: 1, isExactAppPrefix: false)
    }

    @Test func aFolderCardIsTheBrowsersOwnWindow() {
        // Folders are handed to PreviewFolderBrowser, which brings its own list, grid and
        // footer — so the card is a window, not a height counted from rows.
        let size = DockPinPreviewMetrics.size(
            for: .folder(DockPinPreview.FolderDetail(path: "/tmp", name: "tmp")))
        #expect(size == DockPinPreviewMetrics.folder)
    }

    @Test func aFileCardMakesRoomForItsThumbnailAndTwoLines() {
        let size = DockPinPreviewMetrics.size(
            for: .file(
                DockPinPreview.FileDetail(
                    path: "/tmp/a.pdf", name: "a.pdf", kindName: "PDF document",
                    byteCount: 100, modified: nil)))
        #expect(size.height > DockPinPreviewMetrics.thumb.height)
        #expect(size.width == DockPinPreviewMetrics.width)
    }

    @Test func aFileLineDropsWhatTheDiskDidNotAnswer() {
        let bare = DockPinPreview.FileDetail(
            path: "/tmp/a.pdf", name: "a.pdf", kindName: "PDF document", byteCount: nil,
            modified: nil)
        #expect(CornerPinPreviewCard.fileDetailLine(bare) == "PDF document")

        let sized = DockPinPreview.FileDetail(
            path: "/tmp/a.pdf", name: "a.pdf", kindName: "PDF document", byteCount: 2_400_000,
            modified: nil)
        #expect(CornerPinPreviewCard.fileDetailLine(sized).hasPrefix("PDF document · "))
    }

    // MARK: Where the card opens

    private func plan(apps: [MatchDockIcon], pins: [DockPin]) -> DockStripPlan {
        DockStripPlan.make(
            running: apps, pins: pins, runningBundleIDs: [], unresolvedDocumentIDs: [],
            tools: 0)
    }

    @Test func theCardOpensOverTheIconItIsAbout() {
        // The card used to be centred on the dock whatever the pointer was over. The offset
        // walks the row exactly as the strip builds it: field, apps, divider, pins.
        typealias M = AppChatPromptMetrics
        let apps = [icon("com.a", "A"), icon("com.b", "B")]
        let made = plan(apps: apps, pins: [])

        let first = made.iconCenterOffset(for: .app(bundleID: "com.a"))
        let second = made.iconCenterOffset(for: .app(bundleID: "com.b"))
        // The folded field holds the first slot, so the first app is the second icon.
        #expect(first == M.dockInset + 1.5 * M.dockIconSize + M.dockIconGap)
        #expect(second == first! + M.dockIconSize + M.dockIconGap)
    }

    @Test func aPinnedFilesCardClearsTheDividerTheStripDraws() {
        typealias M = AppChatPromptMetrics
        let file = pin(.file(path: "/tmp/a.pdf"), "a.pdf", order: 0)
        let made = plan(apps: [icon("com.a", "A")], pins: [file])

        let app = made.iconCenterOffset(for: .app(bundleID: "com.a"))!
        let pinned = made.iconCenterOffset(for: .pin(id: file.id))!
        // One icon, then the hairline and the gap on each side of it.
        #expect(pinned - app == M.dockIconSize + M.dockIconGap + 1 + M.dockIconGap)
    }

    @Test func aPinnedAppIsFoundInTheAppRegionWhereItIsDrawn() {
        let safari = pin(.app(bundleID: "com.apple.Safari"), "Safari", order: 0)
        let made = plan(apps: [icon("com.apple.Safari", "Safari")], pins: [safari])

        // Hovering it reports .app, and it is the only icon drawn for that app.
        #expect(made.iconCenterOffset(for: .app(bundleID: "com.apple.Safari")) != nil)
        #expect(made.iconCenterOffset(for: .pin(id: safari.id)) != nil)
        #expect(
            made.iconCenterOffset(for: .app(bundleID: "com.apple.Safari"))
                == made.iconCenterOffset(for: .pin(id: safari.id)))
    }

    @Test func anIconThatIsNotDrawnHasNowhereToOpenOver() {
        let made = plan(apps: [icon("com.a", "A")], pins: [])
        #expect(made.iconCenterOffset(for: .app(bundleID: "com.gone")) == nil)
        #expect(made.iconCenterOffset(for: .pin(id: UUID())) == nil)
    }

    @Test func theSlotLandsOverTheIconNotOverTheMiddleOfTheDock() {
        // What the screenshot showed: the card sat mid-dock however far left the icon was.
        let dock = CGSize(width: 520, height: 68)
        let card = CGSize(width: 260, height: 200)
        let overFirstIcon = CornerDockLayout.slots(
            list: card, prompt: dock, listAnchorOffset: 82, anchor: .center, panelWidth: 1400)
        let centred = CornerDockLayout.slots(
            list: card, prompt: dock, anchor: .center, panelWidth: 1400)

        let anchored = try! #require(overFirstIcon.list)
        let plain = try! #require(centred.list)
        let promptRect = try! #require(overFirstIcon.prompt)
        #expect(anchored.midX == promptRect.minX + 82)
        #expect(anchored.midX < plain.midX)
    }

    @Test func aCardNearTheEdgeStaysOnThePanel() {
        // Anchoring is clamped: half a card off-screen is worse than one not quite over
        // its icon.
        let card = CGSize(width: 360, height: 320)
        let slots = CornerDockLayout.slots(
            list: card, prompt: CGSize(width: 520, height: 68), listAnchorOffset: 8,
            anchor: .center, panelWidth: 1000)
        let rect = try! #require(slots.list)
        #expect(rect.minX >= 0)
        #expect(rect.maxX <= 1000)
    }
}
