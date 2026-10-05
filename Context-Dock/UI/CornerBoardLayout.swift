// CornerBoardLayout.swift
// Context-Dock
//
// The split result board (#191): one card over the field, at the field's own width, with the
// list in its left half and whatever row is highlighted in its right — a file's preview, an
// app, a menu command — the way Raycast lays a list beside its detail (owner 2026-10-05:
// "not a separate card, inside the same window").
//
// One board in the one shell, two columns: not a second window and not a second floating
// container (Unified Dock Surface rule). Pure, like every other corner size, because the
// corner draws this frame and hit-tests the same number.

import CoreGraphics
import Foundation

/// What the side panel shows for the highlighted row.
enum CornerBoardPreview: Hashable {
    /// A file, an image, a document or a folder.
    case file(URL)
    /// An application.
    case app(bundleID: String, name: String)
    /// A menu command: where it lives in its app's menus.
    case command(title: String, path: [String], appName: String, bundleID: String)
}

enum CornerBoardLayout {
    /// The list's share of the card while a preview shows.
    static let listFraction: CGFloat = 0.5
    /// The hairline between the two halves.
    static let dividerWidth: CGFloat = 1
    /// The least height the card keeps while a preview shows, so a short list still leaves
    /// the preview room to read.
    static let minimumPreviewHeight: CGFloat = 280

    /// The list's column: the whole card, or its left half beside a preview.
    static func listWidth(board: CGFloat, preview: CornerBoardPreview?) -> CGFloat {
        preview == nil ? board : (board * listFraction).rounded()
    }

    /// The preview's column: what the list and the hairline leave.
    static func panelWidth(board: CGFloat) -> CGFloat {
        board - listWidth(board: board, preview: .file(URL(fileURLWithPath: "/"))) - dividerWidth
    }

    /// What the panel shows for this row, or nil when it has nothing worth a panel — an
    /// action, a CLI subcommand, a row nothing resolves for. Nil also when no row is
    /// highlighted: the panel follows the arrows, it does not guess.
    ///
    /// `lookup` resolves a Global row's search document by id (the model's own
    /// `searchDocumentLookup`), so a test can hand it documents without the index.
    static func preview(
        for row: AppChatRow?, appName: String = "", appBundleID: String = "",
        lookup: (String) -> GlobalSearchService.SearchDocument? = { _ in nil }
    ) -> CornerBoardPreview? {
        guard let row else { return nil }
        switch row {
        case .file(let url):
            return .file(url)
        case .global(let doc):
            return preview(for: doc)
        case .dock(let pill):
            if let path = pill.previewPath, !path.isEmpty {
                return .file(URL(fileURLWithPath: path))
            }
            if let id = pill.searchDocumentID, let doc = lookup(id) {
                return preview(for: doc)
            }
            return nil
        case .command(let item):
            return .command(
                title: item.title, path: item.path,
                appName: item.sourceAppName.isEmpty ? appName : item.sourceAppName,
                bundleID: appBundleID)
        case .action, .cliSuggestion:
            return nil
        }
    }

    /// A Global result: the file it stands for, the app it opens, or the command it runs.
    static func preview(for doc: GlobalSearchService.SearchDocument) -> CornerBoardPreview? {
        if let path = doc.filePath, !path.isEmpty, !path.hasSuffix(".app") {
            return .file(URL(fileURLWithPath: path))
        }
        switch doc.action {
        case .launchPath(let path) where !path.hasSuffix(".app"):
            return .file(URL(fileURLWithPath: path))
        case .launchBundleId(let bundleID, _), .activatePID(_, let bundleID, _):
            return .app(bundleID: bundleID, name: doc.title)
        case .launchPath:
            return doc.bundleId.isEmpty ? nil : .app(bundleID: doc.bundleId, name: doc.title)
        case .cachedMenu(let bundleID, let appName, let path, _, _):
            return .command(
                title: path.last ?? doc.title, path: path, appName: appName, bundleID: bundleID)
        default:
            return nil
        }
    }

    /// The whole card: always the list's width — the field's — and, while a preview shows,
    /// at least tall enough for it.
    static func boardSize(list: CGSize, preview: CornerBoardPreview?) -> CGSize {
        guard preview != nil else { return list }
        return CGSize(width: list.width, height: max(list.height, minimumPreviewHeight))
    }
}

extension AppChatPromptModel {
    /// The side panel for the row the arrows are on (#191). Read by the board that draws it
    /// and by the window that hit-tests it, so the two are one answer.
    var boardPreview: CornerBoardPreview? {
        CornerBoardLayout.preview(
            for: focusedRow, appName: appName, appBundleID: appBundleID,
            lookup: searchDocumentLookup)
    }

    /// The list card and its panel together: the size the window reserves for the board.
    var boardSize: CGSize {
        CornerBoardLayout.boardSize(
            list: AppChatListMetrics.size(
                rows: listRowCount, width: AppChatPromptMetrics.boardWidth(for: self)),
            preview: boardPreview)
    }
}
