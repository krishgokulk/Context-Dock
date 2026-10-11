import Foundation
import Testing

@testable import Context_Dock

/// A window layout ("Centre") can be pinned to an app's bar (owner 2026-10-08). It is kept
/// as an app action whose id names the layout, so the pin store needs no new kind.
@MainActor
struct WindowLayoutPinTests {
    @Test func aNativeWindowRowNamesItsLayout() {
        #expect(WindowLayoutPin.command(
            trackingIdentifier: "native-window:com.anthropic.claudefordesktop:center")
            == "center")
        #expect(WindowLayoutPin.command(trackingIdentifier: "syscmd-custom:x:y") == nil)
    }

    @Test func theLayoutRoundTripsThroughTheActionID() {
        let id = WindowLayoutPin.actionID("center")
        #expect(WindowLayoutPin.command(actionID: id) == "center")
        // An adapter's own action is not a layout.
        #expect(WindowLayoutPin.command(actionID: "new-window") == nil)
        #expect(WindowLayoutPin.command(actionID: WindowLayoutPin.prefix) == nil)
    }
}
