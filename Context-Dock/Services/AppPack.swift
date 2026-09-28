// AppPack.swift
// Context-Dock
//
// An App Pack is what the UI calls an app's adapter — its actions, skills, menu commands,
// tools and context readers — and, for the System packs, a topic's Global Commands
// (SystemConnectors). Settings ▸ App Packs lists one row per pack with a single on/off.
//
// A view over the existing stores, not a new one: an app pack's switch is the adapter's own
// `isEnabled`, a System pack's is its commands' `isEnabled`, and nothing here is persisted.
// The type names (`AppAdapter`, `SystemCommand`) and their stored keys are unchanged.

import Foundation

/// How many things a pack brings, in the words the row shows.
struct AppPackCounts: Equatable {
    var actions = 0
    var skills = 0
    var menuCommands = 0
    var tools = 0
    var contextReaders = 0

    /// "12 actions · 2 skills · 29 menu commands · 3 tools". Kinds the pack has none of are
    /// left out rather than listed as zero.
    var summary: String {
        let parts = [
            Self.phrase(actions, "action"),
            Self.phrase(skills, "skill"),
            Self.phrase(menuCommands, "menu command"),
            Self.phrase(tools, "tool"),
            Self.phrase(contextReaders, "context reader"),
        ].compactMap { $0 }
        return parts.isEmpty ? "Nothing yet" : parts.joined(separator: " · ")
    }

    private static func phrase(_ count: Int, _ noun: String) -> String? {
        count > 0 ? "\(count) \(noun)\(count == 1 ? "" : "s")" : nil
    }
}

/// What an app pack links beyond its own actions, read from the stores that own each kind.
/// Supplied by the caller so the list can be built — and tested — without those stores.
struct AppPackResources: Equatable {
    var skills = 0
    var menuCommands = 0
    /// Built-in tools, CLI tools and linked MCP servers.
    var tools = 0
    var mcpServers: [MCPServerConfig] = []

    static let none = AppPackResources()
}

struct AppPack: Identifiable, Equatable {
    enum Kind: Equatable, Hashable {
        case app(bundleID: String)
        case system(SystemConnectorGroup)
    }

    let kind: Kind
    let name: String
    /// SF Symbol shown when the app is not installed, and for every System pack.
    let symbol: String
    let isEnabled: Bool
    let counts: AppPackCounts
    let sendsDataOut: Bool

    var id: String {
        switch kind {
        case .app(let bundleID): return "app:" + bundleID
        case .system(let group): return "system:" + group.rawValue
        }
    }

    var bundleID: String? {
        if case .app(let bundleID) = kind { return bundleID }
        return nil
    }

    var isSystem: Bool {
        if case .system = kind { return true }
        return false
    }
}

// MARK: - Sends data out (pure)

extension AppPack {
    /// Whether anything in the pack can send data off this Mac: an AI prompt (it goes to the
    /// chosen provider), a send-to or share, a web URL, a script that reaches the network,
    /// or an MCP server that is not a local process.
    static func sendsDataOut(actions: [AdapterAction], mcpServers: [MCPServerConfig] = []) -> Bool {
        actions.contains { sendsDataOut($0) } || mcpServers.contains { isRemote($0) }
    }

    /// The same question for a System pack: its commands run scripts, so only a script that
    /// reaches the network sends anything out.
    static func sendsDataOut(commands: [SystemCommand]) -> Bool {
        commands.contains { reachesNetwork($0.script) || reachesNetwork($0.valueScript) }
    }

    static func sendsDataOut(_ action: AdapterAction) -> Bool {
        switch action.type {
        case .aiPrompt:
            return true
        case .urlScheme, .openItem:
            if let url = action.urlScheme, isWebURL(url) { return true }
        case .shell, .applescript, .jxa, .scriptFile, .pageJS:
            if let script = action.script, reachesNetwork(script) { return true }
        case .menubar, .shortcut, .cliTool, .savePageMarkdown:
            break
        }
        // Send-to: a menu command, shortcut or action whose name says it hands content on.
        let names = [action.name, action.menuPath?.last, action.shortcutName].compactMap { $0 }
        return names.contains(where: namesASendTo)
    }

    /// A server started as a local process speaks stdio; anything else is reached over the
    /// network.
    static func isRemote(_ server: MCPServerConfig) -> Bool {
        let transport = server.transport.lowercased().trimmingCharacters(in: .whitespaces)
        return (!transport.isEmpty && transport != "stdio") || isWebURL(server.command)
    }

    private static func isWebURL(_ string: String) -> Bool {
        let s = string.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return s.hasPrefix("http://") || s.hasPrefix("https://")
    }

    private static let networkMarkers = [
        "http://", "https://", "curl ", "wget ", "fetch(", "xmlhttprequest",
        "open location", "ssh ", "scp ", "rsync ",
    ]

    private static func reachesNetwork(_ script: String) -> Bool {
        let s = script.lowercased()
        return networkMarkers.contains { s.contains($0) }
    }

    /// Whole words only: "Share…" and "Send to Kindle" are send-tos, "Shared Albums" is not.
    private static let sendWords: Set<String> = ["send", "share", "upload", "email"]

    private static func namesASendTo(_ name: String) -> Bool {
        let words = name.lowercased().split { !$0.isLetter }.map(String.init)
        return words.contains { sendWords.contains($0) }
    }
}

// MARK: - The list (pure)

enum AppPacks {
    /// Every installed pack: the app packs in the adapter store's order, then the System
    /// packs in their fixed order. A System pack is listed even when all its commands are
    /// off, so it can be turned back on.
    static func all(
        adapters: [AppAdapter], commands: [SystemCommand],
        resources: (String) -> AppPackResources
    ) -> [AppPack] {
        let apps = adapters.filter { !$0.bundleId.isEmpty }.map { adapter in
            appPack(adapter, resources: resources(adapter.bundleId))
        }
        let system = SystemConnectors.connectors(from: commands, includingDisabled: true)
            .map(systemPack)
        return apps + system
    }

    static func appPack(_ adapter: AppAdapter, resources: AppPackResources) -> AppPack {
        AppPack(
            kind: .app(bundleID: adapter.bundleId),
            name: adapter.appName.isEmpty ? adapter.bundleId : adapter.appName,
            symbol: adapter.icon,
            isEnabled: adapter.isEnabled,
            counts: AppPackCounts(
                actions: adapter.actions.count,
                skills: resources.skills,
                menuCommands: resources.menuCommands,
                tools: resources.tools,
                contextReaders: adapter.contextReaders.count),
            sendsDataOut: AppPack.sendsDataOut(
                actions: adapter.actions, mcpServers: resources.mcpServers))
    }

    static func systemPack(_ connector: SystemConnector) -> AppPack {
        AppPack(
            kind: .system(connector.group),
            name: connector.group.title,
            symbol: connector.group.symbol,
            // On while any of its commands is: turning the last one off turns the pack off.
            isEnabled: connector.commands.contains(where: \.isEnabled),
            counts: AppPackCounts(actions: connector.commands.count),
            sendsDataOut: AppPack.sendsDataOut(commands: connector.commands))
    }

    // MARK: The switch

    /// The adapters after turning one app pack on or off. Every other adapter is untouched.
    static func adapters(
        _ adapters: [AppAdapter], settingBundleID bundleID: String, enabled: Bool
    ) -> [AppAdapter] {
        adapters.map { adapter in
            guard adapter.bundleId == bundleID else { return adapter }
            var changed = adapter
            changed.isEnabled = enabled
            return changed
        }
    }

    /// The commands after turning one System pack on or off: every command the pack lists
    /// (the runnable ones in its topic). Commands outside it — another topic, or a picker
    /// with nothing to run — keep their state.
    static func commands(
        _ commands: [SystemCommand], settingGroup group: SystemConnectorGroup, enabled: Bool
    ) -> [SystemCommand] {
        commands.map { command in
            guard GlobalCommandCapabilities.isRunnable(command),
                  SystemConnectorGroup.group(for: command) == group
            else { return command }
            var changed = command
            changed.isEnabled = enabled
            return changed
        }
    }
}
