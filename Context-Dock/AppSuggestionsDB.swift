import SwiftUI
import Foundation

// MARK: - Suggestion Models

struct SuggestedQuickAction {
    let name: String
    let iconName: String
    let actionType: AppShortcut.ActionType
    let actionValue: String
    let description: String  // shown in tooltip / subtitle
}

struct SuggestedCLIExtension {
    let toolName: String
    let knownPaths: [String]   // checked in order; first found = installed
    let aiHint: String
    let installCmd: String     // e.g. "brew install spt"
    let installMethod: String  // "brew" | "builtin" | "cargo" | "npm"

    var installedPath: String? {
        knownPaths.first { FileManager.default.fileExists(atPath: $0) }
    }
    var isInstalled: Bool { installedPath != nil }
}

struct AppSuggestionEntry {
    let appNames: [String]     // lowercase match keys, e.g. ["spotify", "spotify.app"]
    let summary: String        // one-liner shown in suggestions card
    let quickActions: [SuggestedQuickAction]
    let cliExtensions: [SuggestedCLIExtension]
}

// MARK: - Database

enum AppSuggestionsDB {

    static let all: [AppSuggestionEntry] = [

        // MARK: Amphetamine
        AppSuggestionEntry(
            appNames: ["amphetamine"],
            summary: "Prevent your Mac from sleeping via AppleScript or caffeinate CLI",
            quickActions: [
                SuggestedQuickAction(name: "Keep Awake Forever", iconName: "bolt.fill",
                    actionType: .shellCommand,
                    actionValue: "osascript -e 'tell application \"Amphetamine\" to start new session with options {duration:0, interval:minutes, displaySleepAllowed:false}'",
                    description: "Starts an indefinite Amphetamine session"),
                SuggestedQuickAction(name: "Keep Awake 1 Hour", iconName: "clock.fill",
                    actionType: .shellCommand,
                    actionValue: "osascript -e 'tell application \"Amphetamine\" to start new session with options {duration:60, interval:minutes, displaySleepAllowed:false}'",
                    description: "60-minute Amphetamine session"),
                SuggestedQuickAction(name: "End Session", iconName: "stop.circle",
                    actionType: .shellCommand,
                    actionValue: "osascript -e 'tell application \"Amphetamine\" to end current session'",
                    description: "Stops the current Amphetamine session"),
                SuggestedQuickAction(name: "Open Amphetamine", iconName: "app",
                    actionType: .openFile,
                    actionValue: "/Applications/Amphetamine.app",
                    description: "Launch Amphetamine"),
            ],
            cliExtensions: [
                SuggestedCLIExtension(
                    toolName: "caffeinate",
                    knownPaths: ["/usr/bin/caffeinate"],
                    aiHint: "Use caffeinate to prevent Mac sleeping. caffeinate -t 3600 (1h), caffeinate -d (display awake), caffeinate -i (idle sleep). Kill with: pkill caffeinate",
                    installCmd: "",
                    installMethod: "builtin")
            ]
        ),

        // MARK: Spotify
        AppSuggestionEntry(
            appNames: ["spotify"],
            summary: "Control playback via AppleScript; use spt CLI for full terminal control",
            quickActions: [
                SuggestedQuickAction(name: "Play / Pause", iconName: "playpause.fill",
                    actionType: .shellCommand,
                    actionValue: "osascript -e 'tell application \"Spotify\" to playpause'",
                    description: "Toggle Spotify playback"),
                SuggestedQuickAction(name: "Next Track", iconName: "forward.fill",
                    actionType: .shellCommand,
                    actionValue: "osascript -e 'tell application \"Spotify\" to next track'",
                    description: "Skip to next song"),
                SuggestedQuickAction(name: "Previous Track", iconName: "backward.fill",
                    actionType: .shellCommand,
                    actionValue: "osascript -e 'tell application \"Spotify\" to previous track'",
                    description: "Go back one song"),
                SuggestedQuickAction(name: "Now Playing", iconName: "music.note",
                    actionType: .shellCommand,
                    actionValue: "osascript -e 'tell application \"Spotify\" to return name of current track & \" — \" & artist of current track'",
                    description: "Show current track"),
            ],
            cliExtensions: [
                SuggestedCLIExtension(
                    toolName: "spt",
                    knownPaths: ["/opt/homebrew/bin/spt", "/usr/local/bin/spt", "\(NSHomeDirectory())/.cargo/bin/spt"],
                    aiHint: "Use spt (spotify-tui) for terminal Spotify control: spt playback --toggle, spt playback --next, spt search \"artist\" --tracks",
                    installCmd: "brew install spt",
                    installMethod: "brew")
            ]
        ),

        // MARK: VS Code
        AppSuggestionEntry(
            appNames: ["visual studio code", "vscode", "code"],
            summary: "Open files/folders in VS Code; use the code CLI to open from terminal",
            quickActions: [
                SuggestedQuickAction(name: "New Window", iconName: "macwindow.badge.plus",
                    actionType: .shellCommand,
                    actionValue: "code --new-window",
                    description: "Open a blank VS Code window"),
                SuggestedQuickAction(name: "Open Projects Folder", iconName: "folder",
                    actionType: .shellCommand,
                    actionValue: "code ~/Projects",
                    description: "Open ~/Projects in VS Code"),
            ],
            cliExtensions: [
                SuggestedCLIExtension(
                    toolName: "code",
                    knownPaths: ["/usr/local/bin/code", "/opt/homebrew/bin/code",
                                 "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"],
                    aiHint: "Use `code` CLI: code <path> (open file/folder), code --diff a b (diff), code --install-extension <id>, code --list-extensions",
                    installCmd: "Shell Command: Install 'code' from VS Code menu",
                    installMethod: "builtin")
            ]
        ),

        // MARK: Xcode
        AppSuggestionEntry(
            appNames: ["xcode"],
            summary: "Build, test, and manage simulators via xcodebuild and xcrun",
            quickActions: [
                SuggestedQuickAction(name: "Open Simulator", iconName: "iphone",
                    actionType: .shellCommand,
                    actionValue: "open -a Simulator",
                    description: "Launch iOS Simulator"),
                SuggestedQuickAction(name: "Clean DerivedData", iconName: "trash",
                    actionType: .shellCommand,
                    actionValue: "rm -rf ~/Library/Developer/Xcode/DerivedData",
                    description: "Clears Xcode derived data"),
            ],
            cliExtensions: [
                SuggestedCLIExtension(
                    toolName: "xcodebuild",
                    knownPaths: ["/usr/bin/xcodebuild"],
                    aiHint: "Use xcodebuild: xcodebuild build/test/clean, xcodebuild -list (show targets), xcrun simctl list (simulators)",
                    installCmd: "xcode-select --install",
                    installMethod: "builtin"),
                SuggestedCLIExtension(
                    toolName: "xcrun",
                    knownPaths: ["/usr/bin/xcrun"],
                    aiHint: "Use xcrun simctl for simulator control: xcrun simctl list, xcrun simctl boot <udid>, xcrun simctl openurl <udid> <url>",
                    installCmd: "xcode-select --install",
                    installMethod: "builtin")
            ]
        ),

        // MARK: 1Password
        AppSuggestionEntry(
            appNames: ["1password", "1password 7", "1password 8"],
            summary: "Lock vault and manage secrets via the op CLI",
            quickActions: [
                SuggestedQuickAction(name: "Lock 1Password", iconName: "lock.fill",
                    actionType: .shellCommand,
                    actionValue: "osascript -e 'tell application \"1Password 7\" to lock'",
                    description: "Lock the 1Password vault"),
                SuggestedQuickAction(name: "Open 1Password", iconName: "key.fill",
                    actionType: .openURL,
                    actionValue: "onepassword://",
                    description: "Open 1Password"),
            ],
            cliExtensions: [
                SuggestedCLIExtension(
                    toolName: "op",
                    knownPaths: ["/usr/local/bin/op", "/opt/homebrew/bin/op"],
                    aiHint: "Use op (1Password CLI): op item list, op item get \"GitHub\" --fields username,password, op signin, op signout",
                    installCmd: "brew install 1password-cli",
                    installMethod: "brew")
            ]
        ),

        // MARK: GitHub Desktop / gh CLI
        AppSuggestionEntry(
            appNames: ["github desktop", "github"],
            summary: "Manage repos and PRs via the gh CLI",
            quickActions: [
                SuggestedQuickAction(name: "Open GitHub.com", iconName: "globe",
                    actionType: .openURL,
                    actionValue: "https://github.com",
                    description: "Open GitHub in browser"),
            ],
            cliExtensions: [
                SuggestedCLIExtension(
                    toolName: "gh",
                    knownPaths: ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"],
                    aiHint: "Use gh CLI: gh pr list, gh pr create, gh issue list, gh repo clone <owner/repo>, gh run list (CI), gh auth status",
                    installCmd: "brew install gh",
                    installMethod: "brew")
            ]
        ),

        // MARK: Obsidian
        AppSuggestionEntry(
            appNames: ["obsidian"],
            summary: "Open vaults and create notes via URL scheme",
            quickActions: [
                SuggestedQuickAction(name: "New Note", iconName: "square.and.pencil",
                    actionType: .openURL,
                    actionValue: "obsidian://new",
                    description: "Create a new Obsidian note"),
                SuggestedQuickAction(name: "Open Vault", iconName: "lock.open",
                    actionType: .openURL,
                    actionValue: "obsidian://open",
                    description: "Open Obsidian vault"),
                SuggestedQuickAction(name: "Quick Capture", iconName: "bolt.fill",
                    actionType: .openURL,
                    actionValue: "obsidian://new?vault=&content=",
                    description: "Quick note capture"),
            ],
            cliExtensions: [
                SuggestedCLIExtension(
                    toolName: "obsidian-export",
                    knownPaths: ["/opt/homebrew/bin/obsidian-export", "/usr/local/bin/obsidian-export",
                                 "\(NSHomeDirectory())/.cargo/bin/obsidian-export"],
                    aiHint: "Use obsidian-export to export vault to markdown/HTML: obsidian-export <vault-path> <output-path>",
                    installCmd: "brew install obsidian-export",
                    installMethod: "brew")
            ]
        ),

        // MARK: Things 3
        AppSuggestionEntry(
            appNames: ["things", "things 3"],
            summary: "Add tasks and navigate sections via URL scheme",
            quickActions: [
                SuggestedQuickAction(name: "Add Task", iconName: "plus.circle",
                    actionType: .openURL,
                    actionValue: "things:///add?show-quick-entry=true",
                    description: "Open Things quick entry"),
                SuggestedQuickAction(name: "Today", iconName: "sun.max",
                    actionType: .openURL,
                    actionValue: "things:///today",
                    description: "Open Today view"),
                SuggestedQuickAction(name: "Inbox", iconName: "tray",
                    actionType: .openURL,
                    actionValue: "things:///inbox",
                    description: "Open Inbox"),
            ],
            cliExtensions: []
        ),

        // MARK: Notion
        AppSuggestionEntry(
            appNames: ["notion"],
            summary: "Open Notion pages via URL scheme",
            quickActions: [
                SuggestedQuickAction(name: "Open Notion", iconName: "doc.text",
                    actionType: .openURL,
                    actionValue: "notion://",
                    description: "Open Notion app"),
                SuggestedQuickAction(name: "New Page", iconName: "square.and.pencil",
                    actionType: .openURL,
                    actionValue: "notion://www.notion.so/new",
                    description: "Create a new page"),
            ],
            cliExtensions: []
        ),

        // MARK: Slack
        AppSuggestionEntry(
            appNames: ["slack"],
            summary: "Open channels and DMs via Slack URL scheme",
            quickActions: [
                SuggestedQuickAction(name: "Open Slack", iconName: "bubble.left.and.bubble.right",
                    actionType: .openURL,
                    actionValue: "slack://open",
                    description: "Open Slack"),
                SuggestedQuickAction(name: "New Message", iconName: "square.and.pencil",
                    actionType: .openURL,
                    actionValue: "slack://new-message",
                    description: "Start a new DM"),
                SuggestedQuickAction(name: "Set Status", iconName: "person.crop.circle.badge.checkmark",
                    actionType: .shellCommand,
                    actionValue: "open 'slack://open'",
                    description: "Open Slack to set status"),
            ],
            cliExtensions: []
        ),

        // MARK: Apple Music
        AppSuggestionEntry(
            appNames: ["music", "apple music"],
            summary: "Control Apple Music playback via AppleScript",
            quickActions: [
                SuggestedQuickAction(name: "Play / Pause", iconName: "playpause.fill",
                    actionType: .shellCommand,
                    actionValue: "osascript -e 'tell application \"Music\" to playpause'",
                    description: "Toggle playback"),
                SuggestedQuickAction(name: "Next Track", iconName: "forward.fill",
                    actionType: .shellCommand,
                    actionValue: "osascript -e 'tell application \"Music\" to next track'",
                    description: "Skip to next"),
                SuggestedQuickAction(name: "Now Playing", iconName: "music.note",
                    actionType: .shellCommand,
                    actionValue: "osascript -e 'tell application \"Music\" to return name of current track & \" — \" & artist of current track'",
                    description: "Show current track info"),
            ],
            cliExtensions: [
                SuggestedCLIExtension(
                    toolName: "shpotify",
                    knownPaths: ["/opt/homebrew/bin/shpotify", "/usr/local/bin/shpotify"],
                    aiHint: "Use shpotify to control Spotify from terminal: shpotify play/pause/next/previous, shpotify vol up/down, shpotify status",
                    installCmd: "brew install shpotify",
                    installMethod: "brew")
            ]
        ),

        // MARK: Finder
        AppSuggestionEntry(
            appNames: ["finder"],
            summary: "Navigate files with fd, fzf, and ripgrep for AI-powered file search",
            quickActions: [
                SuggestedQuickAction(name: "Open Home", iconName: "house",
                    actionType: .shellCommand,
                    actionValue: "open ~",
                    description: "Open home folder in Finder"),
                SuggestedQuickAction(name: "Open Desktop", iconName: "menubar.rectangle",
                    actionType: .shellCommand,
                    actionValue: "open ~/Desktop",
                    description: "Open Desktop in Finder"),
                SuggestedQuickAction(name: "Open Downloads", iconName: "arrow.down.circle",
                    actionType: .shellCommand,
                    actionValue: "open ~/Downloads",
                    description: "Open Downloads in Finder"),
            ],
            cliExtensions: [
                SuggestedCLIExtension(
                    toolName: "fd",
                    knownPaths: ["/opt/homebrew/bin/fd", "/usr/local/bin/fd"],
                    aiHint: "Use fd for fast file search: fd <name>, fd -e pdf (by extension), fd -t d (directories only), fd . ~/Documents",
                    installCmd: "brew install fd",
                    installMethod: "brew"),
                SuggestedCLIExtension(
                    toolName: "rg",
                    knownPaths: ["/opt/homebrew/bin/rg", "/usr/local/bin/rg"],
                    aiHint: "Use rg (ripgrep) to search file contents: rg <pattern>, rg -t swift <pattern>, rg -l (filenames only), rg -i (case-insensitive)",
                    installCmd: "brew install ripgrep",
                    installMethod: "brew")
            ]
        ),

        // MARK: Bear
        AppSuggestionEntry(
            appNames: ["bear"],
            summary: "Create and open notes via Bear URL scheme",
            quickActions: [
                SuggestedQuickAction(name: "New Note", iconName: "square.and.pencil",
                    actionType: .openURL,
                    actionValue: "bear://x-callback-url/create?title=&text=",
                    description: "Create a new Bear note"),
                SuggestedQuickAction(name: "Search Notes", iconName: "magnifyingglass",
                    actionType: .openURL,
                    actionValue: "bear://x-callback-url/search?term=",
                    description: "Search in Bear"),
            ],
            cliExtensions: []
        ),

        // MARK: OmniFocus
        AppSuggestionEntry(
            appNames: ["omnifocus"],
            summary: "Add tasks and open perspectives via URL scheme",
            quickActions: [
                SuggestedQuickAction(name: "Quick Entry", iconName: "plus.circle",
                    actionType: .openURL,
                    actionValue: "omnifocus:///add",
                    description: "Open OmniFocus quick entry"),
                SuggestedQuickAction(name: "Today (Forecast)", iconName: "sun.max",
                    actionType: .openURL,
                    actionValue: "omnifocus:///forecast",
                    description: "Open Forecast view"),
            ],
            cliExtensions: []
        ),

        // MARK: Homebrew
        AppSuggestionEntry(
            appNames: ["homebrew", "brew"],
            summary: "Manage packages via brew CLI — AI can install, update, and audit",
            quickActions: [
                SuggestedQuickAction(name: "Update All", iconName: "arrow.triangle.2.circlepath",
                    actionType: .shellCommand,
                    actionValue: "brew update && brew upgrade",
                    description: "Update & upgrade all Homebrew packages"),
                SuggestedQuickAction(name: "Brew Doctor", iconName: "stethoscope",
                    actionType: .shellCommand,
                    actionValue: "brew doctor",
                    description: "Check Homebrew health"),
                SuggestedQuickAction(name: "Brew Cleanup", iconName: "trash",
                    actionType: .shellCommand,
                    actionValue: "brew cleanup",
                    description: "Remove old versions"),
            ],
            cliExtensions: [
                SuggestedCLIExtension(
                    toolName: "brew",
                    knownPaths: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"],
                    aiHint: "Use brew: brew install/uninstall/search <pkg>, brew list, brew info <pkg>, brew outdated, brew update && brew upgrade",
                    installCmd: "",
                    installMethod: "builtin")
            ]
        ),

        // MARK: iTerm2
        AppSuggestionEntry(
            appNames: ["iterm2", "iterm"],
            summary: "Launch iTerm profiles and windows via AppleScript",
            quickActions: [
                SuggestedQuickAction(name: "New Window", iconName: "macwindow.badge.plus",
                    actionType: .shellCommand,
                    actionValue: "osascript -e 'tell application \"iTerm2\" to create window with default profile'",
                    description: "Open new iTerm window"),
                SuggestedQuickAction(name: "New Tab", iconName: "plus.rectangle",
                    actionType: .shellCommand,
                    actionValue: "osascript -e 'tell application \"iTerm2\" to tell current window to create tab with default profile'",
                    description: "Open new iTerm tab"),
            ],
            cliExtensions: []
        ),

        // MARK: Docker
        AppSuggestionEntry(
            appNames: ["docker", "docker desktop"],
            summary: "Manage containers and images via docker CLI",
            quickActions: [
                SuggestedQuickAction(name: "Open Docker Dashboard", iconName: "shippingbox",
                    actionType: .openFile,
                    actionValue: "/Applications/Docker.app",
                    description: "Open Docker Desktop"),
            ],
            cliExtensions: [
                SuggestedCLIExtension(
                    toolName: "docker",
                    knownPaths: ["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                                 "/Applications/Docker.app/Contents/Resources/bin/docker"],
                    aiHint: "Use docker: docker ps (running containers), docker images, docker run, docker stop <id>, docker logs <id>, docker compose up/down",
                    installCmd: "Install Docker Desktop from docker.com",
                    installMethod: "brew")
            ]
        ),

        // MARK: qBittorrent
        AppSuggestionEntry(
            appNames: ["qbittorrent"],
            summary: "Manage torrents remotely via qbt CLI (qbittorrent-cli)",
            quickActions: [
                SuggestedQuickAction(name: "Open qBittorrent", iconName: "arrow.down.circle",
                    actionType: .openFile,
                    actionValue: "/Applications/qBittorrent.app",
                    description: "Launch qBittorrent"),
                SuggestedQuickAction(name: "List Torrents", iconName: "list.bullet",
                    actionType: .shellCommand,
                    actionValue: "/opt/homebrew/bin/qbt torrent list",
                    description: "Show all torrents via qbt CLI"),
                SuggestedQuickAction(name: "Pause All", iconName: "pause.circle",
                    actionType: .shellCommand,
                    actionValue: "/opt/homebrew/bin/qbt torrent pause --all",
                    description: "Pause all active torrents"),
                SuggestedQuickAction(name: "Resume All", iconName: "play.circle",
                    actionType: .shellCommand,
                    actionValue: "/opt/homebrew/bin/qbt torrent resume --all",
                    description: "Resume all paused torrents"),
            ],
            cliExtensions: [
                SuggestedCLIExtension(
                    toolName: "qbt",
                    knownPaths: ["/opt/homebrew/bin/qbt", "/usr/local/bin/qbt"],
                    aiHint: "Use qbt (qbittorrent-cli) to manage torrents: qbt torrent list, qbt torrent add <url/magnet>, qbt torrent pause/resume <hash>, qbt torrent delete <hash>, qbt server info. First run: qbt config to set Web API URL + credentials.",
                    installCmd: "brew install qbittorrent-cli",
                    installMethod: "brew")
            ]
        ),
    ]

    /// Match suggestions for a given app key or label (hardcoded database)
    static func suggestions(for appKey: String, label: String = "") -> AppSuggestionEntry? {
        let search = [appKey.lowercased(), label.lowercased()].filter { !$0.isEmpty }
        return all.first { entry in
            search.contains { key in
                entry.appNames.contains { name in
                    key.contains(name) || name.contains(key)
                }
            }
        }
    }

    /// Auto-detect CLI tools from TerminalPackageManager that match the app name.
    /// Used when no hardcoded entry exists — e.g. user adds "qbittorrent" and
    /// TerminalPackageManager already has "qbt" / "qbittorrent-cli" from a --help scan.
    static func autoDetectedCLIs(
        for appKey: String,
        label: String = "",
        installedPackages: [TerminalPackage]
    ) -> [TerminalPackage] {
        // Build search tokens from app key + label
        let tokens: [String] = [appKey, label]
            .flatMap { $0.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted) }
            .filter { $0.count >= 3 }

        guard !tokens.isEmpty else { return [] }

        return installedPackages.filter { pkg in
            let cmd = pkg.command.lowercased()
            let name = pkg.name.lowercased()
            return tokens.contains { token in
                cmd.hasPrefix(token) || cmd.contains(token) ||
                name.contains(token) || token.contains(cmd.prefix(max(cmd.count - 4, 3)))
            }
        }
    }
}

// MARK: - Suggestions Card View

struct AppSuggestionsCard: View {
    let entry: AppSuggestionEntry
    let appKey: String
    /// Tool names already known to TerminalPackageManager (scanned via --help)
    let installedToolNames: Set<String>
    /// Tool name → actual installed path from TerminalPackageManager
    let installedToolPaths: [String: String]
    let onAddShortcut: (AppShortcut) -> Void
    let onAddExtension: (AppToolExtension) -> Void

    @State private var expanded = true

    /// Resolve whether a CLI is installed: file system OR already scanned by TerminalPackageManager
    private func isInstalled(_ cli: SuggestedCLIExtension) -> Bool {
        cli.isInstalled || installedToolNames.contains(cli.toolName)
    }

    private func resolvedPath(_ cli: SuggestedCLIExtension) -> String {
        cli.installedPath
            ?? installedToolPaths[cli.toolName]
            ?? cli.knownPaths.first
            ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.yellow)
                    Text("Suggested for \(appKey.capitalized)")
                        .font(.subheadline).fontWeight(.semibold)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(entry.summary)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            if expanded {
                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    let savedShortcutNames = Set(AppSettings.shared.shortcuts(for: appKey).map { $0.name })
                    let savedToolNames = Set(AppSettings.shared.toolExtensions(for: appKey).map { $0.toolName })

                    // Quick Actions chips
                    if !entry.quickActions.isEmpty {
                        Text("QUICK ACTIONS")
                            .font(.caption2).fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], spacing: 8) {
                            ForEach(entry.quickActions, id: \.name) { action in
                                SuggestionChip(
                                    icon: action.iconName,
                                    title: action.name,
                                    subtitle: action.description,
                                    badgeColor: .blue,
                                    badgeText: action.actionType.rawValue,
                                    alreadyAdded: savedShortcutNames.contains(action.name)
                                ) {
                                    let sc = AppShortcut(name: action.name, iconName: action.iconName,
                                                        actionType: action.actionType,
                                                        actionValue: action.actionValue, appKey: appKey)
                                    onAddShortcut(sc)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                    }

                    // CLI Extensions chips
                    if !entry.cliExtensions.isEmpty {
                        HStack(spacing: 6) {
                            Text("AI EXTENSIONS (CLI)")
                                .font(.caption2).fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            let installedCount = entry.cliExtensions.filter { isInstalled($0) }.count
                            if installedCount > 0 {
                                Text("\(installedCount) installed")
                                    .font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.green.opacity(0.2), in: Capsule())
                                    .foregroundStyle(Color.green)
                            }
                        }
                        .padding(.horizontal, 14)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], spacing: 8) {
                            ForEach(entry.cliExtensions, id: \.toolName) { cli in
                                let installed = isInstalled(cli)
                                SuggestionChip(
                                    icon: "terminal.fill",
                                    title: cli.toolName,
                                    subtitle: installed
                                        ? "Installed ✓  —  tap + to wire to AI"
                                        : (cli.installCmd.isEmpty ? "Built-in macOS tool" : "Install: \(cli.installCmd)"),
                                    badgeColor: installed ? .green : .orange,
                                    badgeText: installed ? "ready" : cli.installMethod,
                                    alreadyAdded: savedToolNames.contains(cli.toolName)
                                ) {
                                    let ext = AppToolExtension(
                                        appKey: appKey,
                                        toolName: cli.toolName,
                                        toolPath: resolvedPath(cli),
                                        aiHint: cli.aiHint)
                                    onAddExtension(ext)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .background(.yellow.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yellow.opacity(0.25), lineWidth: 1))
        .padding(.horizontal, 16).padding(.top, 12)
    }
}

// MARK: - Auto-Detected CLI Card (fuzzy match from TerminalPackageManager)

struct AutoDetectedCLICard: View {
    let appKey: String
    let packages: [TerminalPackage]
    let onAddExtension: (AppToolExtension) -> Void

    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .foregroundStyle(Color.cyan)
                    Text("Auto-detected from My CLI Tools")
                        .font(.subheadline).fontWeight(.semibold)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text("\(packages.count) tool\(packages.count == 1 ? "" : "s") matched \"\(appKey)\"")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            if expanded {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("These tools were found in your My CLI Tools and match the app name. Tap + to wire them to the AI for this app.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.top, 8)

                    let savedTools = Set(AppSettings.shared.toolExtensions(for: appKey).map { $0.toolName })
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], spacing: 8) {
                        ForEach(packages) { pkg in
                            SuggestionChip(
                                icon: "terminal.fill",
                                title: pkg.command,
                                subtitle: pkg.description.isEmpty ? pkg.name : pkg.description,
                                badgeColor: .cyan,
                                badgeText: "scanned",
                                alreadyAdded: savedTools.contains(pkg.command)
                            ) {
                                // Build the richest possible AI hint:
                                // prefer full --help text, fallback to usage examples, fallback to generic
                                let hint: String
                                if let helpText = pkg.helpText, !helpText.isEmpty {
                                    // Trim to first 600 chars so it doesn't bloat the prompt
                                    let trimmed = String(helpText.prefix(600))
                                    hint = "Tool: \(pkg.command)\nDescription: \(pkg.description)\n--help output:\n\(trimmed)"
                                } else if !pkg.usageExamples.isEmpty {
                                    hint = "Use \(pkg.command) for \(pkg.description.isEmpty ? pkg.name : pkg.description). Examples: " + pkg.usageExamples.joined(separator: " | ")
                                } else {
                                    hint = "Use \(pkg.command) to interact with \(appKey). Run \(pkg.command) --help for available commands."
                                }
                                let ext = AppToolExtension(
                                    appKey: appKey,
                                    toolName: pkg.command,
                                    toolPath: pkg.installedPath ?? "",
                                    aiHint: hint)
                                onAddExtension(ext)
                            }
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 12)
                }
            }
        }
        .background(.cyan.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.cyan.opacity(0.25), lineWidth: 1))
        .padding(.horizontal, 16).padding(.top, 8)
    }
}

struct SuggestionChip: View {
    let icon: String
    let title: String
    let subtitle: String
    let badgeColor: Color
    let badgeText: String
    /// Pass true if this tool is already saved in AppSettings — persists across view reloads
    var alreadyAdded: Bool = false
    let onAdd: () -> Void

    @State private var tappedAdd = false

    private var isAdded: Bool { alreadyAdded || tappedAdd }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 22, height: 22)
                .background(badgeColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(badgeColor)

            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).fontWeight(.medium).lineLimit(1)
                Text(isAdded ? "Added to AI Extensions ✓" : subtitle)
                    .font(.caption2).foregroundStyle(isAdded ? Color.green : .secondary).lineLimit(1)
            }

            Spacer(minLength: 4)

            if !isAdded {
                Text(badgeText)
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(badgeColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(badgeColor)
            }

            Button {
                tappedAdd = true
                onAdd()
            } label: {
                Image(systemName: isAdded ? "checkmark" : "plus")
                    .font(.caption).fontWeight(.semibold)
                    .frame(width: 22, height: 22)
                    .background(isAdded ? Color.green.opacity(0.2) : Color.accentColor.opacity(0.15),
                                in: Circle())
                    .foregroundStyle(isAdded ? Color.green : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(isAdded)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}

