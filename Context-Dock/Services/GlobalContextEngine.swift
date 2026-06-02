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
        await waitForAppShortcutReadiness(app)
        try? await Task.sleep(nanoseconds: 120_000_000)

        let isWindowMenuAction = isWindowMenuPath(request.path)

        guard let liveMatch = await waitForExecutableMenuItem(
            path: request.path,
            app: app,
            pid: pid,
            attempts: 16,
            pauseNanoseconds: 120_000_000
        ) else {
            if isWindowMenuAction {
                let executed = executeMenuAction(
                    path: request.path,
                    shortcutChar: request.shortcutChar,
                    shortcutModifiers: request.shortcutModifiers,
                    pid: pid,
                    app: app
                )
                AXMenuReader.shared.invalidateCache(for: pid)
                await forceRefreshCache(for: app)
                return GlobalMenuExecutionResult(
                    status: executed ? .executionFallback : .unavailable,
                    app: app,
                    liveItem: nil,
                    message: executed
                        ? "Tried \(request.path.last ?? "Window action")"
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

        guard liveMatch.isEnabled || isWindowMenuAction else {
            await forceRefreshCache(for: app)
            return GlobalMenuExecutionResult(
                status: .unavailable,
                app: app,
                liveItem: liveMatch,
                message: "\(request.appName) action is not available right now"
            )
        }

        let preferredShortcut = (request.shortcutChar ?? liveMatch.shortcutChar)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let preferredModifiers = request.shortcutModifiers != 0
            ? request.shortcutModifiers
            : liveMatch.shortcutModifiers

        let executed = executeMenuAction(
            path: liveMatch.path,
            shortcutChar: preferredShortcut,
            shortcutModifiers: preferredModifiers,
            pid: pid,
            app: app
        )

        AXMenuReader.shared.invalidateCache(for: pid)
        await forceRefreshCache(for: app)

        if executed {
            return GlobalMenuExecutionResult(
                status: .executed,
                app: app,
                liveItem: liveMatch,
                message: "Executed \(liveMatch.title)"
            )
        }

        AXActionResolver.shared.execute(menuPath: liveMatch.path, in: app)
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
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }

        let perAppCap = q.count == 1 ? 3 : (q.count == 2 ? 4 : 6)
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

        var groups: [GlobalMenuDescriptorGroup] = []
        var total = 0
        for app in candidateApps {
            guard total < limit else { break }
            let remaining = min(perAppCap, limit - total)
            let descriptors = menuDescriptors(for: app, query: q, limit: remaining)
            guard !descriptors.isEmpty else { continue }
            groups.append(GlobalMenuDescriptorGroup(
                bundleID: app.bundleID,
                appName: app.name,
                icon: app.icon,
                descriptors: descriptors
            ))
            total += descriptors.count
        }
        return groups
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
                statusBadge: app.isRunning ? "Cached" : "Needs launch",
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
            let liveItems = AXMenuReader.shared.refreshAllMenuItems(for: pid, maxDepth: 6)
            if !liveItems.isEmpty {
                AppMenuCapabilityCache.shared.store(items: liveItems, for: app)
            }
            if let match = liveItems.first(where: { menuPathMatches($0, targetPath: path) }) {
                return match
            }
            AXMenuReader.shared.invalidateCache(for: pid)
            if attempt < attempts - 1 {
                try? await Task.sleep(nanoseconds: pauseNanoseconds)
            }
        }
        return nil
    }

    nonisolated private func forceRefreshCache(for app: NSRunningApplication) async {
        let pid = app.processIdentifier
        AXMenuReader.shared.invalidateCache(for: pid)
        await MenuWarmCacheService.shared.warm(app: app, force: true)
        let liveItems = AXMenuReader.shared.peekCachedAllMenuItems(for: pid)
        if !liveItems.isEmpty {
            AppMenuCapabilityCache.shared.store(items: liveItems, for: app)
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

    nonisolated private func executeMenuAction(
        path: [String],
        shortcutChar: String?,
        shortcutModifiers: Int,
        pid: pid_t,
        app: NSRunningApplication
    ) -> Bool {
        let shortcut = shortcutChar?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedTitle = path.last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if normalizedTitle == "paste",
           AXMenuReader.shared.clickMenuItem(path: path, in: pid) {
            return true
        }
        if !shortcut.isEmpty,
           AXMenuReader.shared.executeShortcut(char: shortcut, modifiers: shortcutModifiers, in: pid) {
            return true
        }
        if AXMenuReader.shared.clickMenuItem(path: path, in: pid) {
            return true
        }
        AXActionResolver.shared.execute(menuPath: path, in: app)
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
