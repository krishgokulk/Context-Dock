// ScopedAppPromptBuilder.swift
// Context-Dock
//
// The system-prompt block that tells the model what an app-scoped chat is scoped to and
// what DoraX can actually drive in that app: adapter actions, verified menu commands,
// linked MCP servers, API connections, Shortcuts, skills and CLI tools.
//
// It lived on LauncherView, which is why the chat window could not use it — LauncherView's
// state dies with the launcher and cannot be reached from another window. The dock passes
// the few things only it knows (the live browser page, the AX window title, the typed
// query); everything else is read from the same singletons either surface can reach. One
// builder, so an app question is grounded identically wherever it is asked.

import AppKit
import Foundation

@MainActor
enum ScopedAppPromptBuilder {

    /// Browsers get browser-shaped context (page, tabs) rather than generic app context.
    static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.brave.Browser",
        "org.chromium.Chromium",
        "com.microsoft.edgemac",
    ]

    static func isBrowserBundle(_ bundleId: String) -> Bool {
        let trimmed = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        // Safari Web Apps (YouTube, YT Music, …) are browsers too — they render a
        // web page and expose its URL via AX, so they get full browser-scope context.
        return browserBundleIDs.contains(trimmed)
            || trimmed.hasPrefix("com.apple.Safari.WebApp")
    }

    /// `cli://tailscale` → `tailscale`. A CLI scope is an executable, not an app.
    static func cliCommand(forScopeBundleID bundleID: String) -> String? {
        guard bundleID.hasPrefix("cli://") else { return nil }
        let command = String(bundleID.dropFirst("cli://".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    /// Drops provisionally-linked CLIs unless the question names them: a guess about which
    /// binary belongs to an app must not be advertised as one of the app's capabilities.
    static func promptRelevantCLIPackages(
        _ packages: [TerminalPackage], bundleId: String, query: String
    ) -> [TerminalPackage] {
        guard !bundleId.isEmpty else { return packages }
        let normalizedQuery = query.lowercased()
        return packages.filter { package in
            let command = package.command.lowercased()
            guard CLILinkTrustStore.shared.isProvisional(command: command, bundleID: bundleId)
            else { return true }
            guard !normalizedQuery.isEmpty else { return false }
            if normalizedQuery.contains(command) { return true }
            let name = package.name.lowercased()
            return !name.isEmpty && normalizedQuery.contains(name)
        }
    }

    /// - Parameters:
    ///   - query: what the user asked, used to decide which provisional CLI links are
    ///     relevant. Empty is fine — it simply keeps them out.
    ///   - windowTitle: the scoped app's front window, when the caller already has it.
    ///   - browserHost: host of the page a browser scope is on, when the caller knows it.
    static func appIdentityBlock(
        bundleId: String,
        appName: String,
        query: String = "",
        compact: Bool = false,
        windowTitle: String? = nil,
        browserHost: String? = nil
    ) -> String {
        guard !bundleId.isEmpty || !appName.isEmpty else { return "" }

        // A `cli://` scope is the executable itself, not an app adapter that happens to
        // have command associations.  Letting it inherit those associations made a `mole`
        // scope advertise `clean-diff` and the model quite reasonably selected the wrong
        // tool.  Keep this capability boundary absolute: one CLI scope, one executable.
        if let command = cliCommand(forScopeBundleID: bundleId) {
            let package = TerminalPackageManager.shared.packages.first {
                $0.command.caseInsensitiveCompare(command) == .orderedSame
            }
            var lines = [
                "## Scoped CLI Tool: \(command) (\(bundleId))",
                "This chat is scoped exclusively to the `\(command)` executable.",
                "Only explain, inspect, or run `\(command)` commands. Do not use a linked app CLI, global CLI, adapter, menu, MCP tool, or a different executable.",
                "For an unknown capability, run `\(command) --help` first; never invent a subcommand or option.",
            ]
            if let description = package?.description,
                !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                lines.append("Description: \(description)")
            }
            // The subcommand list goes in whole and first. It is the tool's table of
            // contents and it is short, whereas the help below is clipped — asking pear to
            // "clean cache" against a head-truncated 30k document dropped list-orphaned and
            // remove-orphaned entirely, and the model correctly reported that the help it was
            // given mentioned no such thing.
            if let package {
                let subcommands = package.subcommands.filter {
                    !LauncherView.helpNoiseTokens.contains($0.lowercased())
                }
                if !subcommands.isEmpty {
                    lines.append(
                        "Subcommands (use a space between command and subcommand): "
                        + subcommands.joined(separator: ", "))
                }
                if !package.provenInvocations.isEmpty {
                    lines.append(
                        "Known-good invocations on this Mac (prefer these spellings): "
                        + package.provenInvocations.prefix(5).joined(separator: " | "))
                }
                // Ranked against the question rather than truncated from the top, and taken
                // from the man page when --help is the shorter stub of the two.
                let help = package.helpText ?? ""
                let man = package.manText ?? ""
                let reference = man.count > help.count * 2 ? man : help
                if !reference.isEmpty {
                    lines.append(
                        "\n## \(command) help reference\n"
                        + AIContextBudget.fitHelpText(reference, query: query, budget: 2_000))
                }
            }
            lines.append(
                "To run a command, emit exactly one JSON line: "
                    + "{\"terminal_call\":{\"command\":\"\(command) <arguments>\",\"purpose\":\"<reason>\"}}. "
                    + "Execution remains subject to Context Dock approval."
            )
            return lines.joined(separator: "\n")
        }

        // What kind of surface is this?
        let surface: String = {
            if bundleId.hasPrefix("com.apple.Safari.WebApp") {
                return "a Safari Web App (the website \(browserHost ?? "it wraps") running as a standalone app)"
            }
            if isBrowserBundle(bundleId) { return "a web browser" }
            return "a macOS app"
        }()

        var lines: [String] = [
            "## Scoped App: \(appName)\(bundleId.isEmpty ? "" : " (\(bundleId))")",
            "This chat is scoped to \(appName) — \(surface). It is the app the user is",
            "currently using. You DO know which app is open: it is \(appName).",
            "Never claim you cannot see which app is open or ask the user what app they mean.",
        ]
        if let windowTitle = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            !windowTitle.isEmpty
        {
            lines.append("Frontmost window title: \"\(windowTitle)\"")
        }

        // Integration inventory
        let adapter = AppAdapterManager.shared.adapters.first { $0.bundleId == bundleId }
        let actions = adapter?.actions ?? []
        let clis = promptRelevantCLIPackages(
            TerminalPackageManager.shared.packages.filter {
                $0.isEnabled && $0.contextAppBundleIds.contains(bundleId)
            },
            bundleId: bundleId,
            query: query
        )
        let mcpServers = MCPServerManager.shared.servers(forBundleId: bundleId)
        let apiConns = APIConnectionStore.shared.connections(for: bundleId)
        let shortcuts = actions.filter { $0.type == .shortcut }
        let skillCount = SkillStore.shared.skills(for: bundleId).filter(\.isEnabled).count

        lines.append("")
        lines.append("Integrations linked to \(appName) (pick the best fit for each request):")
        if actions.isEmpty {
            lines.append("- Actions: none")
        } else {
            lines.append(
                "- Actions — RUN one with the run_adapter_action tool, passing the id below. "
                + "When a request matches an action, CALL it immediately — do NOT describe it, "
                + "do NOT ask \"would you like me to?\". Actions marked [approval] pop a native "
                + "confirmation on their own, so still just call them. Available:")
            for a in actions.prefix(30) {
                let flag = (a.requiresApproval || a.isDestructive) ? " [approval]" : ""
                lines.append("    • \(a.id) — \(a.name)\(flag)")
            }
        }
        lines.append(
            clis.isEmpty
                ? "- CLI tools: none linked"
                : "- CLI tools (fallback only; request with typed terminal_call JSON only when no adapter/MCP/API/Shortcut/menu route fits): "
                    + clis.map { "\($0.command)\($0.isInstalled ? "" : " (not installed)")" }
                        .joined(separator: ", "))
        lines.append(
            mcpServers.isEmpty
                ? "- MCP servers: none linked"
                : "- MCP servers (read the app's data with the run_mcp_tool tool): "
                    + mcpServers.map(\.name).joined(separator: ", "))
        if !apiConns.isEmpty {
            // Stored credentials and a base URL, with no endpoint spec and no executor —
            // so they are context, not a route. Advertising them as callable would have
            // the model propose calls that nothing in DoraX can make.
            lines.append(
                "- API connections (configured, NOT callable from chat — mention them only "
                + "as context): " + apiConns.map(\.name).joined(separator: ", "))
        }
        if !shortcuts.isEmpty {
            lines.append("- macOS Shortcuts: " + shortcuts.compactMap(\.shortcutName).joined(separator: ", "))
        }
        if skillCount > 0 {
            lines.append("- Skills: \(skillCount) active (their instructions follow below)")
        }

        // Verified menu commands — the universal control surface. Any app can be driven
        // through its own menu bar even with zero linked adapters, so this is how the chat
        // DOES things (Minimize, New Tab, Export, Close…) instead of narrating a shortcut.
        if !bundleId.isEmpty {
            let menuItems = AppMenuCapabilityCache.shared.menuItems(
                bundleIdentifier: bundleId, appName: appName, query: "",
                maxResults: compact ? 14 : 60)
            let leaves = menuItems.filter { $0.isLeaf && !$0.path.isEmpty }
            if !leaves.isEmpty {
                lines.append(
                    "- Menu commands — RUN one with the run_menu_command tool, passing the FULL "
                    + "path below. When a request maps to a menu command, CALL it immediately — "
                    + "do NOT tell the user which keyboard shortcut to press, do NOT ask "
                    + "permission (destructive commands like Close/Quit/Delete pop their own "
                    + "confirmation). Available menu commands:")
                var seen = Set<String>()
                for item in leaves {
                    let key = item.path.joined(separator: " > ").lowercased()
                    guard seen.insert(key).inserted else { continue }
                    let shortcut = item.shortcutDisplay.map { " (\($0))" } ?? ""
                    lines.append("    • \(item.path.joined(separator: " ▸ "))\(shortcut)")
                    if seen.count >= (compact ? 12 : 50) { break }
                }
            }
        }

        lines.append("")
        if compact {
            lines.append(
                "Tool choice order: exact saved adapter action → exact live app menu for visible "
                + "UI commands → MCP/API for app data → Shortcut → linked CLI. Never propose a "
                + "tool that is not listed above.")
            return lines.joined(separator: "\n")
        }
        lines.append(
            "Tool choice order: exact saved adapter action → verified live app menu for visible UI commands → MCP/API for app data → Shortcut → linked CLI fallback → answer from "
            + "the live context. Terminal/CLI is last resort: use it only when this app has no adapter/native/MCP/API/Shortcut/menu route that fits the request. Never generate shell or AppleScript for an operation exposed by the scoped app's linked tools or live menu. If no linked integration or menu can do what the user asks, say what "
            + "IS possible now and suggest linking the right tool in Settings → App Adapters → "
            + "\(appName) (Tools tab: MCP, API, Shortcuts, CLI).")
        lines.append(
            "Intent rule: a question is answered from the supplied live context, observed data, "
            + "adapter readers, MCP results, skills, memory, or reference material. Never run a "
            + "menu command merely to discover an answer. Menu commands are for explicit requests "
            + "to change or navigate the app.")
        if !clis.isEmpty {
            lines.append(
                "CLI fallback rule: only when no adapter/native/MCP/API/Shortcut/menu capability "
                + "fits, and a linked CLI can print the information the user wants (status, "
                + "list, current state), run it with the run_command tool instead of asking the "
                + "user to provide it.")
        }
        // One protocol, said once. Every route above is a tool call; a JSON line written into
        // an answer is not a call, it is a description of one, and the user reads the
        // description while nothing happens.
        lines.append(
            "Every route above is called as a TOOL. Never write a tool call as JSON in your "
            + "reply — a line of JSON in an answer runs nothing and is shown to the user as "
            + "gibberish. Call the tool, wait for its result, then answer in plain language.")
        // The whole reason the assistant reads as incurious: it was handed a snapshot and had
        // no way to go and get anything else. Saying the reading tools exist matters as much
        // as having them — a model that does not know it can look will not look.
        // The failure this repeatedly produced: asked what an app does, the model read the
        // one list it had — the menu bar — and recited it. "About, Check for Updates, Hide
        // Others" is true of every Mac app and says nothing about this one.
        lines.append(
            "A MENU LIST IS NOT A DESCRIPTION. The commands above are how you DO things in "
            + "\(appName); they are not what \(appName) is for. If the user asks what the app "
            + "does or can do, answer from its documentation — read it with read_url if a link "
            + "is listed above and no summary was supplied — and if there is none, say you "
            + "have no description of the app rather than listing its menus.")
        lines.append(
            "LOOK BEFORE YOU ANSWER. read_page reads the page in front of the user, read_url "
            + "fetches a link, read_file reads a document or source file, read_selection reads "
            + "what they have highlighted. All four are read-only and need no approval, so "
            + "reach for them freely: a question about \"this page\", \"this file\" or "
            + "\"these\" is answered by reading it first, never from memory and never with "
            + "\"I don't have access\". If you are unsure what an app can do, find_route "
            + "lists what actually exists.")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Panel inventory

/// The scope's linked tools, shaped for display. Built from the same sources as the
/// prompt block above, so what the side panel lists is what the model was told about —
/// a panel that disagreed with the prompt would be worse than no panel.
struct ScopeInventory {
    struct Group: Identifiable {
        let id = UUID()
        let title: String
        let symbol: String
        let items: [String]
        var isMonospaced: Bool = false
    }

    var subtitle: String?
    var groups: [Group]

    @MainActor
    static func app(bundleId: String, appName: String) -> ScopeInventory {
        var groups: [Group] = []
        let adapter = AppAdapterManager.shared.adapters.first { $0.bundleId == bundleId }
        let actions = adapter?.actions ?? []

        if !actions.isEmpty {
            groups.append(
                Group(
                    title: "Actions", symbol: "bolt.fill",
                    items: actions.prefix(20).map { action in
                        action.requiresApproval || action.isDestructive
                            ? "\(action.name) — asks first"
                            : action.name
                    }))
        }

        let skills = SkillStore.shared.skills(for: bundleId).filter(\.isEnabled)
        if !skills.isEmpty {
            groups.append(
                Group(
                    title: "Skills", symbol: "brain.head.profile",
                    items: skills.map(\.name)))
        }

        // Built-in Apple MCP: registered capabilities scoped to this app (calendar.today,
        // reminders.list, …). Settings shows these under "Linked MCP · built-in", and the
        // panel was missing them because they are not MCPServerManager configs — they live
        // in the capability registry.
        let builtIns = CapabilityRegistry.shared.all
            .filter { $0.appBundleID == bundleId }
            .map(\.title)
        if !builtIns.isEmpty {
            groups.append(
                Group(
                    title: "Built-in tools", symbol: "sparkles",
                    items: Array(builtIns.prefix(12))))
        }

        let servers = MCPServerManager.shared.servers(forBundleId: bundleId)
        if !servers.isEmpty {
            // Names only, read from the config. Listing each server's tools would mean
            // connecting to it, and opening a panel must never spawn a process.
            groups.append(
                Group(title: "Linked MCP", symbol: "server.rack", items: servers.map(\.name)))
        }

        let apis = APIConnectionStore.shared.connections(for: bundleId)
        if !apis.isEmpty {
            groups.append(
                Group(
                    title: "API connections", symbol: "link",
                    items: apis.map { "\($0.name) — configured, not callable yet" }))
        }

        let shortcuts = actions.filter { $0.type == .shortcut }.compactMap(\.shortcutName)
        if !shortcuts.isEmpty {
            groups.append(Group(title: "Shortcuts", symbol: "command", items: shortcuts))
        }

        let clis = TerminalPackageManager.shared.packages.filter {
            $0.isEnabled && $0.contextAppBundleIds.contains(bundleId)
        }
        if !clis.isEmpty {
            groups.append(
                Group(
                    title: "CLI tools", symbol: "terminal",
                    items: clis.map { $0.isInstalled ? $0.command : "\($0.command) (not installed)" },
                    isMonospaced: true))
        }

        let menuItems = AppMenuCapabilityCache.shared.menuItems(
            bundleIdentifier: bundleId, appName: appName, query: "", maxResults: 60)
        let leaves = menuItems.filter { $0.isLeaf && !$0.path.isEmpty }
        if !leaves.isEmpty {
            // Grouped by the menu they live in, a few from each, rather than the first
            // twenty of one flat list. That list was ordered by when each item was last
            // seen, and a menu is only read once it has been opened — so History, whose
            // items are captured on the visit that opens it, sat behind twenty
            // freshly-scanned rows and looked to the user like an entire menu DoraX could
            // not see. Every menu is represented now, and none can be crowded out by a
            // sibling that happens to be larger or more recently read.
            var byMenu: [(menu: String, paths: [String])] = []
            var indexByMenu: [String: Int] = [:]
            var seen = Set<String>()
            for item in leaves {
                let path = item.path.joined(separator: " ▸ ")
                guard seen.insert(path.lowercased()).inserted else { continue }
                let menu = item.path.first ?? ""
                if let index = indexByMenu[menu] {
                    guard byMenu[index].paths.count < 6 else { continue }
                    byMenu[index].paths.append(path)
                } else {
                    indexByMenu[menu] = byMenu.count
                    byMenu.append((menu: menu, paths: [path]))
                }
            }
            let paths = Array(byMenu.flatMap(\.paths).prefix(40))
            groups.append(
                Group(title: "Menu commands", symbol: "filemenu.and.selection", items: paths))
        }

        return ScopeInventory(subtitle: bundleId, groups: groups)
    }

    /// What a folder thread can reach: the folder itself, and the file tools that act on
    /// it. Listed rather than assumed — "which of these can it actually do" is the
    /// question this panel exists to answer, and for files the honest answer is long.
    @MainActor
    static func folder(path: String) -> ScopeInventory {
        let url = URL(fileURLWithPath: path)
        var groups: [Group] = []

        let entries = FolderScopeDigest.topEntries(for: url)
        if !entries.isEmpty {
            groups.append(
                Group(title: "Recently changed", symbol: "clock", items: entries))
        }

        let fileTools = CapabilityRegistry.shared
            .capabilities(for: ChatAppDirectory.finderBundleID)
            .filter { $0.id.hasPrefix("finder.") }
            .map { capability in
                capability.riskLevel.requiresApproval
                    ? "\(capability.title) — asks first" : capability.title
            }
        if !fileTools.isEmpty {
            groups.append(Group(title: "File tools", symbol: "folder.badge.gearshape", items: fileTools))
        }

        groups.append(
            Group(title: "Path", symbol: "folder", items: [path], isMonospaced: true))

        return ScopeInventory(subtitle: FolderScopeDigest.subtitle(for: url), groups: groups)
    }

    @MainActor
    static func cli(command: String) -> ScopeInventory {
        guard let package = TerminalPackageManager.shared.packages.first(where: {
            $0.command.caseInsensitiveCompare(command) == .orderedSame
        }) else {
            return ScopeInventory(subtitle: "\(command) is not a pinned CLI tool.", groups: [])
        }

        var groups: [Group] = []
        if !package.subcommands.isEmpty {
            groups.append(
                Group(
                    title: "Scanned subcommands", symbol: "terminal",
                    items: package.subcommands, isMonospaced: true))
        }
        if let path = package.installedPath, !path.isEmpty {
            groups.append(
                Group(title: "Path", symbol: "folder", items: [path], isMonospaced: true))
        }
        return ScopeInventory(
            subtitle: package.description.isEmpty ? nil : package.description, groups: groups)
    }
}
