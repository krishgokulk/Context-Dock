import Foundation
import Testing

@testable import Context_Dock

// A browser's History menu holds two kinds of item, and they are handled in opposite ways.
//
// Page rows (a recently closed page, a history entry) sit in a submenu that scrolls and
// reorders, so they open by URL and must never be AX-clicked, and the cache forgets them once
// no live scan confirms them. Commands at fixed places (Reopen Last Closed Window, the Recently
// Closed submenu itself) are as durable as File ▸ New Window and belong in menu results.
//
// Treating the whole History menu as volatile hid the commands; treating the commands' rule as
// the rows' rule would start AX-clicking a scrolling submenu. These pin both sides.

@MainActor
struct BrowserHistoryMenuRowsTests {

    private let view = LauncherView()

    private func descriptor(_ path: [String], bundleID: String = "com.apple.Safari")
        -> GlobalMenuDescriptor
    {
        GlobalMenuDescriptor(
            id: path.joined(separator: ">"), name: path.last ?? "", badge: nil,
            statusBadge: nil, bundleID: bundleID, appName: "Safari", appIcon: nil,
            path: path, shortcutChar: nil, shortcutModifiers: 0, rankingScore: 0)
    }

    /// A recently closed page still opens by URL and is never AX-clicked.
    @Test func recentlyClosedPageRowsStayURLRows() {
        let rows: [[String]] = [
            ["History", "Recently Closed", "Apple"],
            ["History", "Recently Closed", "GitHub · Build software better"],
            ["History", "Apple"],
        ]
        for path in rows {
            #expect(
                view.isBrowserURLMenuRow(descriptor(path)),
                "\(path.joined(separator: " ▸ ")) would be AX-clicked")
            #expect(
                view.isVolatileCachedMenuPath(path),
                "\(path.joined(separator: " ▸ ")) would outlive the page it names")
        }
    }

    /// Commands at fixed places under History are not page rows and are not volatile, so
    /// they stay in menu results in both shells.
    @Test func stableHistoryCommandsShowInResults() {
        let commands: [[String]] = [
            ["History", "Reopen Last Closed Window"],
            ["History", "Reopen All Windows from Last Session"],
            ["History", "Recently Closed"],
            ["History", "Clear History…"],
            ["History", "Forward"],
        ]
        for path in commands {
            #expect(
                !view.isBrowserURLMenuRow(descriptor(path)),
                "\(path.joined(separator: " ▸ ")) is a command, not a page")
            #expect(
                !view.isVolatileCachedMenuPath(path),
                "\(path.joined(separator: " ▸ ")) would drop out of results")
        }
    }

    /// Titles are matched after punctuation is dropped, so "Clear History…" and
    /// "Clear History..." are the same command.
    @Test func stableTitlesIgnorePunctuation() {
        #expect(BrowserStableMenuCommand.isStable(title: "Clear History…"))
        #expect(BrowserStableMenuCommand.isStable(title: "Clear History..."))
        #expect(BrowserStableMenuCommand.isStable(title: "Add Bookmark…"))
        #expect(!BrowserStableMenuCommand.isStable(title: "Apple"))
    }
}
