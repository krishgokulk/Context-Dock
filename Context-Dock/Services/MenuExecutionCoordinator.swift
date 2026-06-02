import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class MenuExecutionCoordinator {
    static let shared = MenuExecutionCoordinator()

    private var executionTask: Task<Void, Never>?

    private init() {}

    struct DockMenuActionRequest {
        let sourcePID: pid_t
        let path: [String]
        let shortcutChar: String?
        let shortcutModifiers: Int
        let knownMenuItems: [AXMenuItem]
        let isGlobalContextActive: Bool
        let hasActiveDockContextSelection: Bool
    }

    struct DockMenuActionCallbacks {
        let collapseBeforeExecution: @MainActor () -> Void
        let collapseFinderToIcon: @MainActor () -> Void
        let focusLauncher: @MainActor () -> Void
        let refreshRunningApps: @MainActor () -> Void
        let scheduleTerminationRefresh: @MainActor (NSRunningApplication) -> Void
        let reloadMenu: @MainActor (NSRunningApplication) -> Void
        let clearLiveDockMenuState: @MainActor () -> Void
    }

    func executeDockMenuAction(
        request: DockMenuActionRequest,
        callbacks: DockMenuActionCallbacks
    ) {
        guard request.sourcePID != 0 else { return }
        guard executionTask == nil else {
            AppToast.show("Action already running", icon: "clock", tint: .secondary)
            return
        }
        let isQuitAction = Self.isQuitMenuPath(request.path)
        let normalizedPath = request.path.map(Self.normalizedMenuText)
        let isWindowMenuAction = normalizedPath.first == "window"

        let needsLiveSelectionValidation =
            Self.isVolatileSelectionMenuPath(request.path)
        let shouldKeepLauncherHiddenAfterExecution =
            normalizedPath.contains("open with")
            || needsLiveSelectionValidation
            || (request.isGlobalContextActive && request.hasActiveDockContextSelection)

        executionTask = Task { [self] in
            defer { executionTask = nil }
            guard
                let sourceApp = NSWorkspace.shared.runningApplications.first(where: {
                    $0.processIdentifier == request.sourcePID && !$0.isTerminated
                })
            else { return }

            let shouldCollapseBeforeExecution =
                shouldKeepLauncherHiddenAfterExecution
                || sourceApp.bundleIdentifier == "com.apple.finder"

            let pid = sourceApp.processIdentifier

            if sourceApp.bundleIdentifier == "com.apple.finder" {
                let directResult = await FinderActionService.shared.executeDirectActionIfNeeded(
                    path: request.path
                )
                if case let .handled(success, message, icon, tint) = directResult {
                    await MainActor.run {
                        AppToast.show(message, icon: icon, tint: tint)
                        MenuWarmCacheService.shared.frontmostAppDidChange(sourceApp)
                        if success { callbacks.collapseFinderToIcon() }
                    }
                    return
                }
            }

            var executablePath = request.path
            var executableShortcutChar = request.shortcutChar
            var executableShortcutModifiers = request.shortcutModifiers
            if needsLiveSelectionValidation {
                let liveMatch = await Self.waitForExecutableMenuItem(
                    path: request.path,
                    app: sourceApp,
                    in: request.sourcePID,
                    attempts: 5,
                    pauseNanoseconds: 80_000_000
                )
                guard let liveMatch, liveMatch.isEnabled else {
                    await MainActor.run {
                        AppToast.show(
                            "Action is not available for the current selection",
                            icon: "exclamationmark.triangle",
                            tint: .orange.opacity(0.9)
                        )
                        callbacks.reloadMenu(sourceApp)
                    }
                    return
                }
                executablePath = liveMatch.path
                executableShortcutChar = executableShortcutChar ?? liveMatch.shortcutChar
                if executableShortcutModifiers == 0 {
                    executableShortcutModifiers = liveMatch.shortcutModifiers
                }
            }

            let isWindowStateAction = Self.isWindowStateAction(executablePath)

            await MainActor.run {
                if shouldCollapseBeforeExecution {
                    callbacks.collapseBeforeExecution()
                } else {
                    AppDelegate.shared?.launcherWindow?.resignKey()
                }
            }
            // Let dock collapse commit before target activation sends AX or keyboard events.
            // Running both paths in one render turn caused icon-mode layout races.
            try? await Task.sleep(
                nanoseconds: shouldCollapseBeforeExecution ? 180_000_000 : 40_000_000)
            await MainActor.run {
                if sourceApp.isHidden { sourceApp.unhide() }
                sourceApp.activate(options: [.activateIgnoringOtherApps])
                Self.unminimizeWindows(pid: pid)
            }
            await AXActionResolver.waitForActivation(of: sourceApp)
            try? await Task.sleep(nanoseconds: 80_000_000)

            if let liveMatch = await Self.waitForExecutableMenuItem(
                    path: executablePath,
                    app: sourceApp,
                    in: request.sourcePID,
                    attempts: isWindowMenuAction ? 3 : 2,
                    pauseNanoseconds: 60_000_000
                )
            {
                executablePath = liveMatch.path
                if executableShortcutChar?.isEmpty != false {
                    executableShortcutChar = liveMatch.shortcutChar
                }
                if executableShortcutModifiers == 0 {
                    executableShortcutModifiers = liveMatch.shortcutModifiers
                }
            }

            let preferredShortcut = executableShortcutChar?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let directWindowActionHandled =
                isWindowMenuAction
                && Self.shouldPreferDirectWindowManagementAction(executablePath)
                && self.executeWindowManagementActionIfNeeded(
                    path: executablePath,
                    sourceApp: sourceApp
                )
            let pasteMenuClicked =
                !directWindowActionHandled
                && Self.isPasteMenuPath(executablePath)
                && AXMenuReader.shared.clickMenuItem(path: executablePath, in: request.sourcePID)
            let shortcutSent =
                !directWindowActionHandled && !pasteMenuClicked
                && !preferredShortcut.isEmpty
                && AXMenuReader.shared.executeShortcut(
                    char: preferredShortcut,
                    modifiers: executableShortcutModifiers,
                    in: request.sourcePID
                )

            let menuClicked =
                !directWindowActionHandled && !pasteMenuClicked && !shortcutSent
                && AXMenuReader.shared.clickMenuItem(path: executablePath, in: request.sourcePID)
            let fallbackWindowActionHandled =
                !directWindowActionHandled && !shortcutSent && !menuClicked && isWindowMenuAction
                && self.executeWindowManagementActionIfNeeded(
                    path: executablePath,
                    sourceApp: sourceApp
                )
            let actionSent =
                directWindowActionHandled || pasteMenuClicked || shortcutSent || menuClicked
                || fallbackWindowActionHandled

            if !actionSent {
                AXActionResolver.shared.execute(menuPath: executablePath, in: sourceApp)
            }

            try? await Task.sleep(nanoseconds: 250_000_000)

            if actionSent && !isQuitAction {
                await MainActor.run {
                    if !isWindowStateAction && !shouldCollapseBeforeExecution {
                        callbacks.focusLauncher()
                    }
                    callbacks.refreshRunningApps()
                    MenuWarmCacheService.shared.frontmostAppDidChange(sourceApp)
                    if sourceApp.bundleIdentifier == "com.apple.finder" {
                        callbacks.collapseFinderToIcon()
                    }
                }
                return
            }

            AXMenuReader.shared.invalidateCache(for: request.sourcePID)

            await MainActor.run {
                if isQuitAction {
                    callbacks.scheduleTerminationRefresh(sourceApp)
                    return
                }

                if !isWindowStateAction && !shouldCollapseBeforeExecution {
                    callbacks.focusLauncher()
                }
                callbacks.refreshRunningApps()
                if let liveApp = NSWorkspace.shared.runningApplications.first(where: {
                    $0.processIdentifier == request.sourcePID && !$0.isTerminated
                }) {
                    callbacks.reloadMenu(liveApp)
                } else {
                    callbacks.clearLiveDockMenuState()
                }
                if sourceApp.bundleIdentifier == "com.apple.finder" {
                    callbacks.collapseFinderToIcon()
                }
            }

            try? await Task.sleep(nanoseconds: 400_000_000)
            AXMenuReader.shared.invalidateCache(for: request.sourcePID)
            await MainActor.run {
                guard
                    let liveApp = NSWorkspace.shared.runningApplications.first(where: {
                        $0.processIdentifier == request.sourcePID && !$0.isTerminated
                    })
                else { return }
                callbacks.reloadMenu(liveApp)
            }
        }
    }

    func executeWindowManagementActionIfNeeded(
        path: [String],
        sourceApp: NSRunningApplication
    ) -> Bool {
        WindowManagementService.shared.executeIfSupported(path: path, sourceApp: sourceApp)
    }

    private static func waitForExecutableMenuItem(
        path: [String],
        app: NSRunningApplication,
        in pid: pid_t,
        attempts: Int,
        pauseNanoseconds: UInt64
    ) async -> AXMenuItem? {
        guard !path.isEmpty else { return nil }

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

    private static func menuPathMatches(_ item: AXMenuItem, targetPath: [String]) -> Bool {
        let normalizedTarget = normalizedMenuPathForMatching(targetPath)
        let normalizedItem = normalizedMenuPathForMatching(item.path)

        if normalizedItem == normalizedTarget {
            return true
        }

        if item.isAppleMenu {
            let strippedTarget = normalizedTarget.filter { $0 != "apple" }
            if !strippedTarget.isEmpty && normalizedItem == strippedTarget {
                return true
            }
        }

        return false
    }

    private static func isQuitMenuPath(_ path: [String]) -> Bool {
        guard let last = path.last else { return false }
        let normalized = normalizedMenuText(last)
        return normalized == "quit" || normalized.hasPrefix("quit ")
    }

    private static func isPasteMenuPath(_ path: [String]) -> Bool {
        normalizedMenuText(path.last ?? "") == "paste"
    }

    private static func isCloseWindowMenuPath(_ path: [String]) -> Bool {
        guard let last = path.last else { return false }
        let normalized = normalizedMenuText(last)
        return normalized == "close window"
            || normalized == "close all"
            || normalized == "close all windows"
    }

    private static func isVolatileSelectionMenuPath(_ path: [String]) -> Bool {
        let normalized = normalizedMenuPathForMatching(path)
        guard !normalized.isEmpty else { return false }
        let joined = normalized.joined(separator: " ")
        let volatileExact: Set<String> = [
            "compress",
            "duplicate",
            "make alias",
            "quick look",
            "print",
            "rename",
            "move to bin",
            "move to trash",
            "delete immediately",
            "open with",
            "share",
            "tags",
        ]
        let leaf = normalized.last ?? ""
        if volatileExact.contains(leaf) || normalized.contains("open with") { return true }
        return joined.contains("selected")
            || joined.contains("selection")
            || joined.contains("extract")
    }

    private static func isWindowStateAction(_ path: [String]) -> Bool {
        let name = path.last?.lowercased() ?? ""
        let root = path.first?.lowercased() ?? ""
        return name.contains("full screen") || name.contains("fullscreen")
            || name.contains("minimize") || name.contains("minimise")
            || name == "zoom" || name.contains("slideshow")
            || root == "window"
    }

    private static func shouldPreferDirectWindowManagementAction(_ path: [String]) -> Bool {
        let normalizedPath = path.map(normalizedMenuText)
        guard let title = normalizedPath.last else { return false }
        if title.contains("full screen") || title.contains("fullscreen") { return true }
        guard normalizedPath.contains("window") else { return false }
        return title == "minimize" || title == "minimise" || title == "zoom"
            || title == "centre" || title == "center" || title == "fill" || title.contains("fill")
            || title == "left" || title == "right" || title == "top" || title == "bottom"
            || title == "top left" || title == "top right"
            || title == "bottom left" || title == "bottom right"
            || title == "left right" || title == "right left"
            || title == "top bottom" || title == "bottom top"
            || title == "quarters" || title.contains("previous size")
            || title == "bring all to front" || title.hasPrefix("switch window")
    }

    private static func unminimizeWindows(pid: pid_t) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let axApp = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                let windows = windowsRef as? [AXUIElement]
            {
                for win in windows {
                    var minimized: CFTypeRef?
                    if AXUIElementCopyAttributeValue(
                        win, kAXMinimizedAttribute as CFString, &minimized) == .success,
                        (minimized as? Bool) == true
                    {
                        AXUIElementSetAttributeValue(
                            win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    }
                }
            }
        }
    }

    private static func normalizedMenuPathForMatching(_ path: [String]) -> [String] {
        path.map {
            $0
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
    }

    private static func normalizedMenuText(_ text: String) -> String {
        let lowered = text.lowercased()
        let mapped = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
            {
                return Character(scalar)
            }
            return " "
        }
        return String(mapped)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
