// WindowControlTool.swift
// Context-Dock
//
// Minimise, restore, zoom and close a window — the operations every Mac app has and none
// of them own.
//
// Asked to minimise VS Code, the assistant tried Window ▸ Minimize and was told no such
// cached command exists — true: VS Code's cache holds 225 menu items and not one of them
// is in the Window menu, because Electron builds that menu in a way the enumerator did not
// capture. It then tried `System Events … set miniaturized of front window`, which fails on
// Electron with -10006. Both reports were honest and the window stayed where it was, while
// the operation itself is a single accessibility attribute that works on every app tried,
// Electron included.
//
// So window controls stop being menu commands. They are properties of a window, readable
// and settable through the same accessibility layer that already reads windows for
// verification — no menu cache to miss them, no app scripting dictionary to lack them, and
// no adapter needed, because acting on a window the user can already see and drag is not a
// deeper reach into the app than launching it.

import AppKit
import ApplicationServices
import Foundation

@MainActor
enum WindowControlTool {

    enum Command: String, CaseIterable {
        case minimize
        case restore
        case zoom
        case close
    }

    /// Runs the command against the app's front window and reads the result back.
    ///
    /// The read-back is the point. A window operation either happened or did not, and the
    /// attribute that performed it is the same attribute that reports it — so unlike a menu
    /// click there is nothing to infer.
    static func run(_ command: Command, bundleId: String, appName: String) async
        -> (success: Bool, message: String)
    {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleId)
            .first(where: { !$0.isTerminated })
        else {
            return (false, "\(appName) isn't running, so it has no windows to \(command.rawValue).")
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = frontWindow(of: element) else {
            return (false, "\(appName) has no window open right now.")
        }

        switch command {
        case .minimize, .restore:
            let wanted = command == .minimize
            guard AXUIElementSetAttributeValue(
                window, kAXMinimizedAttribute as CFString, wanted as CFTypeRef) == .success
            else {
                return (false, "\(appName)'s window refused to \(command.rawValue).")
            }
            // Read back only once the window has had time to get there. Minimising is
            // animated and the attribute follows the animation, so an immediate read is
            // taken mid-flight and comes back false — which is how a window that visibly
            // minimised was reported as "did not minimize". The honest report needs the
            // read to happen after the operation, not during it.
            let settled = await settles(
                window, attribute: kAXMinimizedAttribute, to: wanted)
            return settled
                ? (true, "Verified: \(appName)'s window is \(wanted ? "minimised" : "restored").")
                : (false, "\(appName)'s window did not \(command.rawValue).")

        case .zoom, .close:
            // Zoom and close live on the window's own buttons rather than an attribute.
            // Pressing the button is what the user would do, and it goes through the app's
            // own handler — so a document with unsaved changes still gets to ask.
            let button = command == .zoom ? kAXZoomButtonAttribute : kAXCloseButtonAttribute
            guard let target = elementAttribute(window, button) else {
                return (false, "\(appName)'s window has no \(command.rawValue) button.")
            }
            guard AXUIElementPerformAction(target, kAXPressAction as CFString) == .success else {
                return (false, "\(appName)'s window refused to \(command.rawValue).")
            }
            return (true, "Pressed \(appName)'s \(command.rawValue) button.")
        }
    }

    /// The window the user means: the focused one, or the first if the app does not say.
    private static func frontWindow(of app: AXUIElement) -> AXUIElement? {
        if let focused = elementAttribute(app, kAXFocusedWindowAttribute) { return focused }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
            == .success,
            let windows = value as? [AXUIElement]
        else { return nil }
        return windows.first
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
            let result = value, CFGetTypeID(result) == AXUIElementGetTypeID()
        else { return nil }
        return (result as! AXUIElement)
    }

    private static func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return value as? Bool
    }

    /// Waits for `attribute` to reach `wanted`, up to roughly a second.
    ///
    /// Polling rather than a fixed sleep: the common case settles in a frame or two and
    /// returns immediately, while a slow app still gets long enough to finish. A fixed wait
    /// would either be a delay on every call or too short for the app that needed it.
    private static func settles(
        _ window: AXUIElement, attribute: String, to wanted: Bool,
        timeout: TimeInterval = 1.2
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if boolAttribute(window, attribute) == wanted { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < deadline
        return boolAttribute(window, attribute) == wanted
    }

}
