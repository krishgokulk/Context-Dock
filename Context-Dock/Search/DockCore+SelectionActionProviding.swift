// DockCore+SelectionActionProviding.swift
// Context-Dock
//
// Interim bridge delegation to standalone SelectionActionSource (Issue #83).

import AppKit
import Foundation

extension DockCore: SelectionActionProviding {
    func selectionRows(for snapshot: SelectionSnapshot, query: String) -> [SelectionActionRow] {
        SelectionActionSource.shared.selectionRows(for: snapshot, query: query, includeShare: false)
    }

    func selectionRows(
        for snapshot: SelectionSnapshot, query: String, includeShare: Bool
    ) -> [SelectionActionRow] {
        SelectionActionSource.shared.selectionRows(for: snapshot, query: query, includeShare: includeShare)
    }

    @discardableResult
    func runSelectionRow(id: String, query: String, for snapshot: SelectionSnapshot) -> Bool {
        SelectionActionSource.shared.runSelectionRow(id: id, query: query, for: snapshot)
    }

    @discardableResult
    func replaceSelection(with text: String, for snapshot: SelectionSnapshot) -> Bool {
        SelectionActionSource.shared.replaceSelection(with: text, for: snapshot)
    }

    /// Pure: a Dock row in the corner's terms. Forwards to SelectionActionSource.selectionRow.
    static func selectionRow(from pill: DockPill) -> SelectionActionRow {
        SelectionActionSource.selectionRow(from: pill)
    }

    static func isShareRowID(_ id: String) -> Bool {
        SelectionActionSource.isShareRowID(id)
    }

    func currentSelectionSnapshot() -> SelectionSnapshot? {
        let snapshot = dockSelectionSnapshot
        return snapshot.isEmpty ? nil : snapshot
    }
}
