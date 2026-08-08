// ChatRouteResolver.swift
// Context-Dock
//
// The ways DoraX can actually carry out a request for an app, found before the model is
// asked anything.
//
// An app can be reached through its CLI, its adapter actions, its menu bar and its MCP
// tools, and the model was left to guess which. It guessed badly and invisibly: a
// Pearcleaner question became a `rem` command, a Reminders question became advice about
// opening the app. Resolving the routes first makes the choice inspectable — one route
// runs, several are offered to the user, and the answer says which one produced it.

import AppKit
import Foundation

struct ChatRoute: Identifiable, Equatable {
    enum Kind: String {
        case cli
        case adapterAction
        case menuCommand
        case mcpTool
        /// An adapter skill: the user's own written workflow for this app. Not a command —
        /// it steers the model rather than running anything — but it is a real, chooseable
        /// way to carry out a request, and it belongs in the same list as the rest.
        case skill
        case model

        /// What picking this actually does, in the user's terms. "No window opens" is the
        /// distinction people care about far more than which subsystem is involved.
        var routeLabel: String {
            switch self {
            case .cli: return "Command line · no window opens"
            case .adapterAction: return "App action"
            case .menuCommand: return "App menu · opens the app"
            case .mcpTool: return "App data · no window opens"
            case .skill: return "Your saved workflow for this app"
            case .model: return "Answer without running anything"
            }
        }

        /// Fixed preference order: the app's own API, then structured tools, then
        /// inspectable commands, then the screen, then the model. Deterministic before
        /// probabilistic, without asking the model which it prefers.
        var rank: Int {
            switch self {
            case .adapterAction: return 1
            case .mcpTool: return 2
            case .cli: return 3
            case .menuCommand: return 4
            case .skill: return 5
            case .model: return 6
            }
        }

        /// True when running it takes the screen. The user is choosing between "answer me"
        /// and "drive my Mac"; that is the cost that matters to them.
        var takesTheScreen: Bool { self == .menuCommand }

        var symbol: String {
            switch self {
            case .cli: return "terminal"
            case .adapterAction: return "bolt.fill"
            case .menuCommand: return "filemenu.and.selection"
            case .mcpTool: return "server.rack"
            case .skill: return "brain.head.profile"
            case .model: return "text.bubble"
            }
        }
    }

    let id: String
    let kind: Kind
    let title: String
    /// Command, action id, or menu path — what will be run, verbatim.
    let payload: String
    let appName: String
    let bundleId: String
    /// True when running it cannot change anything. Read-only routes are taken without
    /// asking; the point of asking is to give the user the call on consequence, and there
    /// is no consequence to weigh here.
    let isReadOnly: Bool

    static func == (lhs: ChatRoute, rhs: ChatRoute) -> Bool { lhs.id == rhs.id }

    var asActionChoice: ActionChoice {
        ActionChoice(id: id, title: title, routeLabel: kind.routeLabel, appName: appName)
    }
}

@MainActor
enum ChatRouteResolver {

    /// Verbs that mean "do something", as opposed to "tell me something". Only these make
    /// a route worth confirming — a read is run and reported.
    private static let mutatingVerbs = [
        "delete", "remove", "uninstall", "clean", "clear", "quit", "close", "kill",
        "create", "add", "install", "update", "move", "rename", "empty", "reset", "run",
    ]

    /// Routes for a CLI scope: the tool's own subcommands that match the request. A CLI
    /// thread has exactly one executable, so the choice is which invocation to run — the
    /// same decision, one level down.
    static func cliRoutes(for query: String, command: String) -> [ChatRoute] {
        guard let package = TerminalPackageManager.shared.packages.first(where: {
            $0.command.caseInsensitiveCompare(command) == .orderedSame
        }) else { return [] }
        let terms = Set(
            query.lowercased().split { !$0.isLetter && !$0.isNumber }
                .map(String.init).filter { $0.count > 2 })
        guard !terms.isEmpty else { return [] }

        let matching = package.subcommands.filter { subcommand in
            let words = Set(
                subcommand.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
            return !words.isDisjoint(with: terms)
                || terms.contains { subcommand.lowercased().hasPrefix($0) }
        }
        return matching.prefix(4).map { subcommand in
            let invocation = "\(package.command) \(subcommand)"
            return ChatRoute(
                id: "cli:\(invocation)",
                kind: .cli,
                title: invocation,
                payload: invocation,
                appName: package.command,
                bundleId: "cli://\(package.command)",
                isReadOnly: !mutatingVerbs.contains { invocation.lowercased().contains($0) })
        }
    }

    /// True when the user asked for something to be *done*. "what page am I on" is a
    /// question about state; offering to run a menu command for it is noise, and the
    /// answer should come from context the app already exposes.
    static func isActionRequest(_ query: String) -> Bool {
        let lowered = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let questionStarts = [
            "what", "which", "who", "when", "where", "why", "how", "is ", "are ", "do ",
            "does ", "did ", "can ", "am i", "tell me", "show me my", "my ",
        ]
        if questionStarts.contains(where: lowered.hasPrefix) { return false }
        if lowered.hasSuffix("?") { return false }
        let actionVerbs = mutatingVerbs + [
            "open", "launch", "start", "stop", "show", "list", "export", "copy", "paste",
            "refresh", "reload", "search", "find", "jump", "switch", "toggle",
        ]
        return actionVerbs.contains { lowered.hasPrefix($0) || lowered.contains(" \($0) ") }
    }

    static func routes(
        for query: String, bundleId: String, appName: String
    ) async -> [ChatRoute] {
        guard !bundleId.isEmpty else { return [] }
        let lowered = query.lowercased()
        let terms = Set(
            lowered.split { !$0.isLetter && !$0.isNumber }
                .map(String.init).filter { $0.count > 2 })
        guard !terms.isEmpty else { return [] }

        func matches(_ haystack: String) -> Bool {
            let words = Set(
                haystack.lowercased().split { !$0.isLetter && !$0.isNumber }
                    .map(String.init))
            return !words.isDisjoint(with: terms)
        }

        var routes: [ChatRoute] = []

        // CLI first: it answers without taking the screen, which is what the user usually
        // wants from a question they typed into a chat window.
        for package in TerminalPackageManager.shared.packages
        where package.isEnabled && package.contextAppBundleIds.contains(bundleId) {
            let subcommand = package.subcommands.first { matches($0) }
            // Offering the bare binary for any question is how "what page am I on" was
            // answered with a choice between `markitdown` and `play`. A linked tool is a
            // route only when something in it actually matches the request.
            guard subcommand != nil || terms.contains(package.command.lowercased()) else {
                continue
            }
            let command = subcommand.map { "\(package.command) \($0)" } ?? package.command
            routes.append(
                ChatRoute(
                    id: "cli:\(command)",
                    kind: .cli,
                    title: command,
                    payload: command,
                    appName: appName,
                    bundleId: bundleId,
                    isReadOnly: !mutatingVerbs.contains { command.lowercased().contains($0) }))
        }

        if let adapter = AppAdapterManager.shared.adapters.first(where: {
            $0.bundleId == bundleId
        }) {
            for action in adapter.actions
            where action.type != .aiPrompt && matches(action.name) {
                routes.append(
                    ChatRoute(
                        id: "action:\(action.id)",
                        kind: .adapterAction,
                        title: action.name,
                        payload: action.id,
                        appName: appName,
                        bundleId: bundleId,
                        isReadOnly: !action.isDestructive && !action.requiresApproval))
            }
        }

        let menuItems = AppMenuCapabilityCache.shared.menuItems(
            bundleIdentifier: bundleId, appName: appName, query: query, maxResults: 6)
        for item in menuItems
        where item.isLeaf && !item.path.isEmpty
            // Match the command, not its menu. Matching any path component is what put
            // "Edit ▸ Copy" and "Edit ▸ Delete" in front of a question about an IP address,
            // because both live under a menu whose name shares nothing with the request.
            && item.path.last.map(matches) == true {
            let path = item.path.joined(separator: " ▸ ")
            routes.append(
                ChatRoute(
                    id: "menu:\(path)",
                    kind: .menuCommand,
                    title: path,
                    payload: item.path.joined(separator: "\u{1}"),
                    appName: appName,
                    bundleId: bundleId,
                    isReadOnly: false))
        }

        // MCP tools that are already connected. Cached only: resolving a list of choices
        // must never spawn a process, and a server that has not been used yet is not a
        // route the user can be offered honestly.
        let mcpTools = await AppScopedChatService.withTimeout(
            seconds: 2, fallback: [(server: String, serverId: UUID, tool: MCPTool)]()
        ) {
            await MCPRuntime.shared.cachedTools(forBundleId: bundleId)
        }
        for entry in mcpTools where matches(entry.tool.name + " " + entry.tool.description) {
            let required = (entry.tool.inputSchema["required"] as? [String]) ?? []
            // A tool that needs arguments cannot be offered as a one-tap route; the model
            // has to fill it in through the normal tool loop.
            guard required.isEmpty else { continue }
            routes.append(
                ChatRoute(
                    id: "mcp:\(entry.server):\(entry.tool.name)",
                    kind: .mcpTool,
                    title: entry.tool.name.replacingOccurrences(of: "_", with: " "),
                    payload: "\(entry.server)\u{1}\(entry.tool.name)",
                    appName: appName,
                    bundleId: bundleId,
                    isReadOnly: MCPToolSafety.isClearlyReadOnly(name: entry.tool.name)))
        }

        // The user's own workflows for this app. A skill runs nothing on its own, so it is
        // read-only by definition; it changes how the request is answered, not the machine.
        for skill in SkillStore.shared.skills(for: bundleId)
        where skill.isEnabled && matches("\(skill.name) \(skill.summary)") {
            routes.append(
                ChatRoute(
                    id: "skill:\(skill.id)",
                    kind: .skill,
                    title: skill.name,
                    payload: skill.id,
                    appName: appName,
                    bundleId: bundleId,
                    isReadOnly: true))
        }

        // Deduplicate by title so the same capability offered by two subsystems is one
        // choice, and cap the list: five ways to do one thing is not a decision, it is a
        // quiz. Ranked first, so the cap keeps the best routes rather than the first-found
        // ones, and so the leading choice is the one the layer would take unattended.
        var seen = Set<String>()
        return
            routes
            .sorted {
                if $0.kind.rank != $1.kind.rank { return $0.kind.rank < $1.kind.rank }
                // Same kind: a read is a safer default than something that changes state.
                if $0.isReadOnly != $1.isReadOnly { return $0.isReadOnly }
                return $0.title.count < $1.title.count
            }
            .filter { seen.insert($0.title.lowercased()).inserted }
            .prefix(4)
            .map { $0 }
    }

    /// The route the layer takes when no decision is needed: highest-ranked, read-only.
    /// Deterministic before probabilistic means acting on it without consulting the model
    /// about which subsystem it would rather use.
    static func unattendedRoute(_ routes: [ChatRoute]) -> ChatRoute? {
        routes.first { $0.isReadOnly && !$0.kind.takesTheScreen }
    }

    /// True when the user should be asked which route to take.
    ///
    /// Only when the routes differ in consequence — several exist, at least one changes
    /// something or takes the screen, and the user has not already answered this question
    /// for this app.
    static func shouldAsk(routes: [ChatRoute], bundleId: String, query: String) -> Bool {
        guard isActionRequest(query) else { return false }
        guard routes.count > 1 else { return false }
        guard ChatRoutePreferenceStore.preferredKind(bundleId: bundleId, query: query) == nil
        else { return false }
        return routes.contains { !$0.isReadOnly }
    }

    /// Runs a route and returns what it produced, verbatim, for the Console and for the
    /// model to phrase.
    static func run(_ route: ChatRoute, query: String) async -> (success: Bool, output: String) {
        switch route.kind {
        case .cli:
            // A tool that draws its own screen cannot be run with its output captured:
            // with no tty it hangs or emits escape codes, which is how a working
            // terminal-browser became a two-and-a-half minute timeout. Type it into the
            // thread's own terminal instead, where it has somewhere to draw.
            let command = route.payload.split(separator: " ").first.map(String.init) ?? ""
            if ChatThreadTerminalManager.needsTerminal(command: command) {
                let scope = GeneralChatScope.cli(command: command)
                ChatThreadTerminalManager.shared.run(route.payload, scope: scope)
                return (
                    true,
                    "Running in this thread's terminal — it draws its own screen, so watch "
                        + "the Terminal panel rather than waiting for output here."
                )
            }
            return await TerminalCommandExecutor.shared.run(
                route.payload, purpose: query, modelRequiresApproval: !route.isReadOnly)

        case .adapterAction:
            guard let adapter = AppAdapterManager.shared.adapters.first(where: {
                    $0.bundleId == route.bundleId
                }),
                let action = adapter.actions.first(where: { $0.id == route.payload })
            else { return (false, "That action is no longer available in \(route.appName).") }
            return await AppAdapterManager.shared.execute(
                action, context: AXContextReader.shared.current,
                targetBundleId: route.bundleId, query: query)

        case .menuCommand:
            let path = route.payload.split(separator: "\u{1}").map(String.init)
            let result = await AppAdapterManager.shared.runMenuPath(
                path, targetBundleId: route.bundleId, appName: route.appName)
            return (result.0, result.1)

        case .mcpTool:
            let parts = route.payload.split(separator: "\u{1}").map(String.init)
            guard parts.count == 2 else { return (false, "") }
            do {
                let output = try await MCPRuntime.shared.callTool(
                    bundleId: route.bundleId, server: parts[0], tool: parts[1], arguments: [:])
                return (true, output)
            } catch {
                return (false, "\(parts[1]) failed: \(error.localizedDescription)")
            }

        case .skill, .model:
            // Neither runs anything: the caller answers with the skill's instructions in
            // the prompt. Returning "nothing happened" here is the honest result.
            return (true, "")
        }
    }
}

/// Which route the user picked last time, per app and kind of request.
///
/// Asked once, then remembered: a picker that asks the same question every day is a worse
/// bargain than the guessing it replaced.
enum ChatRoutePreferenceStore {
    private static let key = "dorax.chat.routePreference.v1"

    /// The request's shape, not its wording — "show all cache files" and "list cache
    /// files" are the same decision.
    static func intentKey(_ query: String) -> String {
        query.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 3 }
            .sorted()
            .prefix(3)
            .joined(separator: "-")
    }

    private static func storageKey(bundleId: String, query: String) -> String {
        "\(bundleId)|\(intentKey(query))"
    }

    static func preferredKind(bundleId: String, query: String) -> ChatRoute.Kind? {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        guard let raw = all[storageKey(bundleId: bundleId, query: query)] else { return nil }
        return ChatRoute.Kind(rawValue: raw)
    }

    static func remember(_ kind: ChatRoute.Kind, bundleId: String, query: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        all[storageKey(bundleId: bundleId, query: query)] = kind.rawValue
        UserDefaults.standard.set(all, forKey: key)
    }

    /// Everything remembered for an app, as (request shape, route kind). Shown in the
    /// side panel: a preference the user cannot see is one they cannot undo.
    static func remembered(bundleId: String) -> [(intent: String, kind: ChatRoute.Kind)] {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        return all.compactMap { entry in
            guard entry.key.hasPrefix("\(bundleId)|"),
                let kind = ChatRoute.Kind(rawValue: entry.value)
            else { return nil }
            let intent = String(entry.key.dropFirst(bundleId.count + 1))
                .replacingOccurrences(of: "-", with: " ")
            return (intent, kind)
        }
        .sorted { $0.intent < $1.intent }
    }

    static func forget(bundleId: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        all = all.filter { !$0.key.hasPrefix("\(bundleId)|") }
        UserDefaults.standard.set(all, forKey: key)
    }
}
