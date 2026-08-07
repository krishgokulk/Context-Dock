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
        case model

        /// What picking this actually does, in the user's terms. "No window opens" is the
        /// distinction people care about far more than which subsystem is involved.
        var routeLabel: String {
            switch self {
            case .cli: return "Command line · no window opens"
            case .adapterAction: return "App action"
            case .menuCommand: return "App menu · opens the app"
            case .mcpTool: return "App data · no window opens"
            case .model: return "Answer without running anything"
            }
        }

        var symbol: String {
            switch self {
            case .cli: return "terminal"
            case .adapterAction: return "bolt.fill"
            case .menuCommand: return "filemenu.and.selection"
            case .mcpTool: return "server.rack"
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

    static func routes(
        for query: String, bundleId: String, appName: String
    ) -> [ChatRoute] {
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
        for item in menuItems where item.isLeaf && !item.path.isEmpty {
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

        // Deduplicate by title so the same capability offered by two subsystems is one
        // choice, and cap the list: five ways to do one thing is not a decision, it is a
        // quiz.
        var seen = Set<String>()
        return routes.filter { seen.insert($0.title.lowercased()).inserted }.prefix(4).map { $0 }
    }

    /// True when the user should be asked which route to take.
    ///
    /// Only when the routes differ in consequence — several exist, at least one changes
    /// something or takes the screen, and the user has not already answered this question
    /// for this app.
    static func shouldAsk(routes: [ChatRoute], bundleId: String, query: String) -> Bool {
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

        case .mcpTool, .model:
            return (false, "")
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

    static func forget(bundleId: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        all = all.filter { !$0.key.hasPrefix("\(bundleId)|") }
        UserDefaults.standard.set(all, forKey: key)
    }
}
