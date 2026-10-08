import CoreGraphics
import Foundation
import Testing
@testable import Context_Dock

/// Which apps fill a window layout's other tiles: the desktop's apps, front to back, each
/// once, read the way the arrangement itself reads the window list.
struct DesktopAppsTests {
    private func window(
        _ bundle: String?, layer: Int = 0, w: CGFloat = 800, h: CGFloat = 600,
        alpha: Double = 1
    ) -> DesktopApps.Window {
        DesktopApps.Window(bundleID: bundle, layer: layer, size: CGSize(width: w, height: h),
            alpha: alpha)
    }

    @Test func eachAppOnceInFrontToBackOrder() {
        let windows = [
            window("com.messages"), window("com.safari"), window("com.messages"),
            window("com.notes"),
        ]
        #expect(
            DesktopApps.ordered(windows, excluding: [], limit: 3)
                == ["com.messages", "com.safari", "com.notes"])
    }

    @Test func leavesOutTheScopedAppAndStopsAtTheTilesLeft() {
        let windows = [window("com.claude"), window("com.safari"), window("com.notes")]
        #expect(
            DesktopApps.ordered(windows, excluding: ["com.claude"], limit: 1) == ["com.safari"])
    }

    @Test func skipsPalettesHiddenWindowsAndOtherLayers() {
        let windows = [
            window("com.palette", w: 100, h: 300),
            window("com.menu", layer: 25),
            window("com.ghost", alpha: 0),
            window(nil),
            window("com.safari"),
        ]
        #expect(DesktopApps.ordered(windows, excluding: [], limit: 3) == ["com.safari"])
    }

    @Test func noTilesLeftMeansNoApps() {
        #expect(DesktopApps.ordered([window("com.safari")], excluding: [], limit: 0).isEmpty)
    }
}
