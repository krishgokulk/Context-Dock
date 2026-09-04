import Foundation

enum IntegrationInventoryBuilder {
    static func build(from snapshot: IntegrationInventorySnapshot) -> IntegrationInventory {
        let adaptersByBundleID = adaptersByBundleID(snapshot.adapters)
        let appBundleIDs = appBundleIDs(
            adapters: adaptersByBundleID,
            packages: snapshot.packages)

        // Ordered by the name the user reads, not by bundle ID: an alphabetical list of
        // reverse-DNS strings looks shuffled to anyone scanning for an app.
        let apps = appBundleIDs
            .map { bundleID in
                appSummary(
                    bundleID: bundleID,
                    adapter: adaptersByBundleID[bundleID],
                    snapshot: snapshot)
            }
            .sorted { left, right in
                left.appName.caseInsensitiveCompare(right.appName) == .orderedSame
                    ? compare(left.bundleID, right.bundleID)
                    : compare(left.appName, right.appName)
            }

        return IntegrationInventory(
            apps: apps,
            global: GlobalIntegrationSummary(
                commands: sorted(snapshot.commands, by: \.name),
                selectionExtensions: sorted(
                    snapshot.extensions.filter(isSelectionExtension),
                    by: \.name),
                selectionRules: sorted(snapshot.selectionRules, by: \.name),
                cliTools: snapshot.packages
                    .filter { $0.isEnabled && snapshot.globalPackageIDs.contains($0.id) }
                    .sorted { compare($0.command, $1.command) },
                mcpServers: sorted(
                    snapshot.mcpServers.filter { $0.bundleIds.isEmpty },
                    by: \.name)))
    }

    /// Resolves what removal will and will not touch, before the confirmation is shown.
    static func removalPreview(for app: AppIntegrationSummary) -> IntegrationRemovalPreview {
        let sharedTools = app.cliTools
            .filter { package in
                package.contextAppBundleIds.contains { $0 != app.bundleID }
            }
            .map(\.command)

        return IntegrationRemovalPreview(
            removedActionCount: app.appActions.count
                + app.browserActions.count
                + app.shortcuts.count,
            unlinkedCLIToolCount: app.cliTools.count,
            retainedSkillCount: app.skills.count,
            retainedMCPCount: app.mcpServers.count,
            retainedAPIConnectionCount: app.apiConnections.count,
            retainedSharedResourceNames: sharedTools.sorted(by: compare))
    }

    static func filter(_ apps: [AppIntegrationSummary], query: String) -> [AppIntegrationSummary] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return apps }

        return apps.filter { app in
            searchableText(for: app).contains { candidate in
                candidate.range(of: query, options: .caseInsensitive) != nil
            }
        }
    }

    private static func appSummary(
        bundleID: String,
        adapter: AppAdapter?,
        snapshot: IntegrationInventorySnapshot
    ) -> AppIntegrationSummary {
        // Matches the grouping the App Adapters page already uses: linked Shortcuts are a
        // resource the user manages under Resources, never a row in the actions list.
        let visibleActions = adapter?.visibleActions ?? []
        let appActions = visibleActions.filter { $0.type != .pageJS && $0.type != .shortcut }
        let browserActions = visibleActions.filter { $0.type == .pageJS }
        let shortcuts = visibleActions.filter { $0.type == .shortcut }
        let skills = snapshot.skills.filter { $0.adapterBundleId == bundleID }
        // Linked to this app is the whole test. Global scope is a separate grant, not a
        // claim on the tool, so a tool that is also pinned globally still belongs here.
        let cliTools = snapshot.packages.filter {
            $0.isEnabled && $0.contextAppBundleIds.contains(bundleID)
        }
        let mcpServers = snapshot.mcpServers.filter { $0.bundleIds.contains(bundleID) }
        let apiConnections = snapshot.apiConnections.filter { $0.adapterBundleId == bundleID }
        let contextReaders = adapter?.contextReaders ?? []
        let counts = IntegrationResourceCounts(
            actions: appActions.count + browserActions.count,
            skills: skills.count,
            cliTools: cliTools.count,
            mcpServers: mcpServers.count,
            apiConnections: apiConnections.count,
            shortcuts: shortcuts.count,
            contextReaders: contextReaders.count)

        return AppIntegrationSummary(
            bundleID: bundleID,
            appName: adapter?.appName ?? bundleID,
            icon: adapter?.icon ?? "app.badge",
            adapter: adapter,
            appActions: sorted(appActions, by: \.name),
            browserActions: sorted(browserActions, by: \.name),
            skills: sorted(skills, by: \.name),
            cliTools: cliTools.sorted { compare($0.command, $1.command) },
            mcpServers: sorted(mcpServers, by: \.name),
            apiConnections: sorted(apiConnections, by: \.name),
            shortcuts: sorted(shortcuts, by: \.name),
            contextReaders: sorted(contextReaders, by: \.name),
            counts: counts,
            health: health(
                adapter: adapter,
                cliTools: cliTools,
                apiConnections: apiConnections))
    }

    private static func adaptersByBundleID(_ adapters: [AppAdapter]) -> [String: AppAdapter] {
        adapters.reduce(into: [:]) { result, adapter in
            let bundleID = adapter.bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleID.isEmpty, !bundleID.hasPrefix("cli://") else { return }
            if result[bundleID] == nil {
                result[bundleID] = adapter
            }
        }
    }

    private static func appBundleIDs(
        adapters: [String: AppAdapter],
        packages: [TerminalPackage]
    ) -> [String] {
        let linkedPackageBundleIDs = packages
            .filter(\.isEnabled)
            .flatMap { package in
                package.contextAppBundleIds.filter { isAppBundleID($0, for: package) }
            }
        return Set(adapters.keys).union(linkedPackageBundleIDs).sorted(by: compare)
    }

    private static func isAppBundleID(_ bundleID: String, for package: TerminalPackage) -> Bool {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = package.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("cli://") else { return false }
        let globalScopeIDs = Set(["cli_\(command)", command])
        return !globalScopeIDs.contains(trimmed)
    }

    private static func isSelectionExtension(_ item: ILExtension) -> Bool {
        item.layer == .l2_context && item.category == "shortcutSheet"
    }

    private static func health(
        adapter: AppAdapter?,
        cliTools: [TerminalPackage],
        apiConnections: [APIConnection]
    ) -> IntegrationHealth {
        var warnings: [String] = []
        if adapter?.isEnabled == false {
            warnings.append("Integration is disabled")
        }
        if cliTools.contains(where: { !$0.isInstalled }) {
            warnings.append("CLI tool is not installed")
        }
        if apiConnections.contains(where: { $0.status == .disconnected }) {
            warnings.append("API connection is disconnected")
        }
        return warnings.isEmpty ? .healthy : .needsAttention(warnings)
    }

    private static func searchableText(for app: AppIntegrationSummary) -> [String] {
        var text = [
            app.appName,
            app.bundleID,
            "App action",
            "Browser action",
            "Skill",
            "CLI tool",
            "MCP server",
            "API connection",
            "Shortcut",
            "Context reader"
        ]
        for action in app.actions {
            text += [action.name, action.description, action.type.rawValue, action.type.displayName]
        }
        for skill in app.skills {
            text += [skill.name, skill.summary]
        }
        for tool in app.cliTools {
            text += [tool.name, tool.command, tool.description]
        }
        for server in app.mcpServers {
            text += [server.name, server.command, server.transport]
        }
        for connection in app.apiConnections {
            text += [connection.name, connection.baseURL, connection.permissions, connection.status.rawValue]
        }
        for reader in app.contextReaders {
            text += [reader.name, reader.type]
        }
        return text
    }

    private static func sorted<T>(_ values: [T], by name: KeyPath<T, String>) -> [T] {
        values.sorted { compare($0[keyPath: name], $1[keyPath: name]) }
    }

    private static func compare(_ lhs: String, _ rhs: String) -> Bool {
        let loweredLeft = lhs.lowercased()
        let loweredRight = rhs.lowercased()
        return loweredLeft == loweredRight ? lhs < rhs : loweredLeft < loweredRight
    }
}
