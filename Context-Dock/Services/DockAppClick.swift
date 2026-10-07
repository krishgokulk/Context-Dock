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
        switch action(
            isRunning: true, isFrontmost: frontmostApp()?.processIdentifier == pid,
            visibleWindows: WindowServerWindows.count(pid: pid, onScreenOnly: true))
        {
        case .minimizeFrontWindow:
            WindowManagementService.shared.minimizeFrontWindow(pid: pid)
        case .bringForward:
            AppActivation.bringForward(bundleID: bundleID, name: name)
        }
    }

    /// How many windows the app has, minimised ones included; nil when it is not running.
    /// Read from the window server, never from the app: asking a busy app over
    /// Accessibility on every hover froze the corner while Terminal streamed output.
    @MainActor
    static func windowCount(bundleID: String) -> Int? {
        guard
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { !$0.isTerminated })
        else { return nil }
        return WindowServerWindows.count(pid: running.processIdentifier, onScreenOnly: false)
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

/// An app's windows as the window server lists them: no message to the app itself, so a busy
/// app cannot stall the caller. Normal-level windows big enough to be a document — not
/// palettes, menus or the tiny helper windows apps keep off-screen.
enum WindowServerWindows {
    static func count(pid: pid_t, onScreenOnly: Bool) -> Int {
        let options: CGWindowListOption = onScreenOnly
            ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return 0 }
        return list.filter { info in
            Self.isDocumentWindow(
                ownerPID: info[kCGWindowOwnerPID as String] as? Int,
                layer: info[kCGWindowLayer as String] as? Int,
                bounds: (info[kCGWindowBounds as String] as? [String: Any]).flatMap {
                    CGRect(dictionaryRepresentation: $0 as CFDictionary)
                },
                pid: pid)
        }.count
    }

    /// Pure: whether one window-list entry counts as one of the app's windows.
    static func isDocumentWindow(ownerPID: Int?, layer: Int?, bounds: CGRect?, pid: pid_t) -> Bool {
        guard ownerPID == Int(pid), layer == 0, let bounds else { return false }
        return bounds.width >= 120 && bounds.height >= 80
    }
}
