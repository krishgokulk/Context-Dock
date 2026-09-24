import Combine
import Foundation

/// What can be done with the selection the corner's card is showing — the Dock's own
/// Selection Scope rows, run by the Dock's own executor.
///
/// The card used to show the selection and a field, and nothing to act on it with: the
/// corner took over *showing* the selection but not *acting* on it, and acting on it is
/// Selection Scope's whole job (`docs/master/00-DOCK-AND-CORNER.md` §4a). Those rows are
/// built inside `LauncherView` from its frozen `selectionScopePayload`, by a dozen builders
/// that read its state. Rather than a second ranking in the corner, the card hands the Dock
/// its selection while it is up and asks the Dock for the rows — the same bridge
/// `GlobalContextResultSource` is for Global Context, and the same decision as the corner's
/// App Chat rendering the Dock's conversation instead of running its own engine.
///
/// The Dock fills these in on appear (`connectCornerSelectionActions`). Nil closures mean no
/// Dock is connected — the card then shows no rows and asking still works.
@MainActor
final class SelectionActionSource {
    static let shared = SelectionActionSource()

    /// Make this selection the Dock's frozen Selection Scope payload, or clear it with nil.
    var adopt: ((GlobalContextActivation?) -> Void)?
    /// The Dock's Selection Scope rows for a query, in the Dock's order, excluding its own
    /// "Ask AI" row — the card's field is the ask.
    var actions: ((String) -> [DockPill])?
    /// Run one of those rows exactly as the Dock would.
    var run: ((DockPill) -> Void)?
}
