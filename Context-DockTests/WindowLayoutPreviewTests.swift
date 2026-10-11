import CoreGraphics
import Foundation
import Testing

@testable import Context_Dock

/// A native window-layout row in the Corner's board previews where the window will go
/// (owner 2026-10-07: "show preview of centred window of app").
@MainActor
struct WindowLayoutPreviewTests {
    private func layoutRow(_ command: String, bundleID: String = "com.anthropic.claudefordesktop")
        -> DockPill
    {
        var pill = DockPill(
            id: "native-window-\(bundleID)-\(command)", name: "Centre", icon: "macwindow",
            badge: "Window", execute: {})
        pill.rankingKind = "nativeWindow"
        pill.trackingIdentifier = "native-window:\(bundleID):\(command)"
        return pill
    }

    @Test func aLayoutRowPreviewsItsLayout() {
        let preview = CornerBoardLayout.preview(
            for: .dock(layoutRow("center")), appName: "Claude",
            appBundleID: "com.anthropic.claudefordesktop")
        #expect(
            preview
                == .windowLayout(
                    command: "center", title: "Centre", appName: "Claude",
                    bundleID: "com.anthropic.claudefordesktop"))
    }

    /// A Dock row that is not a layout keeps its old answer.
    @Test func otherDockRowsAreNotLayouts() {
        var pill = layoutRow("center")
        pill.rankingKind = "menu"
        #expect(CornerBoardLayout.windowLayoutPreview(for: pill, appName: "", appBundleID: "") == nil)
        var unknown = layoutRow("not-a-layout")
        unknown.rankingKind = "nativeWindow"
        #expect(CornerBoardLayout.windowLayoutPreview(for: unknown, appName: "", appBundleID: "") == nil)
    }

    /// The regions moved out of the Dock unchanged: Centre is one window in the middle,
    /// Quarters four cells, Left & Right two halves.
    @Test func theRegionsAreTheDocks() {
        #expect(WindowManagementService.Command.center.layoutRegions
            == [CGRect(x: 0.18, y: 0.16, width: 0.64, height: 0.68)])
        #expect(WindowManagementService.Command.quarters.layoutRegions.count == 4)
        #expect(WindowManagementService.Command.leftAndRight.layoutRegions.map(\.width) == [0.5, 0.5])
    }
}
