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
    static let cardHeight: CGFloat = 404
    static let pillHeight: CGFloat = 56

    /// Big enough for the worst case: one surface fully expanded with the other's pill
    /// stacked above it. The window never resizes — the morph happens inside it — so this
    /// is sized once for the largest thing it will ever hold.
    static var panelSize: CGSize {
        CGSize(
            width: cardWidth + pad * 2,
            height: cardHeight + gap + pillHeight + pad * 2)
    }

    /// Rects in the panel's coordinates, origin bottom-left. A nil size means that
    /// surface is showing nothing, and it takes no space: with no clipboard pill below
    /// it, the shelf drops into the corner rather than floating above a gap.
    static func slots(
        shelf: CGSize?, clipboard: CGSize?
    ) -> (shelf: CGRect?, clipboard: CGRect?) {
        let rightEdge = panelSize.width - pad

        var clipboardRect: CGRect?
        if let clipboard {
            clipboardRect = CGRect(
                x: rightEdge - clipboard.width,
                y: pad,
                width: clipboard.width,
                height: clipboard.height)
        }

        var shelfRect: CGRect?
        if let shelf {
            let baseline = clipboardRect.map { $0.maxY + gap } ?? pad
            shelfRect = CGRect(
                x: rightEdge - shelf.width,
                y: baseline,
                width: shelf.width,
                height: shelf.height)
        }

        return (shelfRect, clipboardRect)
    }
}
