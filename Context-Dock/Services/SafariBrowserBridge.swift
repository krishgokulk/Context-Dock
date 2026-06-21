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
    let timestamp: Date

    var hasSelectedText: Bool { !selectedText.isEmpty }

    // Convenience: the first 5 000 chars of page text, suitable for AI context
    var pageTextForAI: String { String(pageText.prefix(5000)) }
}

// MARK: - Bridge

final class SafariBrowserBridge: ObservableObject {
    static let shared = SafariBrowserBridge()

    @Published private(set) var latestContext: SafariPageContext? = nil
    @Published private(set) var isExtensionActive: Bool = false

    private let suiteName = "group.com.krishgokul.ContextDock"
    private let payloadKey = "safariExtension.latestPayload"
    private let updatedKey = "safariExtension.lastUpdated"
    private let darwinName = "com.krishgokul.ContextDock.browserContextDidUpdate"

    private var defaults: UserDefaults?

    private init() {
        defaults = UserDefaults(suiteName: suiteName)
        loadStoredContext()
        registerDarwinObserver()
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(darwinName as CFString),
            nil
        )
    }

    // MARK: - Public API

    /// The most-recently received page context, or nil if the extension has
    /// never sent data (i.e. user hasn't enabled it in Safari Preferences).
    func currentContext() -> SafariPageContext? { latestContext }

    /// True when context was updated within the last 30 seconds.
    var isFresh: Bool {
        guard let ctx = latestContext else { return false }
        return Date().timeIntervalSince(ctx.timestamp) < 30
    }

    // MARK: - Private

    private func loadStoredContext() {
        guard
            let defaults,
            let data = defaults.data(forKey: payloadKey),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        latestContext = decode(dict)
        isExtensionActive = latestContext != nil

        // Teach the link resolver this title→url live, so Safari history/bookmark
        // rows can resolve a favicon without Full Disk Access (no History.db read).
        if let ctx = latestContext, !ctx.title.isEmpty, let url = URL(string: ctx.url) {
            SafariLinkResolver.shared.record(title: ctx.title, url: url)
        }
    }

    private func registerDarwinObserver() {
        // Darwin notifications cross the process boundary — the extension fires one
        // every time it writes a new payload, and we wake up here on the main thread.
        let name = darwinName as CFString
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passRetained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let obs = observer else { return }
                let bridge = Unmanaged<SafariBrowserBridge>.fromOpaque(obs).takeUnretainedValue()
                DispatchQueue.main.async { bridge.loadStoredContext() }
            },
            name, nil,
            .deliverImmediately
        )
    }

    private func decode(_ d: [String: Any]) -> SafariPageContext? {
        guard let url = d["url"] as? String, !url.isEmpty else { return nil }
        let tsMillis = d["timestamp"] as? Double ?? 0
        let date = tsMillis > 0
            ? Date(timeIntervalSince1970: tsMillis / 1000)
            : Date()
        return SafariPageContext(
            url:             url,
            title:           d["title"] as? String ?? "",
            selectedText:    d["selectedText"] as? String ?? "",
            pageText:        d["pageText"] as? String ?? "",
            description:     d["description"] as? String ?? "",
            scrollPercent:   d["scrollPercent"] as? Int ?? 0,
            activeFieldText: d["activeFieldText"] as? String ?? "",
            trigger:         d["trigger"] as? String ?? "unknown",
            timestamp:       date
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

    /// Returns selected text from the current Safari page, if the extension
    /// delivered a "select" trigger within the last 10 seconds.
    func selectedTextIfRecent() -> String? {
        guard
            let ctx = latestContext,
            ctx.hasSelectedText,
            ctx.trigger == "select",
            Date().timeIntervalSince(ctx.timestamp) < 10
        else { return nil }
        return ctx.selectedText
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
