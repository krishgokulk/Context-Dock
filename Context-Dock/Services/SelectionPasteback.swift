// SelectionPasteback.swift
// Context-Dock
//
// Synthetic paste-back execution extracted out of DockCore for reuse across Selection surfaces.

import AppKit
import Foundation

@MainActor
public enum SelectionPasteback {
    /// Pastes replacement text into target process by activating the app and posting Command-V.
    @discardableResult
    public static func pasteText(_ text: String, targetPID: pid_t) -> Bool {
        guard !text.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let targetApp = NSWorkspace.shared.runningApplications.first { $0.processIdentifier == targetPID }
            ?? AppDelegate.shared?.previousFrontmostApp
        let pid = targetPID != 0 ? targetPID : (targetApp?.processIdentifier ?? 0)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            if let targetApp, !targetApp.isTerminated {
                targetApp.activate(options: [.activateIgnoringOtherApps])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                postPasteShortcut(to: pid)
            }
        }
        return true
    }

    /// Synthesizes Command-V keypress to target process or HID event tap.
    public static func postPasteShortcut(to pid: pid_t) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let keyCode: CGKeyCode = 9 // Command-V
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        if pid > 0 {
            keyDown?.postToPid(pid)
            keyUp?.postToPid(pid)
        } else {
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }
    }
}
