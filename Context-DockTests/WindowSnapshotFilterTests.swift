import CoreGraphics
import Foundation
import Testing
@testable import Context_Dock

/// Which of an app's windows the strip's hover row shows, decided on values so the rule
/// can be held without ScreenCaptureKit in the room.
struct WindowSnapshotFilterTests {
    private func window(
        _ id: CGWindowID, bundle: String? = "com.x", title: String = "W",
        w: CGFloat = 800, h: CGFloat = 600, onScreen: Bool = true, layer: Int = 0
    ) -> WindowCandidate {
        WindowCandidate(
            id: id, bundleID: bundle, title: title,
            frame: CGRect(x: 0, y: 0, width: w, height: h), isOnScreen: onScreen, layer: layer)
    }

    @Test func keepsThisAppsNormalWindowsIncludingOnesOnOtherSpaces() {
        let all = [
            window(1), window(2, bundle: "com.y"), window(3, onScreen: false),
            window(4, layer: 25), window(5, w: 40, h: 40), window(6, title: ""),
        ]
        // Off-screen (another Space, minimised) stays; other apps, palettes and tiny
        // windows go.
        #expect(
            AppWindowSnapshotService.eligibleWindows(all, bundleID: "com.x").map(\.id) == [1, 3, 6])
    }

    @Test func dropsTheUntitledWindowsAnAppKeepsAliveOffScreen() {
        // Safari holds an untitled 1148x662 window nobody can see; Claude, being Electron,
        // holds two. Each is layer 0 and past the size floor, so the row drew a black tile
        // labelled "Untitled" beside the real window. A window the user can point at either
        // carries a title or is on screen.
        let all = [
            window(1, title: "Personal — AI / ML Associate", onScreen: false),
            window(2, title: "", w: 1148, h: 662, onScreen: false),
            window(3, title: "", w: 500, h: 500, onScreen: false),
        ]
        #expect(AppWindowSnapshotService.eligibleWindows(all, bundleID: "com.x").map(\.id) == [1])
    }

    @Test func keepsAnUntitledWindowTheUserCanActuallySee() {
        let all = [window(1, title: "", onScreen: true)]
        #expect(AppWindowSnapshotService.eligibleWindows(all, bundleID: "com.x").map(\.id) == [1])
    }

    @Test func keepsFrontToBackOrderAndCapsAtTheLimit() {
        let all = (1...10).map { window(CGWindowID($0)) }
        let kept = AppWindowSnapshotService.eligibleWindows(all, bundleID: "com.x")
        #expect(kept.map(\.id) == [1, 2, 3, 4, 5, 6])
    }

    @Test func rowSizeGrowsWithThumbnails() {
        let one = CornerWindowRowMetrics.size(count: 1)
        let three = CornerWindowRowMetrics.size(count: 3)
        #expect(one.height == three.height)
        let twoMore: CGFloat = 2 * (160 + 8)
        #expect(three.width == one.width + twoMore)
    }
}
