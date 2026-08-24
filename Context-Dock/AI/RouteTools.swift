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
    }

    /// Routes offered to the model this turn, by id, so run_route executes exactly what
    /// find_route described rather than re-resolving against drifted state.
    @MainActor
    private static var offeredRoutes: [String: ChatRoute] = [:]

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
                ]
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
            guard let bundleID = await MainActor.run(body: {
                AgentToolRegistry.scopedBundleID(for: context.chatScope)
            }) else {
                return AgentToolResult(
                    success: false,
                    output: "This conversation is not scoped to an app, so it has no app "
                        + "routes. Use find_capability for the system-wide ones.",
                    displayCommand: "find_route")
            }
            let appName = await MainActor.run {
                InstalledApplicationsCatalog.cachedInstalledApps()
                    .first { $0.bundleId.caseInsensitiveCompare(bundleID) == .orderedSame }?
                    .name ?? bundleID
            }
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
}
