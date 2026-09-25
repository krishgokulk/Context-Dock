// SelectionActions.swift
// Context-Dock
//
// What can be done with a selection, as the corner sees it — and the seam the corner reaches
// the Dock's Selection rows through.
//
// Interim (owner 2026-09-25, 00-DOCK-AND-CORNER §4a rule 5): the rows are still built by
// LauncherView, which conforms to `SelectionActionProviding`. The corner card knows only the
// protocol. Extracting a `SelectionActionSource` out of LauncherView is tracked on GitHub; when
// it lands, the new type conforms and the corner does not change.

import AppKit
import Foundation

/// One selection, captured once. Every row the corner builds or runs is about this copy —
/// never whatever the Dock or the frontmost app holds by the time the row runs.
struct SelectionSnapshot: Equatable {
    var text: String
    var filePaths: [String]
    var appName: String
    var bundleID: String

    var isEmpty: Bool { text.isEmpty && filePaths.isEmpty }

    /// The Dock's frozen form of this selection — the shape its Selection builders read.
    var asFrozenPayload: GlobalContextActivation {
        if !filePaths.isEmpty {
            let urls = filePaths.map { URL(fileURLWithPath: $0) }
            return GlobalContextActivation(
                autoActivated: false,
                frozenText: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files selected",
                frozenIcon: "doc.on.doc.fill",
                sourceBundleId: bundleID,
                frozenFilePaths: filePaths)
        }
        return GlobalContextActivation(
            autoActivated: false,
            frozenText: String(text.prefix(120)),
            frozenFullText: text,
            frozenIcon: "text.cursor",
            sourceBundleId: bundleID)
    }

    /// The selection a Dock payload describes — the inverse of `asFrozenPayload`, and what the
    /// Dock's own selection chat reads, so both shells describe one selection the same way.
    static func fromFrozen(
        _ payload: GlobalContextActivation, appName: String, bundleID: String
    ) -> SelectionSnapshot {
        let text = (payload.frozenFilePaths.isEmpty
            ? (payload.frozenFullText ?? payload.frozenText ?? "") : "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SelectionSnapshot(
            text: text, filePaths: payload.frozenFilePaths, appName: appName,
            bundleID: payload.sourceBundleId ?? bundleID)
    }
}

/// A question about a selection, as it is handed to a chat. Built in one place for both shells:
/// the Dock's selection chat and the corner's ask path send the identical request for the same
/// selection and prompt.
struct SelectionAskRequest: Equatable {
    let prompt: String
    let selectedText: String?
    let filePaths: [String]
    let appName: String
    let bundleID: String

    static func make(prompt: String, snapshot: SelectionSnapshot) -> SelectionAskRequest {
        let text = snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SelectionAskRequest(
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            selectedText: text.isEmpty ? nil : text,
            filePaths: snapshot.filePaths,
            appName: snapshot.appName,
            bundleID: snapshot.bundleID)
    }
}

/// One row of the Selection list, detached from how the Dock draws it.
struct SelectionActionRow: Identifiable, Equatable {
    enum Kind: Equatable {
        /// An AI prompt about the selection. The corner asks it in its own chat; the Dock's
        /// chat would answer in a window nobody is looking at.
        case ask(prompt: String)
        /// Runs as the Dock runs it — files, clipboard, other apps.
        case perform
        /// The Dock's inline share mode. Not in the corner yet (tracked with the extraction).
        case share
    }

    let id: String
    let title: String
    let icon: String
    let badge: String?
    let accentColorName: String?
    let kind: Kind

    /// A Finder menu command: it acts on whatever Finder has selected when it runs.
    var actsOnFinderSelection: Bool { id.hasPrefix("finder-") }
    /// Writing Tools: acts on the source app's live text selection.
    var actsOnLiveTextSelection: Bool { id.hasPrefix("selection-writing-tool-") }
}

/// Rows for a selection, and running one. LauncherView conforms today.
@MainActor
protocol SelectionActionProviding {
    func selectionRows(for snapshot: SelectionSnapshot, query: String) -> [SelectionActionRow]
    /// Runs the row with this id, rebuilt for `snapshot`. False when the row is not there.
    @discardableResult
    func runSelectionRow(id: String, query: String, for snapshot: SelectionSnapshot) -> Bool
    /// Put `text` in place of the selection in the app it came from. Takes the screen (the
    /// source app comes forward and is pasted into), so callers gate it on Computer Use.
    @discardableResult
    func replaceSelection(with text: String, for snapshot: SelectionSnapshot) -> Bool
}

@MainActor
enum SelectionActions {
    /// The provider the corner asks. Set by LauncherView when it appears — at app launch, not
    /// the first time the Dock opens (`setupLauncherWindow` runs in didFinishLaunching).
    static var provider: (any SelectionActionProviding)?

    /// True while a corner build or run has the captured selection swapped into the Dock. The
    /// Dock's helpers stop falling back to the live Accessibility selection while it is: the
    /// captured copy is the whole truth for that call.
    static var isScopedToCapturedSelection = false

    /// Pure: the corner's list is the Dock's, in the Dock's order, less Share.
    static func cornerRows(_ rows: [SelectionActionRow]) -> [SelectionActionRow] {
        rows.filter { $0.kind != .share }
    }

    /// Pure: what the end-of-answer Replace does. Replacing writes into another app through its
    /// UI — the `takesScreen` surface (surface-cost spec) — so it runs only when Computer Use is
    /// on for that app; otherwise the answer is copied and the card says why.
    enum ReplaceRoute: Equatable { case replaceInPlace, copyInstead, unavailable }

    static func replaceRoute(snapshot: SelectionSnapshot, computerUseAllowed: Bool) -> ReplaceRoute {
        guard !snapshot.text.isEmpty, snapshot.filePaths.isEmpty else { return .unavailable }
        return computerUseAllowed ? .replaceInPlace : .copyInstead
    }

    /// Pure: whether Finder's live selection must be set back to the captured files before a
    /// row runs — a Finder menu command acts on whatever Finder has selected at that moment.
    static func mustReselectInFinder(_ row: SelectionActionRow, snapshot: SelectionSnapshot) -> Bool {
        row.actsOnFinderSelection && !snapshot.filePaths.isEmpty
    }

    /// Pure: whether a row that acts on the source app's live text may run. Text cannot be put
    /// back the way files can, so a changed selection refuses rather than guesses.
    static func liveTextStillMatches(captured: String, live: String?) -> Bool {
        let a = captured.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = (live ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !a.isEmpty && a == b
    }

    /// Swap `value` in, run `body`, put the old value back — even if `body` returns early.
    /// Pure over its accessors, which is what lets the swap be tested without a mounted view.
    static func withSwapped<Value, Result>(
        _ value: Value, get: () -> Value, set: (Value) -> Void, _ body: () -> Result
    ) -> Result {
        let saved = get()
        set(value)
        let wasScoped = isScopedToCapturedSelection
        isScopedToCapturedSelection = true
        defer {
            set(saved)
            isScopedToCapturedSelection = wasScoped
        }
        return body()
    }
}
