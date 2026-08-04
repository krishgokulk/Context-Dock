import SwiftUI

/// Shared size and animation rules for the unified dock.
///
/// The dock is one shell showing different content per mode, so its measurements and motion
/// have to come from one place. They had drifted: row height existed as 52, 58 and 66 in four
/// files, and 164 animation call sites used 42 distinct spring curves. Nothing was wrong with
/// any single value — the problem was that "the dock's row height" and "the dock's animation"
/// were not things anyone could change.
///
/// Every value here is the value that was already in use. This file moves them, it does not
/// retune them, so adopting it changes no pixels and no timing.
enum DockMetrics {

    // MARK: - Rows
    //
    // Three row heights, because there are three row renderings — not because they drifted.
    // Naming them makes the difference deliberate and visible instead of a number repeated in
    // a formula, which is how the global list ended up estimating 52 for rows that render
    // taller and clipping its last row.

    /// Global Context list rows (app matches, menu commands, global commands).
    static let globalListRow: CGFloat = 52
    /// L1 result rows in the results sheet.
    static let l1ResultRow: CGFloat = 58
    /// Finder / search result panel rows, which carry a subtitle and a larger icon.
    static let searchPanelRow: CGFloat = 66

    /// Space a list reserves for its section header.
    static let listHeaderReserve: CGFloat = 24
    /// Vertical padding around list content.
    static let listContentPadding: CGFloat = 12
    /// Shortest a populated list may be, so one result never renders as a sliver.
    static let listMinHeight: CGFloat = 86

    /// Estimated height for a Global Context list before its rows are measured.
    ///
    /// An estimate is a fallback, not the truth: the rendered list reports its real height
    /// through `updateMeasuredGlobalListHeight`, and that value wins wherever it exists.
    static func globalListEstimatedHeight(
        rowCount: Int,
        includesHeader: Bool = true,
        maximum: CGFloat
    ) -> CGFloat {
        let header = includesHeader ? listHeaderReserve : 0
        let content = CGFloat(rowCount) * globalListRow + header + listContentPadding
        return min(max(content, listMinHeight), maximum)
    }
}

/// Named dock animations.
///
/// These are the curves already in the code, kept exactly: adopting a token is a rename, not a
/// retune. The point is that the dock's motion becomes one thing that can be adjusted, rather
/// than 42 near-identical springs — several of which differ by 0.02 damping and cannot be told
/// apart by eye.
extension Animation {
    /// The dock's default: rows appearing, chips changing, most state changes.
    static let dockStandard = Animation.spring(response: 0.22, dampingFraction: 0.84)
    /// Slightly softer landing, for content that settles rather than snaps.
    static let dockSoft = Animation.spring(response: 0.22, dampingFraction: 0.86)
    /// Crisper, for small immediate feedback.
    static let dockCrisp = Animation.spring(response: 0.22, dampingFraction: 0.78)
    /// Larger movements — sheet expansion, mode changes — where a longer response reads as
    /// deliberate rather than sluggish.
    static let dockSheet = Animation.spring(response: 0.3, dampingFraction: 0.75)
}
