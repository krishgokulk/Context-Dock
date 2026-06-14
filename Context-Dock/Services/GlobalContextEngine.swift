import AppKit
import ApplicationServices
import Foundation

struct GlobalMenuAppSnapshot {
    let bundleID: String
    let name: String
    let icon: NSImage?
    let processIdentifier: pid_t
    let isRunning: Bool
}

struct GlobalMenuDescriptor {
    let id: String
    let name: String
    let badge: String?
    let statusBadge: String?
    let bundleID: String
    let appName: String
    let appIcon: NSImage?
    let path: [String]
    let shortcutChar: String?
    let shortcutModifiers: Int
    let rankingScore: Double
}

struct GlobalMenuDescriptorGroup {
    let bundleID: String
    let appName: String
    let icon: NSImage?
    let descriptors: [GlobalMenuDescriptor]
}

struct GlobalMenuExecutionRequest {
    let bundleIdentifier: String
    let appName: String
    let appPath: String?
    let path: [String]
    let shortcutChar: String?
    let shortcutModifiers: Int
}

enum GlobalMenuExecutionStatus: Equatable {
    case executed
    case unavailable
    case launchFailed
    case executionFallback
}

struct GlobalMenuExecutionResult {
    let status: GlobalMenuExecutionStatus
    let app: NSRunningApplication?
    let liveItem: AXMenuItem?
    let message: String
}

/// Global Context engine boundary.
/// Rule: typing/searching reads persisted cache only. Live AX verification belongs to execution.
final class GlobalContextEngine {
    nonisolated static let shared = GlobalContextEngine()

    nonisolated private init() {}

    nonisolated func cachedMenuItems(
        for app: NSRunningApplication,
        query: String = "",
        maxResults: Int = 24
    ) -> [AXMenuItem] {
        AppMenuCapabilityCache.shared.menuItems(
            for: app,
            query: query,
            maxResults: maxResults
        )
    }

    nonisolated func cachedMenuItems(
        bundleIdentifier: String,
        appName: String,
        processIdentifier: pid_t = 0,
        query: String = "",
        maxResults: Int = 24
    ) -> [AXMenuItem] {
        AppMenuCapabilityCache.shared.menuItems(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            processIdentifier: processIdentifier,
            query: query,
            maxResults: maxResults
        )
    }

    nonisolated func hasMenuSnapshot(bundleIdentifier: String) -> Bool {
        AppMenuCapabilityCache.shared.hasSnapshot(bundleIdentifier: bundleIdentifier)
    }

    nonisolated func cachedBundleIdentifiers() -> [String] {
        AppMenuCapabilityCache.shared.allCachedBundleIdentifiers()
    }

    /// "Quit"/"Quit <App>" from the app menu. "Quit and Keep Windows" (⌥⌘Q) has
    /// different semantics and stays on the regular menu-click path.
    nonisolated static func isPlainQuitAction(path: [String]) -> Bool {
        guard
            let last = path.last?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
            last == "quit" || last.hasPrefix("quit "),
            !last.contains("keep")
        else { return false }
        return true
    }

    nonisolated func verifyAndExecuteCachedMenu(
        _ request: GlobalMenuExecutionRequest
    ) async -> GlobalMenuExecutionResult {
        let bundleIdentifier = request.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleIdentifier.isEmpty, !request.path.isEmpty else {
            return GlobalMenuExecutionResult(
                status: .unavailable,
                app: nil,
                liveItem: nil,
                message: "Menu action unavailable"
            )
        }

        let wasRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
        }

        // Plain "Quit" needs no menu interaction: a graceful terminate() quits the
        // app in the background without activating it, so the launcher keeps key
        // focus instead of hiding when the target app would come frontmost.
        if Self.isPlainQuitAction(path: request.path) {
            guard wasRunning,
                let runningApp = NSWorkspace.shared.runningApplications.first(where: {
                    $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
                })
            else {
                return GlobalMenuExecutionResult(
                    status: .unavailable,
                    app: nil,
                    liveItem: nil,
                    message: "\(request.appName) isn't running"
                )
            }
            _ = await MainActor.run { runningApp.terminate() }
            return GlobalMenuExecutionResult(
                status: .executed,
                app: nil,
                liveItem: nil,
                message: "Quit \(request.appName)"
            )
        }

        guard let app = await activateOrLaunchApp(
            bundleIdentifier: bundleIdentifier,
            appName: request.appName,
            appPath: request.appPath
        ) else {
            return GlobalMenuExecutionResult(
                status: .launchFailed,
                app: nil,
                liveItem: nil,
                message: "Could not open \(request.appName)"
            )
        }

        let pid = app.processIdentifier
        await prepareAppForMenuExecution(app)
        await AXActionResolver.waitForActivation(of: app)
        await MenuExecutionCoordinator.restoreWindowIfAllMinimized(app)
        await waitForAppShortcutReadiness(app)
        // Only wait for app to settle menus when it was just launched; already-running apps are ready
        if !wasRunning {
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        let isWindowMenuAction = isWindowMenuPath(request.path)
        let isCloseDocumentAction = isVolatileCloseDocumentPath(request.path)
        let shouldTryCachedShortcutFallback =
            isWindowMenuAction
            || isStopMenuPath(request.path)
            || isCloseDocumentAction
            || (request.shortcutChar?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)

        guard let liveMatch = await waitForExecutableMenuItem(
            path: request.path,
            app: app,
            pid: pid,
            attempts: wasRunning ? 6 : 16,
            pauseNanoseconds: 120_000_000
        ) else {
            if shouldTryCachedShortcutFallback {
                if isCloseDocumentAction {
                    let executed = await executeCloseWindowFallback(pid: pid, app: app)
                    await MainActor.run {
                        AXMenuReader.shared.invalidateCache(for: pid)
                    }
                    await forceRefreshCache(for: app)
                    return GlobalMenuExecutionResult(
                        status: executed ? .executed : .unavailable,
                        app: app,
                        liveItem: nil,
                        message: executed
                            ? "Closed \(request.appName) window"
                            : "\(request.appName) action is not available right now"
                    )
                }
                let executed = await executeMenuAction(
                    path: request.path,
                    shortcutChar: request.shortcutChar,
                    shortcutModifiers: request.shortcutModifiers,
                    pid: pid,
                    app: app
                )
                await MainActor.run {
                    AXMenuReader.shared.invalidateCache(for: pid)
                }
                await forceRefreshCache(for: app)
                return GlobalMenuExecutionResult(
                    status: executed ? .executionFallback : .unavailable,
                    app: app,
                    liveItem: nil,
                    message: executed
                        ? "Tried \(request.path.last ?? "Menu action")"
                        : "\(request.appName) action is not available right now"
                )
            }
            await forceRefreshCache(for: app)
            return GlobalMenuExecutionResult(
                status: .unavailable,
                app: app,
                liveItem: nil,
                message: "\(request.appName) action is not available right now"
            )
        }

        let isStopMenuAction = isStopMenuPath(liveMatch.path)
        let liveCloseDocumentAction = isVolatileCloseDocumentPath(liveMatch.path)
        if liveCloseDocumentAction && !liveMatch.isEnabled {
            let executed = await executeCloseWindowFallback(pid: pid, app: app)
            await MainActor.run {
                AXMenuReader.shared.invalidateCache(for: pid)
            }
            await forceRefreshCache(for: app)
            return GlobalMenuExecutionResult(
                status: executed ? .executed : .unavailable,
                app: app,
                liveItem: liveMatch,
                message: executed
                    ? "Closed \(request.appName) window"
                    : "\(request.appName) action is not available right now"
            )
        }

        guard liveMatch.isEnabled || isWindowMenuAction || isStopMenuAction || liveCloseDocumentAction else {
            let clicked = await MainActor.run {
                AXMenuReader.shared.clickMenuItem(path: liveMatch.path, in: pid)
            }
            if clicked {
                await MainActor.run {
                    AXMenuReader.shared.invalidateCache(for: pid)
                }
                await forceRefreshCache(for: app)
                return GlobalMenuExecutionResult(
                    status: .executionFallback,
                    app: app,
                    liveItem: liveMatch,
                    message: "Tried \(liveMatch.title)"
                )
            }
            await forceRefreshCache(for: app)
            return GlobalMenuExecutionResult(
                status: .unavailable,
                app: app,
                liveItem: liveMatch,
                message: "\(request.appName) action is not available right now"
            )
        }

        if isStopMenuAction {
            let executed = await executeMenuAction(
                path: liveMatch.path,
                shortcutChar: request.shortcutChar ?? liveMatch.shortcutChar,
                shortcutModifiers: request.shortcutModifiers != 0
                    ? request.shortcutModifiers
                    : liveMatch.shortcutModifiers,
                pid: pid,
                app: app
            )
            await MainActor.run {
                AXMenuReader.shared.invalidateCache(for: pid)
            }
            await forceRefreshCache(for: app)
            return GlobalMenuExecutionResult(
                status: executed ? .executed : .executionFallback,
                app: app,
                liveItem: liveMatch,
                message: executed ? "Executed \(liveMatch.title)" : "Tried \(liveMatch.title)"
            )
        }

        let preferredShortcut = (request.shortcutChar ?? liveMatch.shortcutChar)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let preferredModifiers = request.shortcutModifiers != 0
            ? request.shortcutModifiers
            : liveMatch.shortcutModifiers

        let executed = await executeMenuAction(
            path: liveMatch.path,
            shortcutChar: preferredShortcut,
            shortcutModifiers: preferredModifiers,
            pid: pid,
            app: app
        )

        await MainActor.run {
            AXMenuReader.shared.invalidateCache(for: pid)
        }
        await forceRefreshCache(for: app)

        if executed {
            return GlobalMenuExecutionResult(
                status: .executed,
                app: app,
                liveItem: liveMatch,
                message: "Executed \(liveMatch.title)"
            )
        }

        await MainActor.run {
            AXActionResolver.shared.execute(menuPath: liveMatch.path, in: app)
        }
        return GlobalMenuExecutionResult(
            status: .executionFallback,
            app: app,
            liveItem: liveMatch,
            message: "Tried \(liveMatch.title)"
        )
    }

    nonisolated func crossAppMenuDescriptorGroups(
        query: String,
        runningApps: [GlobalMenuAppSnapshot],
        excludedBundleIDs: Set<String>,
        includeCachedNonRunning: Bool = true,
        limit: Int = 12
    ) -> [GlobalMenuDescriptorGroup] {
        let q = normalizedGlobalMenuQuery(query)
        guard !q.isEmpty else { return [] }

        // Fetch more per app than the global cap so the flat sort has enough
        // candidates to pick from — a tight per-app cap would starve apps whose
        // second-best item scores higher than another app's first-best.
        let perAppFetch = q.count == 1 ? 4 : (q.count == 2 ? 6 : 10)
        let runningBundleIDs = Set(runningApps.map(\.bundleID))
        let sortedRunning = runningApps
            .filter { !excludedBundleIDs.contains($0.bundleID) }

        var candidateApps = sortedRunning
        if includeCachedNonRunning {
            let nonRunning = cachedBundleIdentifiers()
                .filter {
                    !runningBundleIDs.contains($0)
                        && !excludedBundleIDs.contains($0)
                }
                .compactMap(nonRunningAppSnapshot(bundleID:))
                .sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            candidateApps.append(contentsOf: nonRunning)
        }

        let scopedQuery = scopedGlobalMenuQuery(query: q, candidateApps: candidateApps)

        // Collect all matching descriptors across every app, then sort globally.
        // This ensures the top-N results are the highest-scoring items worldwide,
        // not just the top item from each app group.
        var allDescriptors: [GlobalMenuDescriptor] = []
        for app in candidateApps {
            if let appFilter = scopedQuery.appFilter,
                !globalMenuAppNameMatches(appFilter, app: app)
            {
                continue
            }
            let descriptors = menuDescriptors(
                for: app, query: scopedQuery.actionQuery, limit: perAppFetch)
            allDescriptors.append(contentsOf: descriptors)
        }

        // Flat global sort: best item worldwide wins, regardless of which app it's from.
        let topDescriptors = allDescriptors
            .sorted {
                if $0.rankingScore != $1.rankingScore { return $0.rankingScore > $1.rankingScore }
                // Tie-break: running app items before non-running
                let lhsRunning = runningBundleIDs.contains($0.bundleID)
                let rhsRunning = runningBundleIDs.contains($1.bundleID)
                if lhsRunning != rhsRunning { return lhsRunning }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            .prefix(limit)

        // Re-group by app preserving the global ranking order within each group.
        var seenBundleIDs: [String] = []
        var byBundleID: [String: [GlobalMenuDescriptor]] = [:]
        for descriptor in topDescriptors {
            if byBundleID[descriptor.bundleID] == nil {
                seenBundleIDs.append(descriptor.bundleID)
            }
            byBundleID[descriptor.bundleID, default: []].append(descriptor)
        }

        return seenBundleIDs.compactMap { bundleID -> GlobalMenuDescriptorGroup? in
            guard let descriptors = byBundleID[bundleID], !descriptors.isEmpty,
                  let app = candidateApps.first(where: { $0.bundleID == bundleID })
            else { return nil }
            return GlobalMenuDescriptorGroup(
                bundleID: bundleID,
                appName: app.name,
                icon: app.icon,
                descriptors: descriptors
            )
        }
    }

    nonisolated private func scopedGlobalMenuQuery(
        query: String,
        candidateApps: [GlobalMenuAppSnapshot]
    ) -> (actionQuery: String, appFilter: String?) {
        let tokens = query.split(separator: " ").map(String.init)
        guard tokens.count > 1, globalMenuActionPrefixes.contains(tokens[0]) else {
            return (query, nil)
        }

        let appFilter = tokens.dropFirst().joined(separator: " ")
        guard candidateApps.contains(where: { globalMenuAppNameMatches(appFilter, app: $0) }) else {
            return (query, nil)
        }
        return (tokens[0], appFilter)
    }

    nonisolated private func globalMenuAppNameMatches(
        _ appFilter: String,
        app: GlobalMenuAppSnapshot
    ) -> Bool {
        ([app.name] + app.name.split(separator: " ").map(String.init))
            .map(normalizedGlobalMenuQuery)
            .contains(where: { $0.hasPrefix(appFilter) || $0.contains(appFilter) })
    }

    nonisolated private var globalMenuActionPrefixes: Set<String> {
        [
            "close", "copy", "cut", "find", "hide", "minimize", "open", "paste",
            "print", "quit", "redo", "save", "select", "undo", "zoom",
        ]
    }

    nonisolated private func normalizedGlobalMenuQuery(_ query: String) -> String {
        let normalized = AppMenuCapabilityCache.normalize(query)
        if normalized == "minimise" { return "minimize" }
        if normalized.hasPrefix("minimise ") {
            return "minimize " + normalized.dropFirst("minimise ".count)
        }
        return normalized
    }

    nonisolated private func menuDescriptors(
        for app: GlobalMenuAppSnapshot,
        query: String,
        limit: Int
    ) -> [GlobalMenuDescriptor] {
        let rawItems = cachedMenuItems(
            bundleIdentifier: app.bundleID,
            appName: app.name,
            processIdentifier: app.processIdentifier,
            query: query,
            maxResults: max(limit, 1)
        )

        let descriptors = rawItems.compactMap { item -> GlobalMenuDescriptor? in
            guard AppMenuCapabilityCache.shouldExposeInGlobalContext(
                title: item.title,
                path: item.path
            ) else { return nil }

            let nameLower = item.title.lowercased()
            let contextLower = (item.path.dropLast().last ?? "").lowercased()
            let pathLower = item.path.joined(separator: " ").lowercased()
            guard nameLower.hasPrefix(query) || nameLower.contains(query)
                    || contextLower.hasPrefix(query) || contextLower.contains(query)
                    || pathLower.contains(query)
            else { return nil }

            return GlobalMenuDescriptor(
                id: "xapp-\(app.bundleID)-\(item.path.joined(separator: ">"))",
                name: item.title,
                badge: shortcutDisplay(char: item.shortcutChar, modifiers: item.shortcutModifiers),
                statusBadge: app.isRunning ? nil : "Needs launch",
                bundleID: app.bundleID,
                appName: app.name,
                appIcon: app.icon,
                path: item.path,
                shortcutChar: item.shortcutChar,
                shortcutModifiers: item.shortcutModifiers,
                rankingScore: menuScore(item: item, query: query)
            )
        }

        return descriptors.sorted {
            if $0.rankingScore != $1.rankingScore {
                return $0.rankingScore > $1.rankingScore
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    nonisolated private func nonRunningAppSnapshot(bundleID: String) -> GlobalMenuAppSnapshot? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let name = Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? appURL.deletingPathExtension().lastPathComponent
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        return GlobalMenuAppSnapshot(
            bundleID: bundleID,
            name: name,
            icon: icon,
            processIdentifier: 0,
            isRunning: false
        )
    }

    nonisolated private func activateOrLaunchApp(
        bundleIdentifier: String,
        appName: String,
        appPath: String?
    ) async -> NSRunningApplication? {
        if let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
        }) {
            await MainActor.run {
                if runningApp.isHidden { runningApp.unhide() }
                runningApp.activate(options: [.activateIgnoringOtherApps])
            }
            return runningApp
        }

        let appURL =
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            ?? appPath.flatMap { URL(fileURLWithPath: $0) }
        guard let appURL else { return nil }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let launched = try? await NSWorkspace.shared.openApplication(
            at: appURL,
            configuration: configuration
        ) {
            return launched
        }

        NSWorkspace.shared.open(appURL)
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if let runningApp = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
            }) {
                await MainActor.run {
                    if runningApp.isHidden { runningApp.unhide() }
                    runningApp.activate(options: [.activateIgnoringOtherApps])
                }
                return runningApp
            }
        }
        return nil
    }

    nonisolated private func prepareAppForMenuExecution(_ app: NSRunningApplication) async {
        let pid = app.processIdentifier
        await MainActor.run {
            let axApp = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let windows = windowsRef as? [AXUIElement] {
                for window in windows {
                    var minimized: CFTypeRef?
                    if AXUIElementCopyAttributeValue(
                        window,
                        kAXMinimizedAttribute as CFString,
                        &minimized
                    ) == .success,
                       (minimized as? Bool) == true {
                        AXUIElementSetAttributeValue(
                            window,
                            kAXMinimizedAttribute as CFString,
                            kCFBooleanFalse
                        )
                    }
                }
            }
            if app.isHidden { app.unhide() }
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    nonisolated private func waitForAppShortcutReadiness(_ app: NSRunningApplication) async {
        let bundleIdentifier = app.bundleIdentifier ?? ""
        let pid = app.processIdentifier
        guard !bundleIdentifier.isEmpty else { return }

        for attempt in 0..<12 {
            let frontmostBundleIdentifier =
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            let axApp = AXUIElementCreateApplication(pid)
            var focusedWindow: CFTypeRef?
            let hasFocusedWindow =
                AXUIElementCopyAttributeValue(
                    axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow
                ) == .success
                && focusedWindow != nil
            if frontmostBundleIdentifier == bundleIdentifier && app.isActive && hasFocusedWindow {
                return
            }
            if attempt < 11 {
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
        }
    }

    nonisolated private func waitForExecutableMenuItem(
        path: [String],
        app: NSRunningApplication,
        pid: pid_t,
        attempts: Int,
        pauseNanoseconds: UInt64
    ) async -> AXMenuItem? {
        for attempt in 0..<attempts {
            let liveItems = await MainActor.run {
                AXMenuReader.shared.refreshAllMenuItems(for: pid, maxDepth: 6)
            }
            if !liveItems.isEmpty {
                await MainActor.run {
                    AppMenuCapabilityCache.shared.store(items: liveItems, for: app)
                }
            }
            if let match = liveItems.first(where: { menuPathMatches($0, targetPath: path) }) {
                return match
            }
            await MainActor.run {
                AXMenuReader.shared.invalidateCache(for: pid)
            }
            if attempt < attempts - 1 {
                try? await Task.sleep(nanoseconds: pauseNanoseconds)
            }
        }
        return nil
    }

    nonisolated private func forceRefreshCache(for app: NSRunningApplication) async {
        let pid = app.processIdentifier
        await MainActor.run {
            AXMenuReader.shared.invalidateCache(for: pid)
        }
        await MenuWarmCacheService.shared.warm(app: app, force: true)
        let liveItems = await MainActor.run {
            AXMenuReader.shared.peekCachedAllMenuItems(for: pid)
        }
        if !liveItems.isEmpty {
            await MainActor.run {
                AppMenuCapabilityCache.shared.store(items: liveItems, for: app)
            }
        }
    }

    nonisolated private func menuPathMatches(_ item: AXMenuItem, targetPath: [String]) -> Bool {
        let normalizedTarget = normalizedMenuPathForMatching(targetPath)
        let normalizedItem = normalizedMenuPathForMatching(item.path)
        if normalizedItem == normalizedTarget { return true }
        if item.isAppleMenu {
            let strippedTarget = normalizedTarget.filter { $0 != "apple" }
            return !strippedTarget.isEmpty && normalizedItem == strippedTarget
        }
        return false
    }

    nonisolated private func normalizedMenuPathForMatching(_ path: [String]) -> [String] {
        path.map {
            var normalized = $0
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized == "minimise" { normalized = "minimize" }
            if normalized == "minimise all" { normalized = "minimize all" }
            return normalized
        }
        .filter { !$0.isEmpty }
    }

    nonisolated private func isWindowMenuPath(_ path: [String]) -> Bool {
        normalizedMenuPathForMatching(path).first == "window"
    }

    nonisolated private func isVolatileCloseDocumentPath(_ path: [String]) -> Bool {
        let normalized = normalizedMenuPathForMatching(path)
        guard normalized.first == "file", let last = normalized.last else { return false }
        return last == "close selected"
            || last.hasPrefix("close selected ")
            || last.hasPrefix("close current ")
    }

    nonisolated private func isStopMenuPath(_ path: [String]) -> Bool {
        let normalized = normalizedMenuPathForMatching(path)
        guard normalized.last == "stop" else { return false }
        return normalized.contains("product") || normalized.contains("run")
    }

    nonisolated private func executeCloseWindowFallback(
        pid: pid_t,
        app: NSRunningApplication
    ) async -> Bool {
        await MainActor.run {
            if !app.isActive {
                _ = app.activate(options: [.activateIgnoringOtherApps])
            }
        }
        await AXActionResolver.waitForActivation(of: app)

        let candidates = [
            ["File", "Close Window"],
            ["File", "Close"],
        ]
        for path in candidates {
            if await MainActor.run(body: { AXMenuReader.shared.clickMenuItem(path: path, in: pid) }) {
                return true
            }
        }
        if await MainActor.run(body: {
            AXMenuReader.shared.executeShortcut(char: "w", modifiers: 0, in: pid)
        }) {
            return true
        }
        return await MainActor.run(body: {
            AXMenuReader.shared.executeShortcutToFrontmost(char: "w", modifiers: 0)
        })
    }

    nonisolated private func executeMenuAction(
        path: [String],
        shortcutChar: String?,
        shortcutModifiers: Int,
        pid: pid_t,
        app: NSRunningApplication
    ) async -> Bool {
        let shortcut = shortcutChar?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedTitle = path.last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if normalizedTitle == "paste",
           await MainActor.run(body: { AXMenuReader.shared.clickMenuItem(path: path, in: pid) }) {
            return true
        }
        if isStopMenuPath(path), shortcut == ".",
           await MainActor.run(body: {
               AXMenuReader.shared.executeShortcutToFrontmost(
                   char: shortcut,
                   modifiers: shortcutModifiers
               )
           }) {
            return true
        }
        if !shortcut.isEmpty,
           await MainActor.run(body: {
               AXMenuReader.shared.executeShortcut(char: shortcut, modifiers: shortcutModifiers, in: pid)
           }) {
            return true
        }
        if await MainActor.run(body: { AXMenuReader.shared.clickMenuItem(path: path, in: pid) }) {
            return true
        }
        await MainActor.run {
            AXActionResolver.shared.execute(menuPath: path, in: app)
        }
        return true
    }

    nonisolated private func menuScore(item: AXMenuItem, query: String) -> Double {
        let title = item.title.lowercased()
        let context = (item.path.dropLast().last ?? "").lowercased()
        let path = item.path.joined(separator: " ").lowercased()
        var score = 0.0
        if title == query { score += 10_000 }
        if title.hasPrefix(query) { score += 7_500 }
        if title.contains(query) { score += 4_000 }
        if context.hasPrefix(query) { score += 2_500 }
        if context.contains(query) { score += 1_500 }
        if path.contains(query) { score += 800 }
        if item.isEnabled { score += 100 }
        score -= Double(item.path.count)
        score -= Double(title.count) * 0.01
        return score
    }

    nonisolated private func shortcutDisplay(char: String?, modifiers: Int) -> String? {
        MenuShortcutFormatter.display(char: char, modifiers: modifiers)
    }
}
