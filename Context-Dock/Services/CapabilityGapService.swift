import Foundation

/// Answers "the user asked for something this app scope cannot do — what would make it possible?"
///
/// Before this, a scoped chat with no matching route could only narrate ("open Terminal and
/// run…"), which pushes the work back onto the user. The missing capability is almost always one
/// CLI away, and the app already knows which tools are installed and which are linked to the
/// scope. So: detect the gap, name the exact tool, and offer the one action that closes it —
/// link it, or install then link it. Nothing happens without the user pressing the button.
@MainActor
final class CapabilityGapService {
    static let shared = CapabilityGapService()
    private init() {}

    enum Resolution: Equatable {
        /// The tool is installed on this Mac but not linked to this app scope.
        /// `provisional` marks a link the scorer guessed at: it works immediately, but it is
        /// only advertised to the model when the question names it, and it is unlinked again
        /// if it never actually runs.
        case linkInstalledTool(
            packageID: UUID, command: String, appName: String, provisional: Bool)
        /// Nothing installed can do it; a well-known formula can.
        case installTool(command: String, formula: String, appName: String)
    }

    struct Gap: Identifiable, Equatable {
        let id = UUID()
        let query: String
        let bundleID: String
        let appName: String
        let resolution: Resolution
        /// One line the UI shows: why this tool, in the user's terms.
        let rationale: String
    }

    /// Well-known task → CLI mapping, used only when nothing installed already fits. Deliberately
    /// small and boring: these are the tools a Homebrew user would reach for anyway, and each
    /// entry still ends in an approval dialog before anything is installed.
    private struct KnownTool {
        let keywords: [String]
        let command: String
        let formula: String
        let rationale: String
    }

    private let catalog: [KnownTool] = [
        // Order matters: the first entry whose keyword appears wins, so "download … as mp3" must
        // reach yt-dlp before any transcoding tool claims the "mp3" keyword.
        KnownTool(
            keywords: ["download", "youtube", "playlist", "rip ", "save video", "save audio"],
            command: "yt-dlp", formula: "yt-dlp",
            rationale: "yt-dlp downloads video and audio from web pages, including audio-only extraction."),
        KnownTool(
            keywords: ["convert video", "transcode", "trim video", "gif from", "ffmpeg", "mux"],
            command: "ffmpeg", formula: "ffmpeg",
            rationale: "ffmpeg converts and edits audio/video files that are already on disk."),
        KnownTool(
            keywords: ["clone", "repo", "repository", "git ", "checkout", "pull request"],
            command: "git", formula: "git",
            rationale: "git clones and manages repositories."),
        KnownTool(
            keywords: ["pdf to", "docx", "markdown from", "pandoc", "convert document"],
            command: "pandoc", formula: "pandoc",
            rationale: "pandoc converts documents between formats."),
        KnownTool(
            keywords: ["resize image", "crop image", "image magick", "imagemagick", "montage"],
            command: "magick", formula: "imagemagick",
            rationale: "ImageMagick batch-edits images."),
        KnownTool(
            keywords: ["download file", "fetch url", "wget", "mirror site"],
            command: "wget", formula: "wget",
            rationale: "wget downloads files and mirrors pages."),
    ]

    /// Nil when the scope can already do it (a linked tool matches), or when nothing sensible
    /// would help — in which case the normal AI answer path runs untouched.
    func resolve(query: String, bundleID: String, appName: String) -> Gap? {
        let normalized = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > 3, !bundleID.isEmpty else { return nil }
        // A question wants an answer, not a tool. "what is this app used for?" is asking
        // about the scope, and no linked CLI would help.
        guard !Self.looksLikeQuestion(normalized) else { return nil }

        let manager = TerminalPackageManager.shared
        // 1. Already linked and plausibly relevant → no gap, let the model use it.
        let linked = manager.packages.filter {
            $0.isEnabled && $0.contextAppBundleIds.contains(bundleID)
        }
        if linked.contains(where: { matches($0, query: normalized) }) { return nil }

        // 2. Known task → known tool, FIRST. The generic scorer ranks by keyword overlap, so
        //    "download this video as mp3" scored HandBrakeCLI (video, convert) above yt-dlp and
        //    offered to link a transcoder for a download. When the task is one we recognise, the
        //    tool is not a guess.
        if let known = catalog.first(where: { tool in
            tool.keywords.contains { normalized.contains($0) }
        }) {
            if let installed = manager.packages.first(where: {
                $0.command == known.command && $0.isInstalled
            }) {
                guard !installed.contextAppBundleIds.contains(bundleID) else { return nil }
                return Gap(
                    query: query,
                    bundleID: bundleID,
                    appName: appName,
                    resolution: .linkInstalledTool(
                        packageID: installed.id, command: installed.command, appName: appName,
                        provisional: false),
                    rationale: known.rationale)
            }
            return Gap(
                query: query,
                bundleID: bundleID,
                appName: appName,
                resolution: .installTool(
                    command: known.command, formula: known.formula, appName: appName),
                rationale: known.rationale)
        }

        // 3. Unrecognised task: fall back to the generic scorer over installed tools.
        //
        // This branch is a guess, and a wrong guess here is expensive: the caller shows the
        // gap card *instead of* resolving an in-app route, so the request never reaches the
        // menus. "new private window" in Safari offered to link an installed tool called
        // new-localization — findPackageForQuery splits a package name into words and scores
        // any overlap ("new") with no floor, then discards the score. So this branch now
        // requires two things the scorer cannot give on its own.
        if appLikelyHandlesItself(query: normalized, bundleID: bundleID, appName: appName) {
            return nil
        }
        if let installed = manager.findPackageForQuery(query),
            installed.isInstalled,
            queryNamesTool(installed, query: normalized),
            !installed.contextAppBundleIds.contains(bundleID)
        {
            return Gap(
                query: query,
                bundleID: bundleID,
                appName: appName,
                resolution: .linkInstalledTool(
                    packageID: installed.id, command: installed.command, appName: appName,
                    provisional: true),
                rationale: installed.description.isEmpty
                    ? "\(installed.command) is installed but not available in the \(appName) scope."
                    : installed.description)
        }
        return nil
    }

    private static func looksLikeQuestion(_ normalized: String) -> Bool {
        if normalized.hasSuffix("?") { return true }
        let starts = [
            "what", "why", "how", "who", "when", "where", "which", "explain", "tell me",
            "describe", "is ", "are ", "does ", "do ", "did ", "can ", "should ",
        ]
        return starts.contains(where: normalized.hasPrefix)
    }

    /// True when the app's own capabilities plausibly cover the request, so proposing a CLI
    /// tool would be answering a question the app already answers. Only the strict test
    /// counts: every meaningful word of the request must appear in one menu item's title or
    /// path, the same bar `bestMenuMatch` applies before it will click a menu.
    private func appLikelyHandlesItself(
        query: String, bundleID: String, appName: String
    ) -> Bool {
        let tokens = query
            .split { !$0.isLetter && !$0.isNumber }
            .map { String($0).lowercased() }
            .filter { $0.count > 1 }
        guard !tokens.isEmpty else { return false }

        let strongAdapterMatch = AppAdapterManager.shared
            .scoredActions(for: bundleID, query: query)
            .contains { $0.score >= AppAdapterManager.adapterActionStrongMatchScore }
        if strongAdapterMatch { return true }

        // Built-in/imported tools are first-class App Adapter capabilities too. The gap
        // service used to inspect only custom actions and menus, so "export … Downloads"
        // matched yt-dlp's broad "download" keyword before scoped chat could select
        // notes.export. Never advertise a CLI when an enabled registered capability fits.
        if !AppAdapterCapabilityCatalog.registeredCandidates(
            appName: appName, bundleID: bundleID, query: query
        ).isEmpty {
            return true
        }

        let menus = AppMenuCapabilityCache.shared.menuItems(
            bundleIdentifier: bundleID, appName: appName, query: query, maxResults: 8)
        return menus.contains { item in
            let haystack = (item.path + [item.title]).joined(separator: " ").lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    /// True when the request actually names the tool — its command, or its full package name.
    /// A shared name *fragment* is not enough for an unrecognised task: `new-localization`
    /// contributed only the word "new".
    private func queryNamesTool(_ package: TerminalPackage, query: String) -> Bool {
        // Whole words only. A substring test matched the tool `pp` inside "what is this app
        // used for?" and offered to link it — the check meant to stop weak guesses became
        // one itself.
        let words = Set(
            query.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init))
        let command = package.command.lowercased()
        let name = package.name.lowercased()
        if !command.isEmpty, words.contains(command) { return true }
        // A multi-word package name has to appear as a phrase, so compare on word boundaries
        // rather than raw containment.
        if !name.isEmpty, name != command {
            let nameWords = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
            if !nameWords.isEmpty, nameWords.allSatisfy({ words.contains($0) }) { return true }
        }
        return false
    }

    private func matches(_ package: TerminalPackage, query: String) -> Bool {
        let haystack = ([package.command, package.name, package.description]
            + package.keywords + package.taskCategories)
            .joined(separator: " ")
            .lowercased()
        // Any meaningful word shared between the request and the tool's own vocabulary.
        return query.split(separator: " ")
            .filter { $0.count > 3 }
            .contains { haystack.contains($0) }
    }

    /// Grants the scope access to an installed tool. This is the whole "permission" step —
    /// the user pressed the button, so the link is written and the tool becomes callable for
    /// this app only.
    func link(packageID: UUID, to bundleID: String, provisional: Bool = false) {
        let manager = TerminalPackageManager.shared
        guard var package = manager.packages.first(where: { $0.id == packageID }) else { return }
        if provisional {
            CLILinkTrustStore.shared.markProvisional(command: package.command, bundleID: bundleID)
        } else {
            CLILinkTrustStore.shared.markTrusted(command: package.command, bundleID: bundleID)
        }
        guard !package.contextAppBundleIds.contains(bundleID) else { return }
        package.contextAppBundleIds.append(bundleID)
        package.isEnabled = true
        manager.updatePackage(package)
    }

    /// Links a tool by command name after an install finishes (the package list is rescanned by
    /// the caller first, so the freshly installed binary is present).
    func linkCommand(_ command: String, to bundleID: String, provisional: Bool = false) -> Bool {
        let manager = TerminalPackageManager.shared
        guard let package = manager.packages.first(where: { $0.command == command }) else {
            return false
        }
        link(packageID: package.id, to: bundleID, provisional: provisional)
        return true
    }
}
