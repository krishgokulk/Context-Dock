// RouteTools.swift
// Context-Dock
//
// The deterministic layer, offered to the model instead of used on it.
//
// ChatRouteResolver knows every real way an app can carry out a request: its adapter actions,
// its verified menu commands, its linked CLI, its MCP tools, the user's own skills — ranked,
// permission-checked, and provably real rather than guessed. Until now that knowledge was
// used *instead of* the model: the resolver picked a route, ran it, and handed the model the
// output to phrase. Fast and safe, and the reason DoraX often reads as a router rather than
// an assistant — there are no steps to show when the thinking happened before the model was
// asked anything.
//
// These expose the same resolver as two tools. The model asks what routes exist, picks one,
// and narrates around it. Every guard survives untouched, because the guards live on the
// routes and not on who chose them: AppAccessPolicy still filters by grant, destructive menu
// commands still raise their own approval, the CLI boundary still holds.
//
// Nothing is taken away. The unattended path still answers the questions it always did; this
// is the door for the model when it wants to look for itself.

import Foundation

extension AgentToolRegistry {

    func registerRouteTools() {
        register(makeFindRouteTool())
        register(makeRunRouteTool())
        register(makeFindMenuCommandTool())
    }

    /// The app a route or menu lookup should act on: the thread's own scope, an app the
    /// user named that this chat was granted, or the single granted app when there is one.
    /// Returns nil when the name was never granted or more than one app is in scope with no
    /// name given — the caller turns that into "name one of these apps".
    @MainActor
    static func resolveScopedApp(
        named: String, grantedApps: [String: String], chatScope: GeneralChatScope?
    ) -> (id: String, name: String)? {
        func displayName(for bundleID: String, fallback: String) -> String {
            InstalledApplicationsCatalog.cachedInstalledApps()
                .first { $0.bundleId.caseInsensitiveCompare(bundleID) == .orderedSame }?
                .name ?? fallback
        }
        let trimmed = named.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            // Named an app: it must be one this chat was granted; otherwise we do not reach
            // into an app the user has not agreed to.
            guard let id = grantedApps[trimmed.lowercased()] else { return nil }
            return (id, trimmed)
        }
        if let scoped = scopedBundleID(for: chatScope) {
            return (scoped, displayName(for: scoped, fallback: scoped))
        }
        // One granted app and no name given is unambiguous.
        if grantedApps.count <= 2, let only = grantedApps.first {
            return (only.value, displayName(for: only.value, fallback: only.key))
        }
        return nil
    }

    /// Routes offered to the model this turn, by id, so run_route executes exactly what
    /// find_route described rather than re-resolving against drifted state.
    @MainActor
    private static var offeredRoutes: [String: ChatRoute] = [:]

    /// What `run_route` would run for this id, for the outbound gate to classify before it does.
    static func offeredRoute(id: String) -> ChatRoute? { offeredRoutes[id] }

    private func makeFindRouteTool() -> AgentTool {
        AgentTool(
            name: "find_route",
            description: "Ask what real ways this app has to carry out a request — its saved "
                + "actions, its verified menu commands, its linked command-line tools and its "
                + "data tools. Returns only routes that actually exist and are permitted, "
                + "each with an id to pass to run_route. Use it before saying an app cannot "
                + "do something.",
            properties: [
                "request": [
                    "type": "string",
                    "description": "What the user wants done, in their words.",
                ],
                "app": [
                    "type": "string",
                    "description": "Which app to ask about. Needed in a general conversation "
                        + "that has more than one app enabled; omit in an app's own thread.",
                ],
            ],
            required: ["request"]
        ) { arguments, context in
            let request = (arguments["request"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !request.isEmpty else {
                return AgentToolResult(
                    success: false, output: "find_route needs 'request'.",
                    displayCommand: "find_route")
            }
            // The thread's own app, or one the user named that this chat has been granted.
            //
            // Refusing outright unless the thread was app-scoped was wrong in exactly the
            // case that matters: in General Chat the user is asked "enable Pearcleaner for
            // this chat?", says yes, asks their question again — and the tool that lists what
            // Pearcleaner can do still answered "this conversation is not scoped to an app".
            // The grant is the scope, for that app, for this conversation.
            let named = (arguments["app"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = await MainActor.run {
                AgentToolRegistry.resolveScopedApp(
                    named: named, grantedApps: context.grantedApps, chatScope: context.chatScope)
            }
            guard let resolved else {
                let available = await MainActor.run {
                    Set(context.grantedApps.values).sorted().joined(separator: ", ")
                }
                return AgentToolResult(
                    success: false,
                    output: available.isEmpty
                        ? "This conversation has no app in scope. Use find_capability for the "
                            + "system-wide routes, or ask the user to enable the app."
                        : "Pass 'app' as one of the apps this chat can reach: \(available).",
                    displayCommand: "find_route")
            }
            let bundleID = resolved.id
            let appName = resolved.name
            let routes = await ChatRouteResolver.routes(
                for: request, bundleId: bundleID, appName: appName)
            guard !routes.isEmpty else {
                return AgentToolResult(
                    success: true,
                    output: "\(appName) has no route for that — no saved action, no menu "
                        + "command, no linked tool matches it. Say so plainly, and if it "
                        + "would need one, name what the user could link in Settings → App "
                        + "Adapters. Do not invent a menu path.",
                    displayCommand: "find_route(\(request))")
            }
            await MainActor.run {
                AgentToolRegistry.offeredRoutes = Dictionary(
                    uniqueKeysWithValues: routes.map { ($0.id, $0) })
            }
            let lines = routes.map { route in
                "- \(route.id): \(route.title) | \(route.kind.routeLabel)"
                    + (route.isReadOnly ? " | read-only" : " | changes something")
            }
            return AgentToolResult(
                success: true,
                output: "Ways \(appName) can do this — run one with run_route:\n"
                    + lines.joined(separator: "\n")
                    + "\n\nPrefer a read-only route when the user asked a question, and the "
                    + "app's own action over driving its menu. A route that changes something "
                    + "asks the user first; you do not need to ask as well.",
                displayCommand: "find_route(\(request))")
        }
    }

    private func makeRunRouteTool() -> AgentTool {
        AgentTool(
            name: "run_route",
            description: "Run a route returned by find_route, by id, and get back what it "
                + "produced. Destructive routes raise their own approval card first.",
            properties: [
                "route_id": [
                    "type": "string",
                    "description": "The id exactly as find_route reported it.",
                ],
                "purpose": [
                    "type": "string",
                    "description": "One line on why, shown with the approval when there is one.",
                ],
            ],
            required: ["route_id"]
        ) { arguments, _ in
            let routeID = (arguments["route_id"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let route = await MainActor.run(body: {
                AgentToolRegistry.offeredRoutes[routeID]
            }) else {
                return AgentToolResult(
                    success: false,
                    output: "No route with id \"\(routeID)\" was offered. Call find_route "
                        + "first and use an id it returns — an invented id runs nothing.",
                    displayCommand: "run_route(\(routeID))")
            }
            let purpose = (arguments["purpose"] as? String ?? route.title)
            let result = await ChatRouteResolver.run(route, query: purpose)
            return AgentToolResult(
                success: result.success,
                output: result.output.isEmpty
                    ? (result.success
                        ? "Done — \(route.title). It produced no output, which is normal for "
                            + "a command of this kind."
                        : "\(route.title) did not run.")
                    : result.output,
                displayCommand: "run_route(\(route.title))")
        }
    }

    /// Menus on demand (P2). The scoped prompt no longer dumps fifty menu paths; it names
    /// this tool instead. Given a UI request it returns the few matching menu-bar paths from
    /// `AppMenuCapabilityCache`, each ready to pass to run_menu_command. Read-only.
    private func makeFindMenuCommandTool() -> AgentTool {
        AgentTool(
            name: "find_menu_command",
            description: "Find the menu-bar commands in this app that match an interface "
                + "request (minimize, new tab, export, close…). Menus are not listed in the "
                + "prompt — ask here when the request is about the app's window or interface, "
                + "or when no headless route fits, then run a returned path with "
                + "run_menu_command. Read-only; nothing runs.",
            properties: [
                "query": [
                    "type": "string",
                    "description": "The interface command, in a word or two (e.g. \"minimize\").",
                ],
                "app": [
                    "type": "string",
                    "description": "Which app to look in. Needed only in a general conversation "
                        + "with more than one app enabled; omit in an app's own thread.",
                ],
            ],
            required: ["query"]
        ) { arguments, context in
            let query = (arguments["query"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                return AgentToolResult(
                    success: false, output: "find_menu_command needs 'query'.",
                    displayCommand: "find_menu_command")
            }
            let named = (arguments["app"] as? String ?? "")
            let resolved = await MainActor.run {
                AgentToolRegistry.resolveScopedApp(
                    named: named, grantedApps: context.grantedApps, chatScope: context.chatScope)
            }
            guard let resolved else {
                let available = await MainActor.run {
                    Set(context.grantedApps.values).sorted().joined(separator: ", ")
                }
                return AgentToolResult(
                    success: false,
                    output: available.isEmpty
                        ? "This conversation has no app in scope. Name the app, or ask the "
                            + "user to enable it."
                        : "Pass 'app' as one of the apps this chat can reach: \(available).",
                    displayCommand: "find_menu_command")
            }
            let items = AppMenuCapabilityCache.shared.menuItems(
                bundleIdentifier: resolved.id, appName: resolved.name,
                query: query, maxResults: 12)
            let leaves = items.filter { $0.isLeaf && !$0.path.isEmpty }
            guard !leaves.isEmpty else {
                return AgentToolResult(
                    success: true,
                    output: "\(resolved.name) has no cached menu command matching "
                        + "\"\(query)\". If it is a command the app builds only when a menu is "
                        + "opened, operate_app reads the live menu bar.",
                    displayCommand: "find_menu_command(\(query))")
            }
            var seen = Set<String>()
            var paths: [String] = []
            for item in leaves {
                let path = item.path.joined(separator: " ▸ ")
                guard seen.insert(path.lowercased()).inserted else { continue }
                let shortcut = item.shortcutDisplay.map { " (\($0))" } ?? ""
                paths.append("- \(path)\(shortcut)")
                if paths.count >= 8 { break }
            }
            return AgentToolResult(
                success: true,
                output: "Menu commands in \(resolved.name) matching \"\(query)\" — run one "
                    + "with run_menu_command, passing the full path:\n"
                    + paths.joined(separator: "\n"),
                displayCommand: "find_menu_command(\(query))")
        }
    }
}
