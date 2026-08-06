// GeneralChatWindowController.swift
// Context-Dock
//
// Standalone window for General Chat Mode. Separate from the launcher panel on
// purpose: the launcher is a non-activating floating panel that closes on focus
// loss, while this is an ordinary document-style window the user keeps open.

import AppKit
import SwiftUI

@MainActor
final class GeneralChatWindowController: NSObject, NSWindowDelegate {
    static let shared = GeneralChatWindowController()

    private var window: NSWindow?

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Pick up whatever the result sheet has said since this window was last shown —
        // one General Chat conversation, two places to read it.
        GeneralChatWindowModel.shared.reloadFromStore()

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let initialW: CGFloat = 1100
        let initialH: CGFloat = 720
        // Centre on the screen the cursor is on, not NSScreen.main — on a
        // multi-display setup main can be a side display.
        let activeScreen =
            NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        let screenFrame =
            activeScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(
            x: (screenFrame.midX - initialW / 2).rounded(),
            y: (screenFrame.midY - initialH / 2).rounded(),
            width: initialW,
            height: initialH
        )

        let win = NSWindow(
            contentRect: frame,
            styleMask: [
                .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )
        win.title = "General Chat"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        // Clear + non-opaque so the sidebar's behind-window blur samples the desktop
        // instead of an opaque window backing — that is what makes the sidebar half
        // translucent while the content half stays solid.
        win.backgroundColor = .clear
        win.isOpaque = false
        // The SwiftUI chrome row draws the whole titlebar strip, so AppKit must not
        // paint a separator or its own background over it.
        win.isMovableByWindowBackground = false
        let hosting = NSHostingController(rootView: GeneralChatWindowView())
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        win.contentViewController = hosting
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 720, height: 480)
        win.level = .normal
        win.collectionBehavior = [.fullScreenPrimary]
        win.delegate = self
        win.setFrame(frame, display: false)
        win.makeKeyAndOrderFront(nil)
        window = win
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        window = nil
    }
}
