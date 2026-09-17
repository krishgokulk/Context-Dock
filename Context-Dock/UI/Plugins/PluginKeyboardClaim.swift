// Context-Dock
//
// A plugin's field has the caret. The corner's one key monitor turns a typed letter into
// "bring the field back" while the strip rests as a dock — which is right for the dock and
// wrong the moment someone has clicked into a tile's amount to change it: the "5" went to
// the Global field and the tile never saw it. A plugin field that takes focus says so here,
// the corner passes keys through while it holds, and lets go when the field does.

import Combine
import Foundation

@MainActor
final class PluginKeyboardClaim: ObservableObject {
    static let shared = PluginKeyboardClaim()
    @Published private(set) var isEditing = false

    func fieldFocusChanged(_ focused: Bool) {
        guard isEditing != focused else { return }
        isEditing = focused
    }
}
