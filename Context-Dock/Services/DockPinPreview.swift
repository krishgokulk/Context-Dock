// DockPinPreview.swift
// Context-Dock
//
// What the card above a hovered pin shows.
//
// Hovering an app icon in the strip answers "what is this app doing?" with its windows.
// Hovering a pinned file, folder or command answered with nothing at all, so half the dock
// was worth pointing at and half was not. This is the other half of that answer, in the same
// slot, on the same dwell: a file shows itself, a folder shows what is in it, a command says
// what it is.
//
// The shape of the answer is decided here, away from the filesystem — the reads are handed
// in — so the rules that matter (what is hidden, how many fit, what a missing target says)
// can be held without a disk.

import AppKit
import Foundation

enum DockHoverTarget: Equatable {
    case app(bundleID: String)
    case pin(id: UUID)
}

enum DockPinPreview: Equatable {
    struct FileDetail: Equatable {
        let path: String
        let name: String
        /// "PDF document", "Swift source" — what the Finder calls it.
        let kindName: String
        let byteCount: Int64?
        let modified: Date?
    }

    /// A folder is handed to `PreviewFolderBrowser`, which is what this app already shows a
    /// folder with — list or grid, a keyboard selection, drag out, walk into a subfolder.
    /// Nothing here lists a directory: a second lister beside that one would be a second
    /// set of rules about sorting, hidden files and what a click does.
    struct FolderDetail: Equatable {
        let path: String
        let name: String
    }

    struct DocumentDetail: Equatable {
        let title: String
        let subtitle: String?
        let symbol: String
    }

    case file(FileDetail)
    case folder(FolderDetail)
    case document(DocumentDetail)
    /// The pin still exists; what it points at does not.
    case missing(name: String, reason: String)
}

/// The card's size, from the preview alone — a corner slot is hit-tested by this number, so
/// it is a function of the model and nothing else (memory `corner-pill-size-must-be-pure`).
enum DockPinPreviewMetrics {
    static let width: CGFloat = 260
    static let inset: CGFloat = 12
    static let thumb = CGSize(width: 236, height: 148)
    static let titleHeight: CGFloat = 16
    static let detailHeight: CGFloat = 14
    static let headerHeight: CGFloat = 20
    /// The folder browser brings its own list, grid and footer, so it is given a window to
    /// be a window in rather than a height derived from a count this no longer knows.
    static let folder = CGSize(width: 360, height: 320)
    /// The folder card after its expand control: room for a real column of names and a
    /// grid more than two icons wide. Files and messages have nothing more to show.
    static let folderExpanded = CGSize(width: 560, height: 480)

    static func size(for preview: DockPinPreview, expanded: Bool = false) -> CGSize {
        switch preview {
        case .file:
            return CGSize(
                width: width,
                height: 2 * inset + thumb.height + 6 + titleHeight + 2 + detailHeight)
        case .folder:
            return expanded ? folderExpanded : folder
        case .document, .missing:
            return CGSize(width: width, height: 2 * inset + titleHeight + 4 + detailHeight + 20)
        }
    }
}
