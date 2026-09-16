import CoreGraphics
import Foundation

/// Every place a window can be snapped to — the same catalogue a window manager offers from
/// shortcuts, here offered as drop targets while a thumbnail is dragged. Pure: a layout and
/// a screen in, a frame out. Coordinates are top-left origin, as AX reports them.
enum SnapLayout: String, CaseIterable, Identifiable, Sendable {
    // Halves
    case leftHalf, rightHalf, centerHalf, topHalf, bottomHalf
    // Quarters
    case topLeft, topRight, bottomLeft, bottomRight
    // Thirds
    case firstThird, centerThird, lastThird, firstTwoThirds, centerTwoThirds, lastTwoThirds
    // Fourths
    case firstFourth, secondFourth, thirdFourth, lastFourth
    case firstThreeFourths, centerThreeFourths, lastThreeFourths
    // Sixths
    case topLeftSixth, topCenterSixth, topRightSixth
    case bottomLeftSixth, bottomCenterSixth, bottomRightSixth
    // Whole
    case maximize, almostMaximize, maximizeHeight, center

    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable {
        case halves = "Halves", quarters = "Quarters", thirds = "Thirds", fourths = "Fourths",
            sixths = "Sixths", whole = "Whole"
        var id: String { rawValue }
    }

    var group: Group {
        switch self {
        case .leftHalf, .rightHalf, .centerHalf, .topHalf, .bottomHalf: return .halves
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return .quarters
        case .firstThird, .centerThird, .lastThird, .firstTwoThirds, .centerTwoThirds,
            .lastTwoThirds:
            return .thirds
        case .firstFourth, .secondFourth, .thirdFourth, .lastFourth, .firstThreeFourths,
            .centerThreeFourths, .lastThreeFourths:
            return .fourths
        case .topLeftSixth, .topCenterSixth, .topRightSixth, .bottomLeftSixth,
            .bottomCenterSixth, .bottomRightSixth:
            return .sixths
        case .maximize, .almostMaximize, .maximizeHeight, .center: return .whole
        }
    }

    var title: String {
        switch self {
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .centerHalf: return "Center Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .firstThird: return "First Third"
        case .centerThird: return "Center Third"
        case .lastThird: return "Last Third"
        case .firstTwoThirds: return "First Two Thirds"
        case .centerTwoThirds: return "Center Two Thirds"
        case .lastTwoThirds: return "Last Two Thirds"
        case .firstFourth: return "First Fourth"
        case .secondFourth: return "Second Fourth"
        case .thirdFourth: return "Third Fourth"
        case .lastFourth: return "Last Fourth"
        case .firstThreeFourths: return "First Three Fourths"
        case .centerThreeFourths: return "Center Three Fourths"
        case .lastThreeFourths: return "Last Three Fourths"
        case .topLeftSixth: return "Top Left Sixth"
        case .topCenterSixth: return "Top Center Sixth"
        case .topRightSixth: return "Top Right Sixth"
        case .bottomLeftSixth: return "Bottom Left Sixth"
        case .bottomCenterSixth: return "Bottom Center Sixth"
        case .bottomRightSixth: return "Bottom Right Sixth"
        case .maximize: return "Maximize"
        case .almostMaximize: return "Almost Maximize"
        case .maximizeHeight: return "Maximize Height"
        case .center: return "Center"
        }
    }

    /// The layout as a unit rectangle (x, y, w, h in 0…1 of the screen), which is both how
    /// the palette draws its icon and how the frame is computed. `nil` for the layouts that
    /// depend on the window's own size.
    var unit: CGRect? {
        switch self {
        case .leftHalf: return CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf: return CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .centerHalf: return CGRect(x: 0.25, y: 0, width: 0.5, height: 1)
        case .topHalf: return CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottomHalf: return CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .topLeft: return CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case .topRight: return CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .bottomLeft: return CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .bottomRight: return CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .firstThird: return CGRect(x: 0, y: 0, width: 1.0 / 3.0, height: 1)
        case .centerThird: return CGRect(x: 1.0 / 3.0, y: 0, width: 1.0 / 3.0, height: 1)
        case .lastThird: return CGRect(x: 2.0 / 3.0, y: 0, width: 1.0 / 3.0, height: 1)
        case .firstTwoThirds: return CGRect(x: 0, y: 0, width: 2.0 / 3.0, height: 1)
        case .centerTwoThirds: return CGRect(x: 1.0 / 6.0, y: 0, width: 2.0 / 3.0, height: 1)
        case .lastTwoThirds: return CGRect(x: 1.0 / 3.0, y: 0, width: 2.0 / 3.0, height: 1)
        case .firstFourth: return CGRect(x: 0, y: 0, width: 0.25, height: 1)
        case .secondFourth: return CGRect(x: 0.25, y: 0, width: 0.25, height: 1)
        case .thirdFourth: return CGRect(x: 0.5, y: 0, width: 0.25, height: 1)
        case .lastFourth: return CGRect(x: 0.75, y: 0, width: 0.25, height: 1)
        case .firstThreeFourths: return CGRect(x: 0, y: 0, width: 0.75, height: 1)
        case .centerThreeFourths: return CGRect(x: 0.125, y: 0, width: 0.75, height: 1)
        case .lastThreeFourths: return CGRect(x: 0.25, y: 0, width: 0.75, height: 1)
        case .topLeftSixth: return CGRect(x: 0, y: 0, width: 1.0 / 3.0, height: 0.5)
        case .topCenterSixth: return CGRect(x: 1.0 / 3.0, y: 0, width: 1.0 / 3.0, height: 0.5)
        case .topRightSixth: return CGRect(x: 2.0 / 3.0, y: 0, width: 1.0 / 3.0, height: 0.5)
        case .bottomLeftSixth: return CGRect(x: 0, y: 0.5, width: 1.0 / 3.0, height: 0.5)
        case .bottomCenterSixth: return CGRect(x: 1.0 / 3.0, y: 0.5, width: 1.0 / 3.0, height: 0.5)
        case .bottomRightSixth: return CGRect(x: 2.0 / 3.0, y: 0.5, width: 1.0 / 3.0, height: 0.5)
        case .maximize: return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .almostMaximize: return CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        case .maximizeHeight, .center: return nil
        }
    }

    /// The frame this layout gives a window currently at `window` on `screen` (the visible
    /// area). Only the whole-screen layouts that keep the window's own size read `window`.
    func frame(on screen: CGRect, window: CGRect) -> CGRect {
        let size = window.size
        if let unit {
            return CGRect(
                x: screen.minX + unit.minX * screen.width,
                y: screen.minY + unit.minY * screen.height,
                width: unit.width * screen.width,
                height: unit.height * screen.height
            ).integral
        }
        switch self {
        case .maximizeHeight:
            let width = min(size.width, screen.width)
            return CGRect(
                x: min(max(window.minX, screen.minX), screen.maxX - width),
                y: screen.minY, width: width, height: screen.height
            ).integral
        case .center:
            let width = min(size.width, screen.width)
            let height = min(size.height, screen.height)
            return CGRect(
                x: screen.midX - width / 2, y: screen.midY - height / 2,
                width: width, height: height
            ).integral
        default:
            return screen
        }
    }

    /// The layouts that fill what this one leaves: dropping a window on the left half
    /// leaves the right half for whatever else is on the desktop. Empty for layouts that
    /// leave no clean remainder.
    var complements: [SnapLayout] {
        switch self {
        case .leftHalf: return [.rightHalf]
        case .rightHalf: return [.leftHalf]
        case .topHalf: return [.bottomHalf]
        case .bottomHalf: return [.topHalf]
        case .topLeft: return [.topRight, .bottomLeft, .bottomRight]
        case .topRight: return [.topLeft, .bottomRight, .bottomLeft]
        case .bottomLeft: return [.bottomRight, .topLeft, .topRight]
        case .bottomRight: return [.bottomLeft, .topRight, .topLeft]
        case .firstThird: return [.lastTwoThirds]
        case .lastThird: return [.firstTwoThirds]
        case .centerThird: return [.firstThird, .lastThird]
        case .firstTwoThirds: return [.lastThird]
        case .lastTwoThirds: return [.firstThird]
        case .firstFourth: return [.lastThreeFourths]
        case .lastFourth: return [.firstThreeFourths]
        case .firstThreeFourths: return [.lastFourth]
        case .lastThreeFourths: return [.firstFourth]
        default: return []
        }
    }

    /// Where the pointer has to be for each target. Proportions rather than points, so a
    /// laptop display and a 6K one both give the bands the same share of the screen.
    enum Band {
        /// An edge is a half; the band is generous because it is aimed at by feel.
        static let edge: CGFloat = 0.12
        static let top: CGFloat = 0.12
        /// A corner is a quarter, and it wins over the edge it shares — reaching a corner
        /// should never give you the half by accident.
        static let cornerX: CGFloat = 0.20
        static let cornerY: CGFloat = 0.28
    }

    /// The target the pointer is over, or nil for "leave it where I drop it". This is the
    /// whole vocabulary now that there is no palette: edge → half, corner → quarter,
    /// top → maximize. The bottom edge is deliberately nothing: the corner dock lives there
    /// and a snap zone under it would fight the hand reaching for it.
    static func zone(at point: CGPoint, on screen: CGRect) -> SnapLayout? {
        guard screen.contains(point) else { return nil }
        let left = point.x <= screen.minX + screen.width * Band.cornerX
        let right = point.x >= screen.maxX - screen.width * Band.cornerX
        let top = point.y <= screen.minY + screen.height * Band.cornerY
        let bottom = point.y >= screen.maxY - screen.height * Band.cornerY

        switch (left, right, top, bottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        default: break
        }
        if point.y <= screen.minY + screen.height * Band.top { return .maximize }
        if point.x <= screen.minX + screen.width * Band.edge { return .leftHalf }
        if point.x >= screen.maxX - screen.width * Band.edge { return .rightHalf }
        return nil
    }

    /// The layout whose frame matches `frame` on `screen`, within `tolerance` — how an
    /// existing window on the desktop is read as "already in the left half".
    static func matching(_ frame: CGRect, on screen: CGRect, tolerance: CGFloat = 12)
        -> SnapLayout?
    {
        allCases.first { layout in
            guard layout.unit != nil else { return false }
            let candidate = layout.frame(on: screen, window: frame)
            return abs(candidate.minX - frame.minX) <= tolerance
                && abs(candidate.minY - frame.minY) <= tolerance
                && abs(candidate.width - frame.width) <= tolerance
                && abs(candidate.height - frame.height) <= tolerance
        }
    }
}

/// What to do with the *other* windows on the desktop once one has been snapped: the
/// frontmost of them, if it is not already snapped, takes the complement. One window
/// adjusted, never a reshuffle of everything — the user dropped one thing.
enum SnapArrangement {
    struct Other: Equatable {
        let id: CGWindowID
        let frame: CGRect
    }

    struct Move: Equatable {
        let id: CGWindowID
        let layout: SnapLayout
    }

    /// `others` front to back, already excluding the dropped window and this app.
    static func adjustments(
        after layout: SnapLayout, others: [Other], screen: CGRect
    ) -> [Move] {
        let complements = layout.complements
        guard !complements.isEmpty else { return [] }
        // Windows already sitting in a complement stay; the free ones take what is left.
        let taken = Set(
            others.compactMap { SnapLayout.matching($0.frame, on: screen) }
                .filter { complements.contains($0) })
        var free = complements.filter { !taken.contains($0) }
        var moves: [Move] = []
        for other in others where !free.isEmpty {
            if let existing = SnapLayout.matching(other.frame, on: screen), existing != layout,
                complements.contains(existing)
            {
                continue  // already placed
            }
            moves.append(Move(id: other.id, layout: free.removeFirst()))
        }
        return moves
    }
}
