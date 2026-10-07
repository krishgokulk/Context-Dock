// DockAppClick.swift
// Context-Dock
//
// A running app's icon in Global Context is the window manager's handle on it (owner
// 2026-10-07: "running app icon is our windows management"):
//
// - the app in front, with a window up → its front window is minimised;
// - anything else → the app comes forward, its minimised windows with it (`AppActivation`);
// - an app not running → it launches.
//
// And the hover card of window thumbnails is only worth showing when there is more than one
// window to choose between — one window is what the click already brings back.

import AppKit
import ApplicationServices

enum DockAppClickAction: Equatable {
    case minimizeFrontWindow
    case bringForward
}

enum DockAppClick {
    /// Pure: what a click on the icon does.
    static func action(isRunning: Bool, isFrontmost: Bool, visibleWindows: Int) -> DockAppClickAction {
        isRunning && isFrontmost && visibleWindows > 0 ? .minimizeFrontWindow : .bringForward
    }

    /// Pure: whether hovering the icon shows its windows. `nil` is "could not count" — no
    /// Accessibility permission — and keeps the card, as before.
    static func showsWindowPreview(windowCount: Int?) -> Bool {
        guard let windowCount else { return true }
        return windowCount > 1
    }

    /// The click itself.
    @MainActor
    static func click(bundleID: String, name: String) {
        guard
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { !$0.isTerminated }),
            AXIsProcessTrusted()
        else {
            AppActivation.bringForward(bundleID: bundleID, name: name)
            return
        }
        let pid = running.processIdentifier
        let counts = WindowManagementService.shared.standardWindowCounts(pid: pid)
        switch action(
            isRunning: true, isFrontmost: frontmostApp()?.processIdentifier == pid,
            visibleWindows: counts.visible)
        {
        case .minimizeFrontWindow:
            WindowManagementService.shared.minimizeFrontWindow(pid: pid)
        case .bringForward:
            AppActivation.bringForward(bundleID: bundleID, name: name)
        }
    }

    /// How many standard windows the app has, minimised ones included; nil when it is not
    /// running or the windows cannot be read.
    @MainActor
    static func windowCount(bundleID: String) -> Int? {
        guard AXIsProcessTrusted(),
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { !$0.isTerminated })
        else { return nil }
        let counts = WindowManagementService.shared.standardWindowCounts(
            pid: running.processIdentifier)
        return counts.visible + counts.minimized
    }

    /// The app the user is in. The corner panel does not activate DoraX, so this is usually
    /// the workspace's frontmost app; if DoraX did take the front, the app it took it from.
    @MainActor
    private static func frontmostApp() -> NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier == Bundle.main.bundleIdentifier {
            return AppDelegate.shared?.previousFrontmostApp
        }
        return front
    }
}
