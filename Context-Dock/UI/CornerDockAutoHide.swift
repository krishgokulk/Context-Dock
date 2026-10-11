// CornerDockAutoHide.swift
// Context-Dock
//
// "Automatically hide and show the dock", the way the macOS Dock does it: at rest the shell
// slides below the bottom edge of the screen, and the pointer reaching that edge under it
// brings it back. The rules live here, apart from the window, so they can be tested without
// one — the controller only asks and moves the panel.

import CoreGraphics

enum CornerDockAutoHide {
    /// How long the pointer has to stay away before the dock goes. The system Dock is quick
    /// but not instant; a pointer that overshoots and comes straight back should not see it
    /// flicker.
    static let hideDelay: Double = 0.45
    /// How long a dock nobody has pointed at stays up — raised by a hotkey, say, and then
    /// left alone. Long enough to read, short enough to be out of the way.
    static let idleDelay: Double = 3
    static let slideDuration: Double = 0.28
    /// How close to the bottom edge counts as "at the edge". A pointer cannot go below the
    /// screen, so this is a band a couple of points tall, as the system's is.
    static let edgeBand: CGFloat = 2
    /// Sideways slack around the dock's own width, so the edge does not have to be hit
    /// precisely under the first or last icon.
    static let edgeSlack: CGFloat = 24

    /// Whether the shell is at rest — only the dock strip showing, nothing asked for. Any
    /// surface the user opened, or one that has something to say, keeps it on screen.
    static func canHide(
        enabled: Bool,
        stripShowing: Bool,
        hoverCardShowing: Bool,
        selectionShowing: Bool,
        clipboardExpanded: Bool,
        shelfNeedsAttention: Bool,
        pluginEditing: Bool,
        /// A context menu is open — an icon's Unpin / Show in Finder. The pointer is on the
        /// menu, outside the dock, and hiding would take the icon out from under it.
        menuOpen: Bool = false
    ) -> Bool {
        enabled && stripShowing && !hoverCardShowing && !selectionShowing
            && !clipboardExpanded && !shelfNeedsAttention && !pluginEditing && !menuOpen
    }

    /// How long to wait before hiding, given how long ago the field folded into the strip:
    /// the fold is a morph of its own, and sliding away in the middle of it cut it off
    /// (owner 2026-09-26: "wait until it got collapsed, and then hide"). A short beat after
    /// it lands so the strip is seen at rest before it goes.
    static func delay(base: Double, sinceFold: Double?, foldDuration: Double) -> Double {
        guard let sinceFold else { return base }
        return max(base, foldDuration + settleBeat - sinceFold)
    }

    static let settleBeat: Double = 0.25

    /// The pointer is at the bottom edge of the dock's screen, under the dock.
    /// `content` is what the shell draws, in screen coordinates at its shown position.
    static func pointerReveals(
        mouse: CGPoint, screenFrame: CGRect, content: CGRect
    ) -> Bool {
        guard !content.isEmpty else { return false }
        return mouse.y <= screenFrame.minY + edgeBand
            && mouse.x >= content.minX - edgeSlack
            && mouse.x <= content.maxX + edgeSlack
    }

    /// The pointer is on the dock, or between it and the edge it came up from — the gap
    /// under the strip is part of the way in, not a reason to leave.
    static func pointerIsOver(
        mouse: CGPoint, screenFrame: CGRect, content: CGRect, slack: CGFloat
    ) -> Bool {
        guard !content.isEmpty else { return false }
        let reach = CGRect(
            x: content.minX, y: screenFrame.minY,
            width: content.width, height: content.maxY - screenFrame.minY)
        return reach.insetBy(dx: -slack, dy: -slack).contains(mouse)
    }

    /// How far the window moves down to take everything it draws below the screen, the
    /// glass shadow included.
    static func hideDistance(contentTop: CGFloat, screenMinY: CGFloat, shadow: CGFloat) -> CGFloat
    {
        max(0, contentTop - screenMinY + shadow)
    }
}
