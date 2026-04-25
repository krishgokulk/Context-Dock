// SafariDeepContextStubs.swift
// Context-Dock
//
// SafariDeepContextReader: reads Safari history via AppleScript and injects
// relevant entries into the AI context block.
//
// ContextAppSuggestionsRow: suggests apps and extensions for the current context
// (files, text, URL) using IntelligentExtensionMatcher + DefaultAppResolver.

import SwiftUI
import AppKit

// MARK: - SafariDeepContextReader

final class SafariDeepContextReader {
    static let shared = SafariDeepContextReader()
    private init() {}

    /// Returns a formatted block of Safari history entries relevant to `query`.
    /// Uses AppleScript to read history — no private APIs.
    func contextBlock(
        query: String,
        maxRecentHistory: Int,
        maxMatchedHistory: Int,
        maxBookmarks: Int,
        maxCharacters: Int
    ) -> String {
        let history = fetchHistory(query: query,
                                   maxRecent: maxRecentHistory,
                                   maxMatched: maxMatchedHistory)
        guard !history.isEmpty else { return "" }

        var lines = ["\n## Safari History (relevant to query)"]
        for entry in history.prefix(maxMatched + maxRecentHistory) {
            lines.append("- \(entry.title.isEmpty ? entry.url : entry.title) — \(entry.url)")
        }
        let block = lines.joined(separator: "\n")
        return String(block.prefix(maxCharacters))
    }

    // MARK: - Private

    private struct HistoryEntry {
        let title: String
        let url: String
    }

    private func fetchHistory(query: String, maxRecent: Int, maxMatched: Int) -> [HistoryEntry] {
        // Read recent Safari history via AppleScript
        let script = """
        tell application "Safari"
            set historyItems to history items
            set result to {}
            set maxItems to \(maxRecent + maxMatched)
            set count to 0
            repeat with h in historyItems
                if count >= maxItems then exit repeat
                try
                    set hTitle to name of h
                    set hURL to URL of h
                    set end of result to hTitle & "|||" & hURL
                    set count to count + 1
                end try
            end repeat
            return result
        end tell
        """
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script),
              let output = appleScript.executeAndReturnError(&error).stringValue
        else { return [] }

        let q = query.lowercased()
        let entries: [HistoryEntry] = output
            .components(separatedBy: ", ")
            .compactMap { raw -> HistoryEntry? in
                let parts = raw.components(separatedBy: "|||")
                guard parts.count == 2 else { return nil }
                return HistoryEntry(title: parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
                                    url: parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
            }

        guard !q.isEmpty else { return Array(entries.prefix(maxRecent)) }

        // Prioritise entries whose title or URL contains the query
        let matched = entries.filter {
            $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q)
        }
        let recent = entries.filter {
            !$0.title.lowercased().contains(q) && !$0.url.lowercased().contains(q)
        }
        let combined = Array(matched.prefix(maxMatched)) + Array(recent.prefix(maxRecent))
        return Array(combined.prefix(maxMatched + maxRecent))
    }
}

// MARK: - ContextAppSuggestionsRow

/// Shows "Open With" app chips and relevant extension chips for the current context.
/// Displayed at the bottom of AIModeView when files, text, or a URL is selected.
struct ContextAppSuggestionsRow: View {
    let context: AppUserContext
    let onOpenWith: (DefaultAppResolver.DefaultApp) -> Void
    let onRunExtension: (ScriptExtension) -> Void

    @State private var apps: [DefaultAppResolver.DefaultApp] = []
    @State private var extensions: [SuggestedExtension] = []

    var body: some View {
        Group {
            if !apps.isEmpty || !extensions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(apps.prefix(5)) { app in
                            appChip(app)
                        }
                        ForEach(extensions.prefix(4)) { suggestion in
                            extensionChip(suggestion)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(height: 36)
            }
        }
        .task(id: contextKey) { await load() }
    }

    // MARK: - Chips

    private func appChip(_ app: DefaultAppResolver.DefaultApp) -> some View {
        Button {
            onOpenWith(app)
        } label: {
            HStack(spacing: 4) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 14, height: 14)
                }
                Text(app.displayName)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(7)
        }
        .buttonStyle(.plain)
    }

    private func extensionChip(_ suggestion: SuggestedExtension) -> some View {
        Button {
            onRunExtension(suggestion.scriptExtension)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: suggestion.scriptExtension.type.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(suggestion.scriptExtension.name)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.08))
            .cornerRadius(7)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Loading

    private var contextKey: String {
        switch context {
        case .filesSelected(let urls): return urls.map(\.path).joined(separator: ",")
        case .textSelected(let t):     return String(t.prefix(40))
        case .url(let s):              return s
        default:                        return ""
        }
    }

    @MainActor
    private func load() async {
        let detectedContext = toDetectedContext(context)

        // App suggestions (only for files)
        if case .filesSelected(let urls) = context, !urls.isEmpty {
            apps = DefaultAppResolver.shared.getAllApps(for: urls[0]).prefix(5).map { $0 }
        } else {
            apps = []
        }

        // Extension suggestions
        let suggestions = IntelligentExtensionMatcher.shared.suggestExtensions(for: detectedContext)
        extensions = Array(suggestions.prefix(4))
    }

    private func toDetectedContext(_ ctx: AppUserContext) -> DetectedContext {
        switch ctx {
        case .filesSelected(let urls): return .files(urls)
        case .textSelected(let t):     return .text(t)
        case .url(let s):              return .browserTab(url: s, title: "")
        default:                        return .text("")
        }
    }
}
