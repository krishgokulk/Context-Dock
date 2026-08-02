import AppKit
import Foundation

/// The workspace a scoped chat is actually working in: which app, which project, and what
/// that project's state is right now.
///
/// A scope used to know only what an app *can do* (adapters, CLI names, menus) and never what
/// it *is doing*, so "what's happening in VS Code?" had nothing to answer from. Identity is
/// per app **and** project — one Code scope per workspace folder, not one for the editor.
///
/// State is read from three sources, in this order of trust:
///   1. the app's own state files (VS Code's active-folder record — exact, no guessing)
///   2. the scope's linked CLIs, run read-only (`git`, `claude`, `code`)
///   3. the project directory itself (agent config, repo presence)
///
/// Every command is a fixed literal from `readers(for:)`; nothing a model produced is ever
/// interpolated, which is why these can run pre-approved without an approval card.
struct AppWorkspaceIdentity: Equatable, Hashable {
    let bundleId: String
    let appName: String
    /// Stable name for the project ("Context-Dock"), or "" when the app has no project.
    let projectKey: String
    /// Absolute path when the project is a real directory.
    let projectPath: String?

    var cacheKey: String { "\(bundleId)|\(projectKey)" }
}

actor AppWorkspaceService {
    static let shared = AppWorkspaceService()

    private struct Entry {
        let block: String
        let readAt: Date
    }

    private var cache: [String: Entry] = [:]
    /// Long enough that a conversation doesn't re-run git on every turn, short enough that
    /// "what changed?" after a save is still true.
    private let freshness: TimeInterval = 20
    /// A stalled probe must never hold up an answer.
    private let perReaderTimeout: TimeInterval = 2.0

    private init() {}

    // MARK: - Identity

    /// The project the scoped app is currently working in.
    /// - Parameter windowTitle: the app's frontmost window title, when the caller knows it.
    nonisolated static func identity(
        bundleId: String,
        appName: String,
        windowTitle: String? = nil,
        finderFolder: String? = nil
    ) -> AppWorkspaceIdentity {
        switch bundleId {
        case let id where isVSCodeFamily(id):
            if let folder = vsCodeActiveFolder() {
                return AppWorkspaceIdentity(
                    bundleId: bundleId, appName: appName,
                    projectKey: (folder as NSString).lastPathComponent, projectPath: folder)
            }
        case "com.anthropic.claudefordesktop":
            // Claude Desktop and Claude Code are one product. When a Claude Code session is
            // running, the project it works in IS this scope's project — that is what makes
            // "are you the one working in VS Code?" answerable from the Claude scope.
            if let folder = vsCodeActiveFolder() {
                return AppWorkspaceIdentity(
                    bundleId: bundleId, appName: appName,
                    projectKey: (folder as NSString).lastPathComponent, projectPath: folder)
            }
        case "com.apple.dt.Xcode":
            if let title = windowTitle, !title.isEmpty {
                // "MyApp — ContentView.swift" → project is the trailing component.
                let project = title.components(separatedBy: " — ").last?
                    .trimmingCharacters(in: .whitespaces) ?? title
                return AppWorkspaceIdentity(
                    bundleId: bundleId, appName: appName, projectKey: project, projectPath: nil)
            }
        case "com.apple.finder":
            if let folder = finderFolder, !folder.isEmpty {
                return AppWorkspaceIdentity(
                    bundleId: bundleId, appName: appName,
                    projectKey: (folder as NSString).lastPathComponent, projectPath: folder)
            }
        default:
            break
        }
        return AppWorkspaceIdentity(
            bundleId: bundleId, appName: appName, projectKey: "", projectPath: nil)
    }

    nonisolated static func isVSCodeFamily(_ bundleId: String) -> Bool {
        [
            "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
            "com.visualstudio.code.oss", "com.todesktop.230313mzl4w4u92",
        ].contains(bundleId)
    }

    /// VS Code records its active folder as a file URI. Reading it beats parsing a window
    /// title or `code --status`, both of which give only a display name.
    nonisolated static func vsCodeActiveFolder() -> String? {
        let path = NSHomeDirectory()
            + "/Library/Application Support/Code/User/globalStorage/storage.json"
        guard let data = FileManager.default.contents(atPath: path),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let windows = root["windowsState"] as? [String: Any],
            let lastActive = windows["lastActiveWindow"] as? [String: Any],
            let folder = lastActive["folder"] as? String,
            let url = URL(string: folder), url.isFileURL
        else { return nil }
        let resolved = url.path
        return FileManager.default.fileExists(atPath: resolved) ? resolved : nil
    }

    // MARK: - Snapshot

    /// Live state block for the scope's prompt. Cached per app+project.
    func contextBlock(for identity: AppWorkspaceIdentity, linkedCLIs: Set<String>) async -> String {
        if let cached = cache[identity.cacheKey],
            Date().timeIntervalSince(cached.readAt) < freshness
        {
            return cached.block
        }
        let readers = Self.readers(for: identity, linkedCLIs: linkedCLIs)
        guard !readers.isEmpty else { return "" }

        var lines: [String] = []
        for reader in readers {
            guard let value = await run(reader.command, limit: reader.limit), !value.isEmpty else {
                continue
            }
            lines.append("\(reader.label):\n\(value)")
        }
        guard !lines.isEmpty else { return "" }

        var header = "## Live workspace — \(identity.appName)"
        if !identity.projectKey.isEmpty {
            header += " · project “\(identity.projectKey)”"
        }
        if let path = identity.projectPath {
            header += "\n(\(path))"
        }
        let block =
            header + "\n\nRead-only state captured just now. Answer from it as fact; say a "
            + "detail was not readable rather than guessing.\n\n"
            + lines.joined(separator: "\n\n")
        cache[identity.cacheKey] = Entry(block: block, readAt: Date())
        return block
    }

    /// Drops the cached snapshot so the next turn re-reads (used after the scope runs a
    /// command that changes state).
    func invalidate(_ identity: AppWorkspaceIdentity) {
        cache[identity.cacheKey] = nil
    }

    // MARK: - Readers

    private struct Reader {
        let label: String
        let command: String
        var limit: Int = 1_200
    }

    private static func readers(
        for identity: AppWorkspaceIdentity, linkedCLIs: Set<String>
    ) -> [Reader] {
        var readers: [Reader] = []

        // Project state — the same three questions a colleague would ask about any repo.
        if let path = identity.projectPath, isGitRepository(path) {
            let quoted = shellQuoted(path)
            readers.append(
                Reader(label: "Branch and working tree", command: "git -C \(quoted) status -sb", limit: 900))
            readers.append(
                Reader(
                    label: "Last commit",
                    command: "git -C \(quoted) log -1 --pretty=format:'%h %s (%cr, %an)'",
                    limit: 200))
            readers.append(
                Reader(
                    label: "Recently edited files",
                    command:
                        "git -C \(quoted) log --name-only --pretty=format: -3 | sort -u | grep -v '^$' | head -12",
                    limit: 500))
        }

        switch identity.bundleId {
        case let id where isVSCodeFamily(id):
            if linkedCLIs.contains("code"), let binary = installedPath(for: "code") {
                readers.append(
                    Reader(
                        label: "Editor windows and extension host (`code --status`)",
                        command: "\(shellQuoted(binary)) --status | head -60",
                        limit: 2_000))
            }
            readers.append(
                Reader(
                    label: "AI agents running in the editor",
                    command: "pgrep -fl 'claude|codex|copilot' | head -6",
                    limit: 400))

        case "com.anthropic.claudefordesktop":
            if linkedCLIs.contains("claude") {
                readers.append(
                    Reader(
                        label: "Claude Code CLI",
                        command: "claude --version 2>&1 | head -2",
                        limit: 200))
            }
            // The desktop app and the CLI are one product: a running Claude Code session is
            // this scope's work, even though it lives inside another editor's window.
            readers.append(
                Reader(
                    label: "Claude Code sessions running now",
                    command: "pgrep -fl 'claude' | grep -v 'Claude.app' | head -6",
                    limit: 400))

        default:
            break
        }

        // Agent configuration in the project — what instructions this workspace already has.
        if let path = identity.projectPath {
            let quoted = shellQuoted(path)
            readers.append(
                Reader(
                    label: "Agent configuration present",
                    command:
                        "ls -1 \(quoted)/CLAUDE.md \(quoted)/AGENTS.md \(quoted)/.claude "
                        + "\(quoted)/.vscode 2>/dev/null | head -8",
                    limit: 300))
        }
        return readers
    }

    private static func isGitRepository(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path + "/.git")
    }

    private static func installedPath(for command: String) -> String? {
        TerminalPackageManager.shared.packages.first {
            $0.command == command && $0.isInstalled
        }?.installedPath
    }

    /// Single-quote for /bin/sh. Only system-derived paths reach this — never model output.
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func run(_ command: String, limit: Int) async -> String? {
        let result: (success: Bool, output: String)? = await withTaskGroup(
            of: (success: Bool, output: String)?.self
        ) { group in
            group.addTask {
                await TerminalCommandExecutor.shared.runPreApproved(command)
            }
            group.addTask { [perReaderTimeout] in
                try? await Task.sleep(nanoseconds: UInt64(perReaderTimeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let result, result.success else { return nil }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(limit))
    }
}
