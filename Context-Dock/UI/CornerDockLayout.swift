// CornerDockLayout.swift
// Context-Dock
//
// Where each pill sits inside the shared corner shell.
//
// The clipboard and the shelf keep separate jobs and separate stores, but they do not get
// separate windows: the Unified Dock Surface rule is one shell with mode-specific content,
// and two floating containers stacked in the same corner is exactly what it forbids. This
// is the one place that decides the geometry both of them live in.

import CoreGraphics
import Foundation

enum CornerDockLayout {
    /// Between the two pills.
    static let gap: CGFloat = 8
    /// Around the content, so the glass shadow is never clipped by the window.
    static let pad: CGFloat = 28

    static let cardWidth: CGFloat = 372
    /// The tallest single surface the shell holds: the clipboard card and the App Chat
    /// prompt with a full suggestion list are both about this.
    static let cardHeight: CGFloat = 620
    static let pillHeight: CGFloat = 56

    /// Big enough for the worst case: one surface fully expanded with the other's pill
    /// stacked above it. The window never resizes — the morph happens inside it — so this
    /// is sized once for the largest thing it will ever hold.
    static var panelSize: CGSize {
        // Worst case: one surface fully expanded with both other pills stacked above it.
        CGSize(
            width: cardWidth + pad * 2,
            height: cardHeight + (gap + pillHeight) * 2 + pad * 2)
    }

    /// Rects in the panel's coordinates, origin bottom-left. A nil size means that
    /// surface is showing nothing, and it takes no space: with no clipboard pill below
    /// it, the shelf drops into the corner rather than floating above a gap.
    /// Stacked bottom-up in the order they are passed, each dropping out of the stack
    /// when it has nothing to show. The prompt takes the corner when it is open: it is the
    /// one the user just asked for by name.
    static func slots(
        shelf: CGSize? = nil, clipboard: CGSize? = nil, prompt: CGSize? = nil
    ) -> (shelf: CGRect?, clipboard: CGRect?, prompt: CGRect?) {
        let rightEdge = panelSize.width - pad
        var baseline = pad

        func place(_ size: CGSize?) -> CGRect? {
            guard let size else { return nil }
            let rect = CGRect(
                x: rightEdge - size.width, y: baseline, width: size.width, height: size.height)
            baseline = rect.maxY + gap
            return rect
        }

        let promptRect = place(prompt)
        let clipboardRect = place(clipboard)
        let shelfRect = place(shelf)
        return (shelfRect, clipboardRect, promptRect)
    }
}
