// AXUIFocusHelper.swift
// Context-Dock
//
// Accessibility element focusing and text entry helper for Computer Use (Task #368 Phase 3).

import ApplicationServices
import AppKit
import Foundation

@MainActor
enum AXUIFocusHelper {

    /// Searches the frontmost window of `pid` for a search field (`kAXSearchFieldSubrole`)
    /// or text field (`kAXTextFieldRole`), focuses it, and optionally sets its text value.
    static func focusSearchOrTextField(
        in pid: pid_t,
        text: String? = nil
    ) -> (success: Bool, elementDescription: String) {
        guard AXIsProcessTrusted() else {
            return (false, "Accessibility permission not granted")
        }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 1.0)

        // Find the active window
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) != .success {
            var windowsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let windows = windowsRef as? [AXUIElement], let first = windows.first {
                windowRef = first
            }
        }

        guard let window = windowRef else {
            return (false, "No active window found")
        }

        guard let targetElement = findSearchOrTextField(in: window as! AXUIElement, maxDepth: 8, visited: 0).element else {
            return (false, "No search or text field found in active window")
        }

        // Focus the element
        let focusErr = AXUIElementSetAttributeValue(targetElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if focusErr != .success {
            _ = AXUIElementPerformAction(targetElement, kAXPressAction as CFString)
        }

        if let text = text, !text.isEmpty {
            let setValErr = AXUIElementSetAttributeValue(targetElement, kAXValueAttribute as CFString, text as CFTypeRef)
            if setValErr != .success {
                let pasteboard = NSPasteboard.general
                let old = pasteboard.string(forType: .string)
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                let src = CGEventSource(stateID: .combinedSessionState)
                if let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true),
                   let up = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false) {
                    down.flags = .maskCommand
                    up.flags = .maskCommand
                    down.postToPid(pid)
                    up.postToPid(pid)
                }
                if let old {
                    Task {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        pasteboard.clearContents()
                        pasteboard.setString(old, forType: .string)
                    }
                }
            }
            return (true, "Focused search field and entered '\(text)'")
        }

        return (true, "Focused search field")
    }

    private static func findSearchOrTextField(
        in element: AXUIElement,
        maxDepth: Int,
        visited: Int
    ) -> (element: AXUIElement?, visitedCount: Int) {
        if maxDepth <= 0 || visited > 150 { return (nil, visited) }

        var roleRef: CFTypeRef?
        var subroleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)

        let role = (roleRef as? String) ?? ""
        let subrole = (subroleRef as? String) ?? ""

        // Prefer search fields first
        if subrole == (kAXSearchFieldSubrole as String) || subrole.lowercased().contains("search") {
            return (element, visited + 1)
        }

        // Children traversal
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return (nil, visited + 1)
        }

        var currentVisited = visited + 1
        var fallbackTextField: AXUIElement?

        for child in children {
            let res = findSearchOrTextField(in: child, maxDepth: maxDepth - 1, visited: currentVisited)
            currentVisited = res.visitedCount
            if let found = res.element {
                return (found, currentVisited)
            }
        }

        if role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String) {
            fallbackTextField = element
        }

        return (fallbackTextField, currentVisited)
    }
}
