// SafariCapabilityRouter.swift
// Context-Dock
//
// Per-app capability routing for DoraX Action Chat.
//
// General AI Chat understands the task; an App Capability Router chooses the BEST
// route for that app — not "menu click by default". Deterministic route order:
//
//   1. Native app API / app adapter
//   2. MCP/API integration
//   3. CLI tool
//   4. Shortcut / App Intent
//   5. Keyboard shortcut
//   6. Verified menu command
//   7. AX click fallback (last resort, live-verified)
//
// Safari examples this router encodes:
//   "summarize this page"      → extension/bridge page context → AIProviderRouter (never a menu)
//   "open <x> history page"    → cached history URL → open URL (never AX-click the History menu)
//   "bookmark this page"       → adapter capability → ⌘D shortcut → verified menu fallback
//   "download youtube audio"   → current tab URL → yt-dlp CLI (never a Safari menu)
//   "new private window"       → falls through to the generic adapter/shortcut/menu ranking

import AppKit
import Foundation

// MARK: - Router protocol

/// One per app. Returns a resolution when it has an app-specific best route,
/// or nil to fall through to the generic adapter/menu/shortcut ranking.
/// Same constraints as the resolver: cached metadata only, never execute,
/// never live-scan AX menus.
@MainActor
protocol AppCapabilityRouting {
    var bundleID: String { get }
    func route(actionPhrase: String, original: String) async -> GeneralAIActionResolution?
}

// MARK: - Safari

@MainActor
final class SafariCapabilityRouter: AppCapabilityRouting {
    let bundleID = "com.apple.Safari"

    func route(actionPhrase: String, original: String) async -> GeneralAIActionResolution? {
        let phrase = actionPhrase.lowercased()

        if phrase.contains("summarize") || phrase.contains("summarise") {
            return summarizePageResolution()
        }
        if phrase.contains("history") && (phrase.contains("open") || phrase.contains("page")
            || original.lowercased().hasPrefix("open ")) {
            return openHistoryResolution(phrase: phrase)
        }
        if phrase.contains("bookmark") {
            return bookmarkPageResolution()
        }
        if phrase.contains("download")
            && (phrase.contains("audio") || phrase.contains("video")
                || phrase.contains("youtube") || phrase.contains("music")) {
            return downloadMediaResolution(phrase: phrase)
        }
        // Everything else ("new private window", "new tab", …) uses the generic
        // adapter → shortcut → verified-menu ranking in the resolver.
        return nil
    }

    // MARK: "summarize this page" — extension/bridge context + provider, never a menu

    private func summarizePageResolution() -> GeneralAIActionResolution {
        var candidates: [DoraXActionCandidate] = []

        // Route 1: Safari Web Extension context (freshest — URL/title/visible text pushed
        // by the extension), summarized through AIProviderRouter.
        if SafariBrowserBridge.shared.isFresh,
           let context = SafariBrowserBridge.shared.currentContext(),
           !context.pageText.isEmpty {
            var candidate = DoraXActionCandidate(
                id: "safari.bridge.summarize",
                title: "Summarize “\(String(context.title.prefix(60)))”",
                appName: "Safari",
                bundleID: bundleID,
                source: .api,
                route: .automation,
                capabilityID: nil,
                requiredInputs: [],
                riskLevel: .low,
                confidence: 0.9,
                permissionKey: "generalAI.execute.com.apple.Safari.summarizePage",
                debugReason: "Safari extension page context is fresh")
            candidate.inputValues = ["url": context.url, "title": context.title]
            candidates.append(candidate)
        }

        // Route 2: registered capability (AX web snapshot + provider) as fallback.
        if CapabilityRegistry.shared.capability(id: "safari.summarizePage") != nil {
            candidates.append(DoraXActionCandidate(
                id: "capability.safari.summarizePage",
                title: "Summarize Current Safari Page",
                appName: "Safari",
                bundleID: bundleID,
                source: .system,
                route: .adapter,
                capabilityID: "safari.summarizePage",
                requiredInputs: [],
                riskLevel: .low,
                confidence: 0.75,
                permissionKey: "generalAI.execute.com.apple.Safari.summarizePage",
                debugReason: "safari.summarizePage capability registered"))
        }

        guard !candidates.isEmpty else {
            return .explain(
                "I can summarize Safari pages, but no page context is available — "
                + "enable the DoraX Safari extension (Safari → Settings → Extensions) "
                + "or open the page in Safari and try again.")
        }
        return .candidates(candidates)
    }

    // MARK: "open <x> history page" — cached history URL, never the History menu

    private func openHistoryResolution(phrase: String) -> GeneralAIActionResolution {
        let searchTerm = phrase
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !["open", "history", "page", "my", "from", "that", "this", "the"].contains($0) }
            .joined(separator: " ")
        guard !searchTerm.isEmpty else {
            return .clarify(
                question: "Which history page? Give me part of its title or site name.",
                options: [])
        }
        let matches = SafariRecentURLService.shared.entries(matching: searchTerm, limit: 4)
        guard let best = matches.first else {
            return .explain(
                "No page matching “\(searchTerm)” is in the Safari history cache — "
                + "nothing was opened.")
        }
        if matches.count > 1 {
            let sameHost = matches.allSatisfy { $0.domain == best.domain }
            if !sameHost {
                return .clarify(
                    question: "Which history page should I open?",
                    options: matches.map { "\($0.title.isEmpty ? $0.url.absoluteString : $0.title) — \($0.domain)" })
            }
        }
        var candidate = DoraXActionCandidate(
            id: "safari.history.open.\(best.url.absoluteString.hashValue)",
            title: "Open “\(String((best.title.isEmpty ? best.domain : best.title).prefix(60)))”",
            appName: "Safari",
            bundleID: bundleID,
            source: .system,
            route: .automation,
            capabilityID: nil,
            requiredInputs: [],
            riskLevel: .low,
            confidence: 0.88,
            permissionKey: "generalAI.execute.com.apple.Safari.openHistoryURL",
            debugReason: "cached Safari history match — opens the URL, never AX-clicks the History menu")
        candidate.inputValues = ["url": best.url.absoluteString, "automation": "safari.openURL"]
        return .candidates([candidate])
    }

    // MARK: "bookmark this page" — adapter → ⌘D → verified menu

    private func bookmarkPageResolution() -> GeneralAIActionResolution {
        var candidates: [DoraXActionCandidate] = []

        // Route 1: Safari adapter bookmark capability, if the user installed one.
        let adapterActions = AppAdapterManager.shared.actions(for: bundleID, query: "bookmark")
        if let action = adapterActions.first {
            var candidate = DoraXActionCandidate(
                id: "adapter.\(bundleID).\(action.id)",
                title: "Safari: \(action.name)",
                appName: "Safari",
                bundleID: bundleID,
                source: .appAdapter,
                route: .adapter,
                capabilityID: nil,
                requiredInputs: [],
                riskLevel: .low,
                confidence: 0.88,
                permissionKey: "generalAI.execute.com.apple.Safari.adapter.bookmark",
                debugReason: "Safari adapter bookmark action")
            candidate.adapterActionID = action.id
            candidates.append(candidate)
        }

        // Route 2: ⌘D on the current tab (native Safari shortcut).
        var shortcut = DoraXActionCandidate(
            id: "kbd.\(bundleID).add-bookmark",
            title: "Safari: Add Bookmark",
            appName: "Safari",
            bundleID: bundleID,
            source: .keyboardShortcut,
            route: .keyboardShortcut,
            capabilityID: nil,
            requiredInputs: [],
            riskLevel: .low,
            confidence: 0.82,
            permissionKey: "generalAI.execute.com.apple.Safari.addBookmark",
            debugReason: "native ⌘D bookmark shortcut on the current tab")
        shortcut.menuPath = ["Bookmarks", "Add Bookmark…"]
        shortcut.shortcutChar = "d"
        shortcut.shortcutModifiers = 0
        if let context = SafariBrowserBridge.shared.safariContextIfFresh() {
            shortcut.caveat = "Bookmarks the current tab (\(context.title))."
        }
        candidates.append(shortcut)

        return .candidates(candidates)
    }

    // MARK: "download youtube audio" — current tab URL → yt-dlp CLI, never a menu

    private func downloadMediaResolution(phrase: String) -> GeneralAIActionResolution {
        guard let toolPath = installedYtDlpPath() else {
            return .explain(
                "Downloading media needs the yt-dlp CLI tool, which isn't installed. "
                + "Install it with “brew install yt-dlp”, then ask again.")
        }
        // Ground on the real current tab URL from the extension/bridge — never guess.
        guard let context = SafariBrowserBridge.shared.safariContextIfFresh(),
              context.url.contains("youtube.com/watch") || context.url.contains("youtu.be/")
        else {
            return .clarify(
                question: "Which video? Open it in Safari first (I read the current tab), "
                    + "or paste the URL.",
                options: [])
        }
        let audioOnly = phrase.contains("audio") || phrase.contains("music")
        let format = audioOnly ? "-x --audio-format mp3" : "-f best"
        var candidate = DoraXActionCandidate(
            id: "cli.ytdlp.download",
            title: audioOnly
                ? "Download audio of “\(String(context.title.prefix(50)))”"
                : "Download “\(String(context.title.prefix(50)))”",
            appName: "Safari",
            bundleID: bundleID,
            source: .cli,
            route: .cli,
            capabilityID: nil,
            requiredInputs: ["command"],
            riskLevel: .high,
            confidence: 0.85,
            permissionKey: "generalAI.execute.cli.yt-dlp.download",
            debugReason: "current tab is a YouTube URL + yt-dlp installed at \(toolPath)")
        candidate.inputValues = [
            "command": "\(toolPath) \(format) -P ~/Downloads \"\(context.url)\""
        ]
        candidate.caveat = "Saves to ~/Downloads."
        return .candidates([candidate])
    }

    private func installedYtDlpPath() -> String? {
        ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
