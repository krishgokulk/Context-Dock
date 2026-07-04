//
//  AdapterIntegrationSeeder.swift
//  Context-Dock
//
//  Seeds the best real integration channel (CLI today; MCP/API entries can join
//  the catalog later) into app adapters, so apps like Obsidian, Tailscale or
//  Ollama get their CLI linked automatically instead of only a starter action.
//
//  Rules:
//  - Runs once per launch, after adapters load.
//  - Each bundle id is seeded at most once ever (UserDefaults set) — unlinking
//    a CLI does not bring it back on relaunch.
//  - A CLI is linked when its binary is found on disk. If the catalog provides
//    an install hint, an "uninstalled" package is seeded anyway so the adapter
//    shows the recommended tool with how to get it.
//  - Creates the adapter itself when the app is installed but has no adapter
//    yet (e.g. Obsidian).
//

import AppKit
import Foundation

@MainActor
enum AdapterIntegrationSeeder {

    // MARK: - Catalog

    private struct CLISpec {
        let name: String
        /// Binary names (searched in standard bin dirs) or absolute paths.
        let candidates: [String]
        let description: String
        let keywords: [String]
        /// When set, the package is seeded even if the binary is missing,
        /// with this hint in the notes. When nil, missing binary = skip.
        let installHint: String?
    }

    private struct Spec {
        let appName: String
        let icon: String
        let bundleIds: [String]     // some apps ship under multiple ids (Tailscale)
        let clis: [CLISpec]
    }

    private static let catalog: [Spec] = [
        Spec(
            appName: "Obsidian", icon: "text.book.closed", bundleIds: ["md.obsidian"],
            clis: [CLISpec(
                name: "Obsidian CLI", candidates: ["obs", "obsidian-cli"],
                description: "Open, search and create Obsidian notes from the terminal",
                keywords: ["obsidian", "notes", "vault"],
                installHint: "brew install yakitrak/yakitrak/obsidian-cli"
            )]
        ),
        Spec(
            appName: "Tailscale", icon: "network",
            bundleIds: ["io.tailscale.ipn.macsys", "io.tailscale.ipn.macos"],
            clis: [CLISpec(
                name: "Tailscale CLI",
                candidates: ["tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"],
                description: "Manage the tailnet: status, ping, exit nodes, file transfer",
                keywords: ["tailscale", "vpn", "network"],
                installHint: nil
            )]
        ),
        Spec(
            appName: "Ollama", icon: "brain", bundleIds: ["com.electron.ollama"],
            clis: [CLISpec(
                name: "Ollama CLI", candidates: ["ollama"],
                description: "Run, pull and manage local LLMs",
                keywords: ["ollama", "llm", "model"],
                installHint: nil
            )]
        ),
        Spec(
            appName: "HandBrake", icon: "film", bundleIds: ["fr.handbrake.HandBrake"],
            clis: [CLISpec(
                name: "HandBrakeCLI", candidates: ["handbrakecli", "HandBrakeCLI"],
                description: "Transcode video from the command line",
                keywords: ["handbrake", "video", "encode"],
                installHint: nil
            )]
        ),
        Spec(
            appName: "IINA", icon: "play.rectangle", bundleIds: ["com.colliderli.iina"],
            clis: [CLISpec(
                name: "iina-cli",
                candidates: ["iina-cli", "/Applications/IINA.app/Contents/MacOS/iina-cli"],
                description: "Open media in IINA from the terminal",
                keywords: ["iina", "video", "player"],
                installHint: nil
            )]
        ),
        Spec(
            appName: "qBittorrent", icon: "arrow.down.circle",
            bundleIds: ["org.qbittorrent.qBittorrent"],
            clis: [CLISpec(
                name: "qbt", candidates: ["qbt"],
                description: "Manage qBittorrent torrents from the terminal",
                keywords: ["qbittorrent", "torrent"],
                installHint: nil
            )]
        ),
        Spec(
            appName: "Claude", icon: "sparkle", bundleIds: ["com.anthropic.claudefordesktop"],
            clis: [CLISpec(
                name: "Claude Code", candidates: ["claude"],
                description: "Anthropic's agentic coding CLI",
                keywords: ["claude", "ai", "code"],
                installHint: nil
            )]
        ),
        Spec(
            appName: "Codex", icon: "chevron.left.forwardslash.chevron.right",
            bundleIds: ["com.openai.codex"],
            clis: [CLISpec(
                name: "Codex CLI", candidates: ["codex"],
                description: "OpenAI's agentic coding CLI",
                keywords: ["codex", "ai", "code"],
                installHint: "npm install -g @openai/codex"
            )]
        ),
        Spec(
            appName: "Visual Studio Code", icon: "chevron.left.forwardslash.chevron.right",
            bundleIds: ["com.microsoft.VSCode"],
            clis: [CLISpec(
                name: "VS Code CLI",
                candidates: [
                    "code",
                    "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
                ],
                description: "Open files, folders and diffs in VS Code",
                keywords: ["vscode", "code", "editor"],
                installHint: nil
            )]
        ),
        Spec(
            appName: "GitHub Desktop", icon: "arrow.triangle.branch",
            bundleIds: ["com.github.GitHubClient"],
            clis: [CLISpec(
                name: "GitHub CLI", candidates: ["gh"],
                description: "Issues, PRs, repos and workflows from the terminal",
                keywords: ["github", "gh", "git"],
                installHint: "brew install gh"
            )]
        ),
    ]

    // MARK: - Entry point

    private static let seededKey = "adapterIntegrationSeededBundles"
    private static var didRunThisLaunch = false

    /// Seed integrations for all catalog apps that are installed. Creates missing
    /// adapters, then links each CLI to every matching adapter bundle id.
    static func seedIfNeeded() async {
        guard !didRunThisLaunch else { return }
        didRunThisLaunch = true

        var seeded = Set(UserDefaults.standard.stringArray(forKey: seededKey) ?? [])
        var changed = false

        for spec in catalog {
            let installedIds = spec.bundleIds.filter {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
            }
            guard let primaryId = installedIds.first else { continue }
            guard !seeded.contains(primaryId) else { continue }

            if AppAdapterManager.shared.adapters.first(where: { $0.bundleId == primaryId }) == nil {
                await AppAdapterManager.shared.createAdapter(
                    appName: spec.appName, bundleId: primaryId, icon: spec.icon)
            }
            for cli in spec.clis {
                linkCLI(cli, to: primaryId)
            }
            seeded.insert(primaryId)
            changed = true
        }

        if changed {
            UserDefaults.standard.set(Array(seeded).sorted(), forKey: seededKey)
        }
    }

    // MARK: - CLI linking

    private static func linkCLI(_ spec: CLISpec, to bundleId: String) {
        let mgr = TerminalPackageManager.shared

        // Already a package for this command? Just attach the app pill.
        if let existing = mgr.packages.first(where: { pkg in
            spec.candidates.contains(pkg.command)
                || spec.candidates.contains(where: { $0.hasSuffix("/" + pkg.command) })
        }) {
            guard !existing.contextAppBundleIds.contains(bundleId) else { return }
            var updated = existing
            updated.contextAppBundleIds = (existing.contextAppBundleIds + [bundleId]).sorted()
            mgr.updatePackage(updated)
            return
        }

        let resolved = resolveBinary(spec.candidates)
        if resolved == nil && spec.installHint == nil { return }

        let package = TerminalPackage(
            name: spec.name,
            command: resolved?.command ?? spec.candidates[0],
            description: spec.description,
            installedPath: resolved?.path,
            keywords: spec.keywords,
            customNotes: resolved == nil ? "Not installed. Install with: \(spec.installHint ?? "")" : "",
            contextAppBundleIds: [bundleId]
        )
        mgr.addPackage(package)

        // Populate --help knowledge in the background so scoped chat can use it.
        if let resolved {
            let packageId = package.id
            Task {
                guard let help = await mgr.scanHelpText(
                    for: resolved.command, binary: resolved.path) else { return }
                await MainActor.run {
                    guard var pkg = mgr.packages.first(where: { $0.id == packageId }) else { return }
                    pkg.helpText = help
                    mgr.updatePackage(pkg)
                }
            }
        }
    }

    /// Find the first existing binary among the candidates. Names are searched in
    /// the standard user bin dirs; absolute paths are checked directly.
    private static func resolveBinary(_ candidates: [String]) -> (command: String, path: String)? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let binDirs = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
            "\(home)/.local/bin", "\(home)/go/bin", "\(home)/.cargo/bin",
            "\(home)/.npm-global/bin",
        ]
        for candidate in candidates {
            if candidate.hasPrefix("/") {
                if fm.isExecutableFile(atPath: candidate) {
                    return ((candidate as NSString).lastPathComponent, candidate)
                }
                continue
            }
            for dir in binDirs {
                let path = "\(dir)/\(candidate)"
                if fm.isExecutableFile(atPath: path) {
                    return (candidate, path)
                }
            }
        }
        return nil
    }
}
