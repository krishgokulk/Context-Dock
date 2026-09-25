// LauncherView+SelectionActionProviding.swift
// Context-Dock
//
// The corner's Selection card, served by the Dock's own Selection rows — the interim bridge
// (00-DOCK-AND-CORNER §4a rule 5). The corner passes the selection it captured; for exactly
// the length of one synchronous call that copy is the Dock's frozen selection, and then the
// Dock's own is put back. Nothing here is shared between the two afterwards.

import AppKit
import Foundation

extension LauncherView: SelectionActionProviding {
    func selectionRows(for snapshot: SelectionSnapshot, query: String) -> [SelectionActionRow] {
        selectionRows(for: snapshot, query: query, includeShare: false)
    }

    /// The Dock's list for this selection. The corner asks without the per-destination share
    /// lists — it lists destinations in its own card, and building them is most of the cost;
    /// the test asks with them, to show that leaving them out changes nothing else.
    func selectionRows(
        for snapshot: SelectionSnapshot, query: String, includeShare: Bool
    ) -> [SelectionActionRow] {
        guard !snapshot.isEmpty else { return [] }
        return withCapturedSelection(snapshot) {
            buildSelectionScopePills(query: query, includeShare: includeShare)
                .filter { !$0.isSeparator }
                .map(Self.selectionRow(from:))
        }
    }

    @discardableResult
    func runSelectionRow(id: String, query: String, for snapshot: SelectionSnapshot) -> Bool {
        guard !snapshot.isEmpty else { return false }
        return withCapturedSelection(snapshot) {
            // Rebuilt for the captured selection rather than kept from the list: the row's
            // closure is made from that copy, whatever the Dock holds now.
            let pills = buildSelectionScopePills(query: query, includeShare: false)
            guard let pill = pills.first(where: { $0.id == id })
                ?? buildSelectionScopePills(query: "", includeShare: false)
                    .first(where: { $0.id == id }),
                pill.isEnabled
            else { return false }
            pill.execute()
            return true
        }
    }

    @discardableResult
    func replaceSelection(with text: String, for snapshot: SelectionSnapshot) -> Bool {
        guard !text.isEmpty, !snapshot.text.isEmpty,
            let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: snapshot.bundleID
            ).first(where: { !$0.isTerminated })
        else { return false }
        // The Dock's own paste-back, unchanged: the source app forward, then the text in.
        pasteNativeWritingToolOutput(text, sourcePID: app.processIdentifier)
        return true
    }

    private func withCapturedSelection<Result>(
        _ snapshot: SelectionSnapshot, _ body: () -> Result
    ) -> Result {
        SelectionActions.withSwapped(
            snapshot.asFrozenPayload as GlobalContextActivation?,
            get: { selectionScopePayload },
            set: { selectionScopePayload = $0 },
            body)
    }

    /// Pure: a Dock row in the corner's terms.
    static func selectionRow(from pill: DockPill) -> SelectionActionRow {
        let kind: SelectionActionRow.Kind
        if let prompt = pill.selectionAIPrompt {
            kind = .ask(prompt: prompt)
        } else if pill.isShareAction || Self.isShareRowID(pill.id) {
            kind = .share
        } else {
            kind = .perform
        }
        return SelectionActionRow(
            id: pill.id, title: pill.name, icon: pill.icon, badge: pill.badge,
            accentColorName: pill.accentColorName, kind: kind)
    }

    static func isShareRowID(_ id: String) -> Bool {
        id == "selection-share" || id.hasPrefix("share-") || id.hasPrefix("sharing-action-")
    }
}
