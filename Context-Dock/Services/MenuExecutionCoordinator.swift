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
        let keepsDockFloating: Bool
    }

    struct DockMenuActionCallbacks {
        let hideBeforeExecution: @MainActor () -> Void
        let refreshRunningApps: @MainActor () -> Void
        let scheduleTerminationRefresh: @MainActor (NSRunningApplication) -> Void
        let reloadMenu: @MainActor (NSRunningApplication) -> Void
        let clearLiveDockMenuState: @MainActor () -> Void
        let refocusDockInput: @MainActor () -> Void
    }

    /// macOS revalidates Accessibility for non-notarized (e.g. Xcode Debug) builds by cdhash,
    /// which changes every build — so the grant silently lapses and AX clicks / CGEvent
    /// shortcuts do nothing. Surface it instead of failing silently, and open the pane.
    @discardableResult
    static func ensureAccessibilityTrustOrPrompt() -> Bool {
        if AXIsProcessTrusted() { return true }
        AppToast.show(
            "Grant Accessibility to run app actions",
            icon: "exclamationmark.shield", tint: .orange)
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    func executeDockMenuAction(
        request: DockMenuActionRequest,
        callbacks: DockMenuActionCallbacks
    ) {
        guard request.sourcePID != 0 else { return }
        // No Accessibility trust → AX menu clicks and shortcut posting can't work; prompt.
        guard Self.ensureAccessibilityTrustOrPrompt() else { return }
        guard executionTask == nil else {
            AppToast.show("Action already running", icon: "clock", tint: .secondary)
            return
        }
        let isQuitAction = Self.isQuitMenuPath(request.path)
        let normalizedPath = request.path.map(Self.normalizedMenuText)
        let isWindowMenuAction = normalizedPath.first == "window"

        let needsLiveSelectionValidation =
            Self.isVolatileSelectionMenuPath(request.path)
        executionTask = Task { [self] in
            defer { executionTask = nil }
            guard
                let sourceApp = NSWorkspace.shared.runningApplications.first(where: {
                    $0.processIdentifier == request.sourcePID && !$0.isTerminated
                })
            else { return }

            let pid = sourceApp.processIdentifier

            if isQuitAction {
                await MainActor.run {
                    _ = sourceApp.terminate()
                    callbacks.scheduleTerminationRefresh(sourceApp)
                    callbacks.refreshRunningApps()
                    callbacks.clearLiveDockMenuState()
                    callbacks.refocusDockInput()
                }
                return
            }

            if sourceApp.bundleIdentifier == "com.apple.finder" {
                let directResult = await FinderActionService.shared.executeDirectActionIfNeeded(
                    path: request.path
                )
                if case let .handled(success, message, icon, tint) = directResult {
                    await MainActor.run {
                        DockActionFeedback.showResult(message, icon: icon, success: success)
                        MenuWarmCacheService.shared.frontmostAppDidChange(sourceApp)
                        callbacks.refreshRunningApps()
                        callbacks.refocusDockInput()
                        _ = tint
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

            await MainActor.run {
                callbacks.hideBeforeExecution()
            }
            // Let window dismissal commit before target activation sends AX or keyboard events.
            try? await Task.sleep(nanoseconds: 40_000_000)
            await MainActor.run {
                if sourceApp.isHidden { sourceApp.unhide() }
                sourceApp.activate(options: [.activateIgnoringOtherApps])
                Self.unminimizeWindows(pid: pid)
            }
            await AXActionResolver.waitForActivation(of: sourceApp)
            await Self.restoreWindowIfAllMinimized(sourceApp)
            try? await Task.sleep(nanoseconds: 80_000_000)

            if Self.isPasswordsApp(sourceApp),
                await Self.executePasswordsActionAfterUnlock(
                    path: executablePath,
                    shortcutChar: executableShortcutChar,
                    shortcutModifiers: executableShortcutModifiers,
                    app: sourceApp,
                    in: request.sourcePID
                )
            {
                try? await Task.sleep(nanoseconds: 250_000_000)
                await MainActor.run {
                    callbacks.refreshRunningApps()
                    MenuWarmCacheService.shared.frontmostAppDidChange(sourceApp)
                }
                return
            }

            let cachedShortcut = executableShortcutChar?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let directWindowActionHandled =
                isWindowMenuAction
                && Self.shouldPreferDirectWindowManagementAction(executablePath)
                && self.executeWindowManagementActionIfNeeded(
                    path: executablePath,
                    sourceApp: sourceApp
                )
            let cachedShortcutSent =
                !directWindowActionHandled
                && !cachedShortcut.isEmpty
                && AXMenuReader.shared.executeShortcut(
                    char: cachedShortcut,
                    modifiers: executableShortcutModifiers,
                    in: request.sourcePID
                )

            if !directWindowActionHandled, !cachedShortcutSent,
                let liveMatch = await Self.waitForExecutableMenuItem(
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
            let shortcutSent =
                cachedShortcutSent
                || (!directWindowActionHandled
                    && !preferredShortcut.isEmpty
                    && AXMenuReader.shared.executeShortcut(
                        char: preferredShortcut,
                        modifiers: executableShortcutModifiers,
                        in: request.sourcePID
                    ))
            let pasteMenuClicked =
                !directWindowActionHandled && !shortcutSent
                && Self.isPasteMenuPath(executablePath)
                && AXMenuReader.shared.clickMenuItemReliably(path: executablePath, in: request.sourcePID)
            let menuClicked =
                !directWindowActionHandled && !shortcutSent && !pasteMenuClicked
                && AXMenuReader.shared.clickMenuItemReliably(path: executablePath, in: request.sourcePID)

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
                    callbacks.refreshRunningApps()
                    MenuWarmCacheService.shared.frontmostAppDidChange(sourceApp)
                    if request.keepsDockFloating {
                        callbacks.refocusDockInput()
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

                callbacks.refreshRunningApps()
                if let liveApp = NSWorkspace.shared.runningApplications.first(where: {
                    $0.processIdentifier == request.sourcePID && !$0.isTerminated
                }) {
                    callbacks.reloadMenu(liveApp)
                } else {
                    callbacks.clearLiveDockMenuState()
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

    /// Live-verified menu execution for DoraX Action Chat (General AI Chat).
    /// Unlike `executeDockMenuAction` this has no dock-UI callbacks and reports the
    /// outcome back to the caller so chat can only claim success when it happened.
    /// The target menu item is re-read from the LIVE menu bar before executing —
    /// cached records alone are never trusted for execution.
    func executeVerifiedMenuAction(
        bundleIdentifier: String,
        path: [String],
        cachedShortcutChar: String? = nil,
        cachedShortcutModifiers: Int = 0
    ) async -> (success: Bool, message: String) {
        guard !path.isEmpty else { return (false, "Empty menu path.") }
        guard Self.ensureAccessibilityTrustOrPrompt() else {
            return (false, "Accessibility permission is required to run menu actions.")
        }
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
        }) else {
            return (false, "The app isn't running, so the menu action can't be verified.")
        }
        let pid = app.processIdentifier
        if app.isHidden { app.unhide() }
        app.activate(options: [.activateIgnoringOtherApps])
        await AXActionResolver.waitForActivation(of: app)
        try? await Task.sleep(nanoseconds: 80_000_000)

        guard let liveMatch = await Self.waitForExecutableMenuItem(
            path: path, app: app, in: pid, attempts: 3, pauseNanoseconds: 100_000_000
        ), liveMatch.isEnabled else {
            return (false, "\(path.joined(separator: " → ")) isn't available in "
                + "\(app.localizedName ?? bundleIdentifier) right now — nothing was executed.")
        }

        let shortcutChar = (cachedShortcutChar?.isEmpty == false
            ? cachedShortcutChar : liveMatch.shortcutChar)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shortcutModifiers = cachedShortcutModifiers != 0
            ? cachedShortcutModifiers : liveMatch.shortcutModifiers
        let pathLabel = liveMatch.path.joined(separator: " → ")

        // Fastest verified strategy first: post the item's own shortcut, then AX click.
        if !shortcutChar.isEmpty,
           AXMenuReader.shared.executeShortcut(char: shortcutChar, modifiers: shortcutModifiers, in: pid) {
            let shortcut = MenuShortcutFormatter.display(
                char: shortcutChar, modifiers: shortcutModifiers) ?? shortcutChar
            return (true, "Opened \(app.localizedName ?? bundleIdentifier) and sent \(shortcut) for \(pathLabel).")
        }
        if AXMenuReader.shared.clickMenuItemReliably(path: liveMatch.path, in: pid) {
            return (true, "Opened \(app.localizedName ?? bundleIdentifier) and clicked \(pathLabel).")
        }
        return (false, "Found \(pathLabel) but the click didn't register — nothing was confirmed.")
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

    private static func executePasswordsActionAfterUnlock(
        path: [String],
        shortcutChar: String?,
        shortcutModifiers: Int,
        app: NSRunningApplication,
        in pid: pid_t
    ) async -> Bool {
        guard !path.isEmpty else { return false }
        let trimmedShortcut = shortcutChar?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        for attempt in 0..<90 {
            if Task.isCancelled || app.isTerminated { return false }

            if attempt > 0, attempt.isMultiple(of: 8) {
                await MainActor.run {
                    if app.isHidden { app.unhide() }
                    app.activate(options: [.activateIgnoringOtherApps])
                }
            }

            let liveMatch = await waitForExecutableMenuItem(
                path: path,
                app: app,
                in: pid,
                attempts: 1,
                pauseNanoseconds: 0
            )

            if let liveMatch, liveMatch.isEnabled {
                let liveShortcut = liveMatch.shortcutChar?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let preferredShortcut = trimmedShortcut.isEmpty ? liveShortcut : trimmedShortcut
                let preferredModifiers =
                    shortcutModifiers == 0 ? liveMatch.shortcutModifiers : shortcutModifiers

                let sentByShortcut =
                    !preferredShortcut.isEmpty
                    && AXMenuReader.shared.executeShortcut(
                        char: preferredShortcut,
                        modifiers: preferredModifiers,
                        in: pid
                    )

                let sentByMenu =
                    !sentByShortcut
                    && AXMenuReader.shared.clickMenuItem(path: liveMatch.path, in: pid)

                if sentByShortcut || sentByMenu {
                    if attempt > 0 {
                        return true
                    }
                    await MainActor.run {
                        AppToast.show(
                            "Unlock Passwords to continue",
                            icon: "lock.open",
                            tint: .secondary
                        )
                    }
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    continue
                }
            }

            if attempt == 0 {
                await MainActor.run {
                    AppToast.show(
                        "Unlock Passwords to continue",
                        icon: "lock.open",
                        tint: .secondary
                    )
                }
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        await MainActor.run {
            AppToast.show(
                "Passwords action timed out",
                icon: "exclamationmark.triangle",
                tint: .orange.opacity(0.9)
            )
        }
        return true
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
        return (normalized == "quit" || normalized.hasPrefix("quit "))
            && !normalized.contains("keep")
    }

    private static func isPasteMenuPath(_ path: [String]) -> Bool {
        normalizedMenuText(path.last ?? "") == "paste"
    }

    private static func isPasswordsApp(_ app: NSRunningApplication) -> Bool {
        let bundle = app.bundleIdentifier?.lowercased() ?? ""
        let name = app.localizedName?.lowercased() ?? ""
        return bundle.contains("password") || name == "passwords"
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

    /// Minimized windows are often missing from kAXWindows, so the AX
    /// unminimize pass can silently no-op. When the app ends up frontmost with
    /// no on-screen window, send a Dock-style reopen — macOS then restores the
    /// last minimized window, exactly like clicking the Dock icon.
    nonisolated static func restoreWindowIfAllMinimized(_ app: NSRunningApplication) async {
        let pid = app.processIdentifier
        let hasVisibleWindow: Bool = {
            guard
                let info = CGWindowListCopyWindowInfo(
                    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
                ) as? [[String: Any]]
            else { return true }
            return info.contains { entry in
                (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                    && (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
            }
        }()
        guard !hasVisibleWindow, let bundleURL = app.bundleURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try? await NSWorkspace.shared.openApplication(
            at: bundleURL, configuration: configuration)
        try? await Task.sleep(nanoseconds: 250_000_000)
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
