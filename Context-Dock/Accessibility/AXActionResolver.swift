// AXActionResolver.swift
// Context-Dock
//
// Unified Action Resolver — executes menu actions using the fastest available strategy.
//
// Priority model:
//   1. Keyboard shortcut injection (fastest — bypasses AX menu traversal entirely)
//   2. AX menu click (reliable — walks the live AX tree and clicks the element)
//   3. AppleScript fallback (safe net — works even when AX tree is unavailable)
//
// App activation is now event-driven: instead of sleeping a fixed duration and
// hoping the app is ready, we subscribe to NSWorkspace.didActivateApplicationNotification
// and proceed the instant the OS confirms the app is frontmost.

import AppKit
import ApplicationServices

final class AXActionResolver {
    static let shared = AXActionResolver()
    private init() {}

    // MARK: - Public entry point

    func execute(menuPath: [String], in app: NSRunningApplication, envVars: [String: String] = [:]) {
        let pid      = app.processIdentifier
        let bundleId = app.bundleIdentifier ?? ""

        // Resolve the best strategy before activating the app
        let record = bundleId.isEmpty ? nil :
            AppMenuCapabilityCache.shared.record(path: menuPath, bundleIdentifier: bundleId)

        if let char = record?.shortcutChar, !char.isEmpty,
           let mods = record.map({ $0.shortcutModifiers }) {
            // Strategy 1: keyboard shortcut — no AX tree traversal at all.
            // Falls through to Strategy 2 if the key code is unknown (e.g. special keys like ⌫).
            Task.detached(priority: .userInitiated) {
                _ = app.activate(options: [.activateIgnoringOtherApps])
                await AXActionResolver.waitForActivation(of: app)
                let sent = AXMenuReader.shared.executeShortcut(char: char, modifiers: mods, in: pid)
                guard !sent else { return }

                // Strategy 1 couldn't map the key — fall back to AX click
                let clicked = AXMenuReader.shared.clickMenuItem(path: menuPath, in: pid)
                guard !clicked else { return }
                await AXActionResolver.appleScriptClick(path: menuPath, appName: app.localizedName ?? "")
            }
        } else {
            // Strategy 2 → 3 fallback chain
            Task.detached(priority: .userInitiated) {
                _ = app.activate(options: [.activateIgnoringOtherApps])
                await AXActionResolver.waitForActivation(of: app)

                let clicked = AXMenuReader.shared.clickMenuItem(path: menuPath, in: pid)
                guard !clicked else { return }

                // Strategy 3: AppleScript (handles apps where AX menu elements are inaccessible)
                await AXActionResolver.appleScriptClick(
                    path: menuPath,
                    appName: app.localizedName ?? ""
                )
            }
        }
    }

    // MARK: - Notification-based activation wait (Fix 4)
    // Replaces the old poll loop. Resolves as soon as NSWorkspace confirms the app
    // is frontmost, or after a 500ms timeout if the notification never fires
    // (e.g. app was already active at the moment of the call).

    static func waitForActivation(of app: NSRunningApplication) async {
        guard !app.isActive else { return }

        let targetBundleId = app.bundleIdentifier ?? ""
        guard !targetBundleId.isEmpty else {
            // Unknown bundle — brief fixed wait as a safe fallback
            try? await Task.sleep(nanoseconds: 80_000_000)
            return
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var didResume = false
            var token: NSObjectProtocol?

            let finish: @Sendable () -> Void = {
                guard !didResume else { return }
                didResume = true
                if let t = token {
                    NSWorkspace.shared.notificationCenter.removeObserver(t)
                    token = nil
                }
                cont.resume()
            }

            token = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { note in
                guard
                    let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication,
                    activated.bundleIdentifier == targetBundleId
                else { return }
                finish()
            }

            // 500ms hard timeout — prevents hanging if notification never fires
            Task.detached {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await MainActor.run { finish() }
            }
        }
    }

    // MARK: - AppleScript fallback (Strategy 3)

    private static func appleScriptClick(path: [String], appName: String) async {
        guard path.count >= 2, !appName.isEmpty else { return }

        let safe = { (s: String) in s.replacingOccurrences(of: "\"", with: "\\\"") }
        let safeApp  = safe(appName)
        let topMenu  = "\"\(safe(path[0]))\""
        let subItems = Array(path.dropFirst())

        // Build nested AppleScript menu reference, deepest-last
        // "File > Export > PDF" → click menu item "PDF" of menu item "Export" of menu bar item "File"
        var script: String
        if subItems.count == 1 {
            script = """
            tell application "System Events"
                tell process "\(safeApp)"
                    click menu item "\(safe(subItems[0]))" of menu bar item \(topMenu) of menu bar 1
                end tell
            end tell
            """
        } else {
            // Walk backwards: last item is the target, all others are ancestors
            let target   = "\"\(safe(subItems.last!))\""
            let ancestors = subItems.dropLast()
                .map { "menu item \"\(safe($0))\"" }
                .reversed()
                .joined(separator: " of ")
            script = """
            tell application "System Events"
                tell process "\(safeApp)"
                    click menu item \(target) of \(ancestors) of menu bar item \(topMenu) of menu bar 1
                end tell
            end tell
            """
        }

        await Task.detached(priority: .userInitiated) {
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        }.value
    }
}
