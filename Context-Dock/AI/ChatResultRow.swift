// ChatResultRow.swift
// Context-Dock
//
// What a tool found, as data, on its way to a card.
//
// DoraX has had good result rows since early on — a note with its folder and date, a file with
// Preview and Show in Finder, a tab that switches to itself. What it has not had is any way for
// a capability to *produce* one. Rows were attached at two hardcoded sites inside the dock's own
// Notes branch, so the same question asked in the General Chat window, in the corner, or through
// the ordinary tool path came back as a paragraph. Siri answers "notes about project ideas" with
// four tappable cards; DoraX answered it with prose about cards it could have drawn.
//
// The fix is a row that travels. A capability returns rows alongside its text, the rows are
// collected per conversation, and each surface maps them onto the message once. Deliberately not
// parsed back out of the model's answer: that is lossy, it fails silently when the wording
// changes, and the app already knows the exact records — it read them.

import AppKit
import Foundation

/// One result, in the shape every surface can draw.
struct ChatResultRow: Equatable, Identifiable, Sendable {

    enum Kind: String, Sendable {
        /// An Apple Note, or anything else with a title, a container and a preview.
        case note
        /// A file on disk. Opens in DoraX's preview panel when the type suits it.
        case file
        /// A web link. Opens in whatever browser the user has made default.
        case link
        /// An installed app, adapter app included.
        case app
    }

    let kind: Kind
    /// Stable identity for the row — a note id, a file path, a URL, a bundle id.
    let id: String
    let title: String
    /// The line under the title: a folder, a containing directory, a domain.
    var subtitle: String = ""
    /// A preview of the contents, when the row has one worth showing.
    var detail: String = ""
    /// The app this result belongs to, so the card can carry its real icon. User-installed
    /// and adapter apps get theirs with nothing added per app.
    var bundleID: String? = nil
    /// Where the row points: a file on disk, or a link.
    var url: URL? = nil
    var date: Date? = nil
}

/// Rows produced during one conversation's turn.
///
/// Keyed by conversation rather than held as one list, because two surfaces can be answering at
/// the same time — the dock's Notes chat and the General Chat window — and rows from one must
/// never be drawn under the other's answer. The scope is the key a capability already carries in
/// its execution request, so nothing new has to be threaded through the provider loops.
@MainActor
final class ChatResultRowCollector {
    static let shared = ChatResultRowCollector()

    private var rowsByScope: [String: [ChatResultRow]] = [:]
    /// A turn that produced fifty notes is a listing, not a card stack. Past this the answer
    /// text is the right medium and the rows are a distraction.
    private let maximumRowsPerTurn = 24

    private init() {}

    /// Start a turn. Anything left from the previous one in this conversation is dropped —
    /// stale rows under a new answer are worse than none, because they look current.
    func begin(scope: GeneralChatScope?) {
        rowsByScope[key(scope)] = []
    }

    func add(_ rows: [ChatResultRow], scope: GeneralChatScope?) {
        guard !rows.isEmpty else { return }
        let scopeKey = key(scope)
        var existing = rowsByScope[scopeKey] ?? []
        // A capability called twice in one turn appends; the same record twice does not.
        for row in rows where !existing.contains(where: { $0.id == row.id }) {
            existing.append(row)
        }
        rowsByScope[scopeKey] = Array(existing.prefix(maximumRowsPerTurn))
    }

    /// Files a capability found, as rows. The common case, and short enough at the call site
    /// that a capability which already knows its paths has no excuse not to hand them over.
    func addFiles(_ urls: [URL], scope: GeneralChatScope?) {
        add(
            urls.map { url in
                ChatResultRow(
                    kind: .file, id: url.path, title: url.lastPathComponent,
                    subtitle: url.deletingLastPathComponent().path, url: url)
            },
            scope: scope)
    }

    /// Take what this turn produced, clearing it. Called once, where the answer is assembled.
    func take(scope: GeneralChatScope?) -> [ChatResultRow] {
        let scopeKey = key(scope)
        let rows = rowsByScope[scopeKey] ?? []
        rowsByScope[scopeKey] = []
        return rows
    }

    private func key(_ scope: GeneralChatScope?) -> String {
        scope?.storageKey ?? "general"
    }
}

/// Rows onto the fields the message views already draw.
///
/// One mapping, called by each surface at the point it turns an answer into a message. The
/// alternative — each surface building its own rows — is exactly how two hardcoded Notes sites
/// came to exist while every other surface showed nothing.
enum ChatResultRowMapper {

    struct Mapped: Equatable {
        var notes: [NoteSearchAction] = []
        var files: [RecentFileAction] = []
        var links: [PageLinkAction] = []
        var apps: [AppLaunchAction] = []

        var isEmpty: Bool {
            notes.isEmpty && files.isEmpty && links.isEmpty && apps.isEmpty
        }
    }

    static func map(_ rows: [ChatResultRow]) -> Mapped {
        var mapped = Mapped()
        for row in rows {
            switch row.kind {
            case .note:
                mapped.notes.append(
                    NoteSearchAction(
                        id: row.id, title: row.title, folder: row.subtitle,
                        snippet: row.detail, modifiedDate: row.date))
            case .file:
                guard let url = row.url else { continue }
                mapped.files.append(RecentFileAction(url: url))
            case .link:
                guard let url = row.url else { continue }
                mapped.links.append(
                    PageLinkAction(
                        title: row.title.isEmpty ? url.absoluteString : row.title,
                        url: url.absoluteString,
                        pageTitle: row.subtitle))
            case .app:
                mapped.apps.append(
                    AppLaunchAction(
                        label: row.title,
                        systemIcon: row.subtitle.isEmpty ? "app" : row.subtitle,
                        bundleId: row.bundleID ?? row.id))
            }
        }
        return mapped
    }
}
