import AppKit
import SwiftUI

extension LauncherView {
    /// True once the window stopped being sized from content. The stabilizers below all
    /// exist to referee the old race between the window frame and the card; under a fixed
    /// host there is no race, and every one of them now only delays the card.
    var dockUsesFixedHost: Bool { false }

    func requestWindowSizeUpdate(
        reason: DockResizeReason,
        animated: Bool = true,
        debounceNanoseconds: UInt64 = 50_000_000
    ) {
        // ponytail: no launcher window since #257 E3; callers go in E4.
        syncScopeChatSpaceHold()
    }


    func updateWindowSize(
        animated: Bool = true,
        debounceNanoseconds: UInt64 = 50_000_000
    ) {
        // ponytail: no launcher window since #257 E3; callers go in E4.
    }
}
