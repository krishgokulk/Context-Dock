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
import SwiftUI

/// Where the shell sits along the bottom of the screen.
///
/// The surface stopped being "the dock plus a corner annex" some time ago: the frontmost
/// app, the selection, the clipboard, the shelf and both chats all live here now. What is
/// left is where it sits — and centred, with the input bar under it, it reads as a dock
/// again without being a second surface.
enum CornerDockAnchor: String, CaseIterable, Codable {
    case left, center, right

    var label: String {
        switch self {
        case .left: return "Left"
        case .center: return "Centre"
        case .right: return "Right"
        }
    }

    /// How the cards line up with each other inside the shell.
    var horizontalAlignment: HorizontalAlignment {
        switch self {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .left: return .bottomLeading
        case .center: return .bottom
        case .right: return .bottomTrailing
        }
    }
}

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
    /// The clip preview that stacks above the clipboard while a clip is being looked at.
    static let previewHeight: CGFloat = 232
    /// The commands card that stacks above the App Chat field while a list is showing.
    static let listHeight: CGFloat = 230
    /// The selection card, when Selection Scope is up.
    static let selectionHeight: CGFloat = 166

    /// The window the shell draws into, which depends on how it is anchored.
    ///
    /// Against an edge it is one card wide. Centred it is a row — shelf, field, clipboard
    /// side by side — and a row does not fit in a column's window: the surfaces were being
    /// drawn into 428 points and landing on top of each other, which is what "the clipboard
    /// interrupts the panel" was.
    ///
    /// The window stays no wider than it needs to be. It is transparent but not inert:
    /// every point of it is a point the pointer cannot use for the app underneath.
    static func panelSize(for anchor: CornerDockAnchor) -> CGSize {
        // Worst case: one surface fully expanded, the preview above it, and both other
        // pills stacked above that.
        let height =
            cardHeight + previewHeight + listHeight + selectionHeight + gap * 3
            + (gap + pillHeight) * 2 + pad * 2
        switch anchor {
        case .left, .right:
            return CGSize(width: cardWidth + pad * 2, height: height)
        case .center:
            // Three cards abreast, which is the widest the row can be.
            return CGSize(width: cardWidth * 3 + gap * 2 + pad * 2, height: height)
        }
    }

    static var panelSize: CGSize { panelSize(for: .right) }

    /// Rects in the panel's coordinates, origin bottom-left. A nil size means that
    /// surface is showing nothing, and it takes no space: with no clipboard pill below
    /// it, the shelf drops into the corner rather than floating above a gap.
    /// Stacked bottom-up in the order they are passed, each dropping out of the stack
    /// when it has nothing to show. The prompt takes the corner when it is open: it is the
    /// one the user just asked for by name.
    /// The clip being looked at sits directly above the list it was chosen from, so the
    /// preview and the row it belongs to are next to each other.
    static func slots(
        shelf: CGSize? = nil, preview: CGSize? = nil, clipboard: CGSize? = nil,
        selection: CGSize? = nil, list: CGSize? = nil, prompt: CGSize? = nil,
        anchor: CornerDockAnchor = .right
    ) -> (
        shelf: CGRect?, preview: CGRect?, clipboard: CGRect?, selection: CGRect?,
        list: CGRect?, prompt: CGRect?
    ) {
        var baseline = pad

        let panel = panelSize(for: anchor)

        /// Cards line up with each other along the anchored edge, so a narrow pill sits
        /// under the wide card it belongs to rather than drifting away from it.
        func x(for width: CGFloat) -> CGFloat {
            switch anchor {
            case .right: return panel.width - pad - width
            case .left: return pad
            case .center: return (panel.width - width) / 2
            }
        }

        func place(_ size: CGSize?) -> CGRect? {
            guard let size else { return nil }
            let rect = CGRect(
                x: x(for: size.width), y: baseline, width: size.width, height: size.height)
            baseline = rect.maxY + gap
            return rect
        }

        // The app's commands sit directly above the field they were typed into, the way
        // the clip preview sits directly above the list it was chosen from.
        let promptRect = place(prompt)
        let listRect = place(list)
        // The selection sits above the chat that will act on it, and below the clipboard.
        let selectionRect = place(selection)

        // Centred, the shell reads as a dock: the ambient pills stand beside the field on
        // the same baseline rather than stacking over it, so the row grows sideways the way
        // the Dock does instead of climbing the screen in front of the user's work. What a
        // question is being answered with — the list, the selection — still sits above,
        // because that belongs to the field and not to the row.
        if anchor == .center, let prompt {
            // One row, centred as a whole: shelf, field, clipboard. Measured the way the
            // view stacks it, so the rect drawn and the rect hit-tested are the same
            // arithmetic rather than two guesses that agree most of the time.
            let widths = [shelf?.width, prompt.width, clipboard?.width].compactMap { $0 }
            let total = widths.reduce(0, +) + CGFloat(widths.count - 1) * gap
            var cursor = (panel.width - total) / 2

            func placeInRow(_ size: CGSize?) -> CGRect? {
                guard let size else { return nil }
                let rect = CGRect(x: cursor, y: pad, width: size.width, height: size.height)
                cursor = rect.maxX + gap
                return rect
            }

            let shelfRect = placeInRow(shelf)
            let rowPromptRect = placeInRow(prompt)!
            let clipboardRect = placeInRow(clipboard)

            // What answers the field sits above the field, centred on it.
            func placeAbovePrompt(_ size: CGSize?, y: CGFloat) -> CGRect? {
                guard let size else { return nil }
                return CGRect(
                    x: rowPromptRect.midX - size.width / 2, y: y,
                    width: size.width, height: size.height)
            }
            var above = rowPromptRect.maxY + gap
            let rowListRect = placeAbovePrompt(list, y: above)
            if let rowListRect { above = rowListRect.maxY + gap }
            let rowSelectionRect = placeAbovePrompt(selection, y: above)

            // The clip being looked at stays directly above the clipboard it came from.
            let previewRect: CGRect? = {
                guard let preview, let clipboardRect else { return nil }
                return CGRect(
                    x: clipboardRect.midX - preview.width / 2,
                    y: clipboardRect.maxY + gap,
                    width: preview.width, height: preview.height)
            }()
            return (
                shelfRect, previewRect, clipboardRect, rowSelectionRect, rowListRect,
                rowPromptRect
            )
        }

        let clipboardRect = place(clipboard)
        let previewRect = place(preview)
        let shelfRect = place(shelf)
        return (shelfRect, previewRect, clipboardRect, selectionRect, listRect, promptRect)
    }
}
