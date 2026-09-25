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
        /// Sharing: "Share Selection" opens the share destinations, and each destination is
        /// a `.share` row too.
        case share
    }

    let id: String
    let title: String
    let icon: String
    let badge: String?
    let accentColorName: String?
    let kind: Kind
    /// The destination's own icon, for share destinations; everything else draws `icon`.
    var image: NSImage? = nil
    /// What running this row may do, when it asks first (a Selection extension with side
    /// effects). The card asks inside itself.
    var approval: String? = nil

    /// A Finder menu command: it acts on whatever Finder has selected when it runs.
    var actsOnFinderSelection: Bool { id.hasPrefix("finder-") }
    /// Writing Tools: acts on the source app's live text selection.
    var actsOnLiveTextSelection: Bool { id.hasPrefix("selection-writing-tool-") }

    /// The app whose UI this row drives — clicking its menu over Accessibility. That is the
    /// `takesScreen` surface of the surface-cost spec; nil for everything else (scripts,
    /// clipboard, the AI provider, opening a URL).
    func screenApp(for snapshot: SelectionSnapshot) -> String? {
        if actsOnFinderSelection { return "com.apple.finder" }
        if actsOnLiveTextSelection { return snapshot.bundleID }
        return nil
    }
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

    /// True while the corner runs a row the user approved in its card, so the Dock's own
    /// confirmation alert is not asked a second time.
    static var runApprovedInCard = false

    /// What a row may do given Computer Use for the app it drives (surface-cost spec §3):
    /// run it, offer the consent first, or leave it out because a cheaper path does the job.
    enum ScreenGate: Equatable { case run, needsConsent(bundleID: String), hidden }

    /// Pure. Rows that take the screen run only with Computer Use for their app. Without it,
    /// Writing Tools are left out — the AI rows do the same work through the user's provider
    /// with no screen taken — and Finder's menu commands stay, marked, offering the consent:
    /// for some (Open With, Tags, Services) the menu is the only way.
    static func screenGate(
        _ row: SelectionActionRow, snapshot: SelectionSnapshot, computerUseAllowed: (String) -> Bool
    ) -> ScreenGate {
        guard let app = row.screenApp(for: snapshot) else { return .run }
        if computerUseAllowed(app) { return .run }
        return row.actsOnLiveTextSelection ? .hidden : .needsConsent(bundleID: app)
    }

    /// Pure: the corner's list is the Dock's, in the Dock's order. Of the share rows only
    /// "Share Selection" is kept: it opens the destinations inside the card, which is where
    /// every one of them is listed.
    static func cornerRows(_ rows: [SelectionActionRow]) -> [SelectionActionRow] {
        rows.filter { $0.kind != .share || $0.id == SelectionShare.entryRowID }
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

/// Sharing a selection from the corner — the Dock's share route 1 (native destinations, every
/// installed share extension, frecency-ranked), fed the captured selection rather than
/// whatever the Dock holds.
@MainActor
enum SelectionShare {
    /// The Dock's "Share Selection" row: in the corner it opens the destinations in the card.
    static let entryRowID = "selection-share"

    /// The captured selection in the shape the share router reads.
    static func context(for snapshot: SelectionSnapshot) -> AXContext {
        var context = AXContext(appName: snapshot.appName, bundleId: snapshot.bundleID, pid: 0)
        context.selectedText = snapshot.text.isEmpty ? nil : snapshot.text
        context.selectedFilePaths = snapshot.filePaths
        return context
    }

    /// What is shared: the captured files, else the captured text — the router's own rule.
    static func items(for snapshot: SelectionSnapshot) -> [Any] {
        ShareIntentRouter.shared.shareableItems(for: context(for: snapshot))
    }

    // MARK: Typed "send to …" — the Dock's route 3

    /// The row a typed send command shows, saying what Return will do.
    static let intentRowID = "selection-share-intent"

    /// Pure: whether what is typed starts like a send command. The router's parser alone reads
    /// "copy text" as texting someone ("text" is a channel and a payload word), and the card's
    /// field is where rows are filtered — so the card asks for a send verb first.
    static func startsLikeSendCommand(_ typed: String) -> Bool {
        let first = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(separator: " ").first.map(String.init) ?? ""
        return ["send", "share", "email", "mail", "message", "imessage", "text", "sms", "airdrop"]
            .contains(first)
    }

    /// Pure: the row for a parsed send command, or nil when it names no channel or person —
    /// a bare "share" is what the Share Selection row already does.
    static func intentRow(for intent: ShareIntent) -> SelectionActionRow? {
        let recipient = intent.recipientQuery?
            .trimmingCharacters(in: .whitespacesAndNewlines).capitalized ?? ""
        let channel: String? = switch intent.channelHint {
        case .messages: "Messages"
        case .mail: "Mail"
        case .airDrop: "AirDrop"
        case .picker: nil
        }
        let title: String
        switch (channel, recipient.isEmpty) {
        case (let channel?, false): title = "Send to \(recipient) via \(channel)"
        case (let channel?, true): title = "Send via \(channel)"
        case (nil, false): title = "Share to \(recipient)"
        case (nil, true): return nil
        }
        let icon = switch intent.channelHint {
        case .messages: "message"
        case .mail: "envelope"
        case .airDrop: "airplayaudio"
        case .picker: "square.and.arrow.up"
        }
        return SelectionActionRow(
            id: intentRowID, title: title, icon: icon, badge: "Send", accentColorName: "blue",
            kind: .share)
    }

    /// Runs a typed send command on the captured selection, through the Dock's router: the
    /// contact is looked up, then Messages or Mail sends it (or composes it), or the share
    /// destinations open. Returns the router's own one-line outcome.
    static func send(
        _ intent: ShareIntent, snapshot: SelectionSnapshot,
        openDestinations: @escaping ([Any]) -> Void
    ) async -> String {
        let resolution = await ShareIntentRouter.shared.resolve(intent)
        return await ShareIntentRouter.shared.execute(
            resolution, axContext: context(for: snapshot), presentSharingPicker: openDestinations)
    }

    struct Destination: Equatable {
        let title: String
        let image: NSImage?
        let usage: Double
    }

    /// Pure: destinations as rows, filtered by what is typed and ranked the Dock's way.
    static func rows(_ destinations: [Destination], query: String) -> [SelectionActionRow] {
        let normalizedQuery = DockTextMatch.normalized(query)
        return destinations.enumerated()
            .compactMap { index, destination -> (SelectionActionRow, Double)? in
                let normalizedTitle = DockTextMatch.normalized(destination.title)
                guard ShareActionCoordinator.destinationMatches(
                    normalizedTitle: normalizedTitle, normalizedQuery: normalizedQuery)
                else { return nil }
                let row = SelectionActionRow(
                    id: ShareActionCoordinator.destinationRowID(normalizedTitle: normalizedTitle),
                    title: destination.title, icon: "square.and.arrow.up", badge: "Share",
                    accentColorName: "blue", kind: .share, image: destination.image)
                return (row, ShareActionCoordinator.rankingScore(
                    usage: destination.usage, systemIndex: index))
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// The installed destinations for `items`, as rows.
    static func rows(for items: [Any], query: String) -> [SelectionActionRow] {
        let destinations = ShareActionCoordinator.shared.shareDestinations(items: items).map {
            Destination(
                title: $0.title, image: $0.image,
                usage: UsageTracker.shared.getScore(
                    for: ShareActionCoordinator.usageKey(
                        normalizedTitle: DockTextMatch.normalized($0.title))))
        }
        return rows(destinations, query: query)
    }

    /// Share `items` through the destination with this row id. False when it is not there.
    static func perform(rowID: String, items: [Any]) -> Bool {
        guard let destination = ShareActionCoordinator.shared.shareDestinations(items: items)
            .first(where: {
                ShareActionCoordinator.destinationRowID(
                    normalizedTitle: DockTextMatch.normalized($0.title)) == rowID
            })
        else { return false }
        ShareActionCoordinator.recordUse(normalizedTitle: DockTextMatch.normalized(destination.title))
        destination.perform(withItems: items)
        return true
    }
}
