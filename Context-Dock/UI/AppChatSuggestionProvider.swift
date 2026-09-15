// AppChatSuggestionProvider.swift
// Context-Dock
//
// What the App Chat prompt offers before the user has typed anything.
//
// The suggestions are read from what the app has actually cached, never invented: menu
// actions come from AppMenuCapabilityCache, which is the same snapshot the dock's own
// menu routing uses. The summary line counts only what can be counted — an app with no
// cached menu yet gets a short line or none, rather than a confident number nobody
// measured.

import AppKit
import Foundation

@MainActor
enum AppChatSuggestionProvider {
    /// Top of the list: the actions this app exposes right now.
    static func suggestions(for app: NSRunningApplication?, limit: Int = 3)
        -> [AppChatSuggestion]
    {
        guard let app else { return [] }
        let items = AppMenuCapabilityCache.shared.menuItems(for: app, maxResults: limit * 4)
        var seen = Set<String>()
        var result: [AppChatSuggestion] = []
        for item in items where item.isEnabled {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, seen.insert(title).inserted else { continue }
            result.append(
                AppChatSuggestion(icon: "bolt.fill", title: title, kind: .action))
            if result.count == limit { break }
        }
        return result
    }

    /// "5 actions · 2 skills" — only the parts that were actually counted, and only about
    /// this app. `SystemCommandsRegistry` is macOS's own always-on commands (Wi-Fi, volume,
    /// sleep) — the same fixed count regardless of which app is scoped — and it used to be
    /// folded into this line as if it were part of what the app itself offered, so a Terminal
    /// summary and a Safari summary quoted the identical "commands" number by coincidence.
    /// A missing count is left out rather than shown as zero, because "0 skills" reads as
    /// a measured fact and this is an absent one.
    static func summary(for app: NSRunningApplication?) -> String {
        guard let app, let bundleID = app.bundleIdentifier else { return "" }
        var parts: [String] = []

        if let record = AppMenuCapabilityCache.shared.summary(bundleIdentifier: bundleID),
            record.recordCount > 0
        {
            parts.append(pluralised(record.recordCount, "action"))
        }

        return parts.joined(separator: " · ")
    }

    private static func pluralised(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}
