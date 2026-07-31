// SafariBrowserBridge.swift
// Context-Dock
//
// Reads the rich page-context payload that SafariWebExtensionHandler writes
// into the shared App Group UserDefaults store. Publishes it as a Combine
// publisher so any part of the app can react instantly when Safari's page
// context changes (new page, text selected, scroll, etc.).
//
// Data flow:
//   JS content_script  →  background.js  →  sendNativeMessage
//   →  SafariWebExtensionHandler.swift   →  App Group UserDefaults
//   →  SafariBrowserBridge (Darwin notification)  →  @Published latestContext

import Foundation
import Combine

// MARK: - Shared container

// IMPORTANT: mirrored verbatim from Context-DockExtension/SafariWebExtensionHandler.swift.
// The appex is a separate compilation unit, so the two copies must be kept in sync by hand.
//
// Why a file and not UserDefaults(suiteName:): this app is NOT sandboxed while the extension
// IS. For a non-sandboxed process the suite resolves to ~/Library/Preferences/<group>.plist,
// for a sandboxed one to the group container — two different files that never meet. That is
// why the bridge read empty for every caller before this change.
enum SafariBridgeKey {
    static let groupID = "group.com.krishgokul.ContextDock"

    static var containerURL: URL? {
        if let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            return url
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/\(groupID)")
    }

    static var bridgeDirectory: URL? {
        containerURL?.appendingPathComponent("SafariBridge", isDirectory: true)
    }

    static var payloadURL: URL? {
        bridgeDirectory?.appendingPathComponent("latest.json")
    }

    /// Command queued for the extension to pick up on its next action click.
    static var pendingCommandURL: URL? {
        bridgeDirectory?.appendingPathComponent("pending.json")
    }

    static func resultURL(requestId: String) -> URL? {
        bridgeDirectory?
            .appendingPathComponent("results", isDirectory: true)
            .appendingPathComponent("\(requestId).json")
    }
}

// MARK: - Model

struct SafariPageContext {
    let url: String
    let title: String
    let selectedText: String
    let pageText: String
    let description: String
    let scrollPercent: Int
    let activeFieldText: String
    let trigger: String          // "load" | "select" | "navigate" | "scroll"
    let timestamp: Date          // page clock (display only — never trust for freshness)
    let receivedAt: Date         // stamped by the extension process

    var hasSelectedText: Bool { !selectedText.isEmpty }

    // Convenience: the first 5 000 chars of page text, suitable for AI context
    var pageTextForAI: String { String(pageText.prefix(5000)) }

    /// Fill blanks from an earlier capture of the same page. Lightweight triggers
    /// (scroll, select) omit the expensive fields; this restores them.
    func merging(carryingOver previous: SafariPageContext) -> SafariPageContext {
        SafariPageContext(
            url:             url,
            title:           title.isEmpty ? previous.title : title,
            selectedText:    selectedText,
            pageText:        pageText.isEmpty ? previous.pageText : pageText,
            description:     description.isEmpty ? previous.description : description,
            scrollPercent:   scrollPercent,
            activeFieldText: activeFieldText,
            trigger:         trigger,
            timestamp:       timestamp,
            receivedAt:      receivedAt
        )
    }
}

// MARK: - Bridge

final class SafariBrowserBridge: ObservableObject {
    static let shared = SafariBrowserBridge()

    @Published private(set) var latestContext: SafariPageContext? = nil
    @Published private(set) var isExtensionActive: Bool = false

    /// How the extension pipeline is doing. Surfaced in Settings so a dead bridge is
    /// visible instead of silently degrading every caller to AppleScript.
    enum ConnectionState: Equatable {
        case neverConnected          // no payload has ever been written
        case idle(lastSeen: Date)    // connected before, nothing recent
        case live(lastSeen: Date)    // payload within the freshness window
    }

    @Published private(set) var connection: ConnectionState = .neverConnected

    private let darwinName = "com.krishgokul.ContextDock.browserContextDidUpdate"
    private let activateDarwinName = "com.krishgokul.ContextDock.browserActivateDock"

    /// Last non-empty selection, kept separately so a scroll or navigate payload
    /// arriving right after the user selects text doesn't wipe the selection.
    private var lastSelection: (text: String, at: Date)?

    private init() {
        loadStoredContext()
        registerDarwinObserver()
    }

    deinit {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(
            center, observer, CFNotificationName(darwinName as CFString), nil
        )
        CFNotificationCenterRemoveObserver(
            center, observer, CFNotificationName(activateDarwinName as CFString), nil
        )
    }

    // MARK: - Public API

    /// The most-recently received page context, or nil if the extension has
    /// never sent data (i.e. user hasn't enabled it in Safari Preferences).
    func currentContext() -> SafariPageContext? { latestContext }

    /// True when context was received within the last 30 seconds. Uses the extension's
    /// receipt time, not the page's `Date.now()` — a page with a skewed clock must not be
    /// able to make stale context look fresh (or fresh context look stale).
    var isFresh: Bool {
        guard let ctx = latestContext else { return false }
        return Date().timeIntervalSince(ctx.receivedAt) < 30
    }

    // MARK: - Private

    private func loadStoredContext() {
        guard
            let url = SafariBridgeKey.payloadURL,
            let data = try? Data(contentsOf: url),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            var incoming = decode(dict)
        else { return }

        // Scroll/select payloads ship without page text to keep native messages
        // small — carry the last full capture forward while we're on the same page.
        if let previous = latestContext, previous.url == incoming.url {
            incoming = incoming.merging(carryingOver: previous)
        }

        latestContext = incoming
        isExtensionActive = true
        connection = Date().timeIntervalSince(incoming.receivedAt) < 30
            ? .live(lastSeen: incoming.receivedAt)
            : .idle(lastSeen: incoming.receivedAt)
        trackSelection(in: incoming)

        // Teach the link resolver this title→url live, so Safari history/bookmark
        // rows can resolve a favicon without Full Disk Access (no History.db read).
        if !incoming.title.isEmpty, let url = URL(string: incoming.url) {
            SafariLinkResolver.shared.record(title: incoming.title, url: url)
        }
    }

    private func trackSelection(in ctx: SafariPageContext) {
        if ctx.hasSelectedText {
            lastSelection = (ctx.selectedText, ctx.receivedAt)
        } else if ctx.trigger == "select" || ctx.trigger == "navigate" {
            // The page told us the selection is gone — don't keep serving it.
            lastSelection = nil
        }
    }

    private func registerDarwinObserver() {
        // Darwin notifications cross the process boundary — the extension fires one
        // every time it writes a new payload, and we wake up here on the main thread.
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, _, _, _ in
                guard let obs = observer else { return }
                let bridge = Unmanaged<SafariBrowserBridge>.fromOpaque(obs).takeUnretainedValue()
                DispatchQueue.main.async { bridge.loadStoredContext() }
            },
            darwinName as CFString, nil,
            .deliverImmediately
        )

        // Safari toolbar button — refresh context first, then ask the app to open.
        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, _, _, _ in
                guard let obs = observer else { return }
                let bridge = Unmanaged<SafariBrowserBridge>.fromOpaque(obs).takeUnretainedValue()
                DispatchQueue.main.async {
                    bridge.loadStoredContext()
                    NotificationCenter.default.post(name: .browserActivateDockRequested,
                                                    object: nil)
                }
            },
            activateDarwinName as CFString, nil,
            .deliverImmediately
        )
    }

    private func decode(_ d: [String: Any]) -> SafariPageContext? {
        guard let url = d["url"] as? String, !url.isEmpty else { return nil }
        let tsMillis = d["timestamp"] as? Double ?? 0
        let date = tsMillis > 0
            ? Date(timeIntervalSince1970: tsMillis / 1000)
            : Date()
        let received = (d["receivedAt"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? date
        return SafariPageContext(
            url:             url,
            title:           d["title"] as? String ?? "",
            selectedText:    d["selectedText"] as? String ?? "",
            pageText:        d["pageText"] as? String ?? "",
            description:     d["description"] as? String ?? "",
            scrollPercent:   d["scrollPercent"] as? Int ?? 0,
            activeFieldText: d["activeFieldText"] as? String ?? "",
            trigger:         d["trigger"] as? String ?? "unknown",
            timestamp:       date,
            receivedAt:      received
        )
    }
}

// MARK: - ContextDetector integration helpers

extension SafariBrowserBridge {

    /// Drop-in replacement for ContextDetector.getSafariContext() —
    /// returns fresh data from the extension if available, else nil
    /// (caller should fall back to AppleScript).
    func safariContextIfFresh() -> (url: String, title: String)? {
        guard isFresh, let ctx = latestContext else { return nil }
        return (url: ctx.url, title: ctx.title)
    }

    /// Returns selected text from the current Safari page if the user selected it
    /// within the last 10 seconds. Tracked independently of the latest payload —
    /// a scroll tick landing after the selection must not hide it.
    func selectedTextIfRecent() -> String? {
        guard
            let selection = lastSelection,
            Date().timeIntervalSince(selection.at) < 10
        else { return nil }
        return selection.text
    }

    /// Build an AI context block from the current page.
    func aiContextBlock() -> String {
        guard let ctx = latestContext else { return "" }
        var parts: [String] = []
        parts.append("URL: \(ctx.url)")
        if !ctx.title.isEmpty     { parts.append("Title: \(ctx.title)") }
        if !ctx.description.isEmpty { parts.append("Description: \(ctx.description)") }
        if ctx.hasSelectedText    { parts.append("Selected text: \(ctx.selectedText)") }
        if !ctx.pageTextForAI.isEmpty {
            parts.append("Page content:\n\(ctx.pageTextForAI)")
        }
        return parts.joined(separator: "\n")
    }
}
