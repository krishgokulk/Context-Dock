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
        case linkInstalledTool(packageID: UUID, command: String, appName: String)
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
        KnownTool(
            keywords: ["download", "video", "mp3", "mp4", "audio", "youtube", "playlist", "rip"],
            command: "yt-dlp", formula: "yt-dlp",
            rationale: "yt-dlp downloads video and audio from web pages."),
        KnownTool(
            keywords: ["convert video", "transcode", "trim video", "gif from", "ffmpeg", "mux"],
            command: "ffmpeg", formula: "ffmpeg",
            rationale: "ffmpeg converts and edits audio/video files."),
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

        let manager = TerminalPackageManager.shared
        // 1. Already linked and plausibly relevant → no gap, let the model use it.
        let linked = manager.packages.filter {
            $0.isEnabled && $0.contextAppBundleIds.contains(bundleID)
        }
        if linked.contains(where: { matches($0, query: normalized) }) { return nil }

        // 2. Installed somewhere on this Mac but not linked to this scope.
        if let installed = manager.findPackageForQuery(query),
            installed.isInstalled,
            !installed.contextAppBundleIds.contains(bundleID)
        {
            return Gap(
                query: query,
                bundleID: bundleID,
                appName: appName,
                resolution: .linkInstalledTool(
                    packageID: installed.id, command: installed.command, appName: appName),
                rationale: installed.description.isEmpty
                    ? "\(installed.command) is installed but not available in the \(appName) scope."
                    : installed.description)
        }

        // 3. Nothing installed fits — name the tool that would.
        guard let known = catalog.first(where: { tool in
            tool.keywords.contains { normalized.contains($0) }
        }) else { return nil }
        // Guard against proposing an install for something already present under another name.
        if manager.packages.contains(where: { $0.command == known.command && $0.isInstalled }) {
            return nil
        }
        return Gap(
            query: query,
            bundleID: bundleID,
            appName: appName,
            resolution: .installTool(
                command: known.command, formula: known.formula, appName: appName),
            rationale: known.rationale)
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
    func link(packageID: UUID, to bundleID: String) {
        let manager = TerminalPackageManager.shared
        guard var package = manager.packages.first(where: { $0.id == packageID }) else { return }
        guard !package.contextAppBundleIds.contains(bundleID) else { return }
        package.contextAppBundleIds.append(bundleID)
        package.isEnabled = true
        manager.updatePackage(package)
    }

    /// Links a tool by command name after an install finishes (the package list is rescanned by
    /// the caller first, so the freshly installed binary is present).
    func linkCommand(_ command: String, to bundleID: String) -> Bool {
        let manager = TerminalPackageManager.shared
        guard let package = manager.packages.first(where: { $0.command == command }) else {
            return false
        }
        link(packageID: package.id, to: bundleID)
        return true
    }
}
