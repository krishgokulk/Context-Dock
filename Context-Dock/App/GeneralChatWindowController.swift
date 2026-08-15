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

    /// The hotkey's entry point: a second press on a window that is already in front puts
    /// it away again.
    ///
    /// `show()` alone could not do this. Pressing the hotkey over a window that was already
    /// frontmost re-activated the app and re-ordered the same window to the front, which
    /// looks like nothing happened at best and like a second window appearing at worst —
    /// so the press that was meant to dismiss it did nothing instead.
    func toggle() {
        if let window, window.isVisible, !window.isMiniaturized, NSApp.isActive, window.isKeyWindow {
            window.orderOut(nil)
            AppDelegate.shared?.restoreAccessoryPolicyIfNoWindowsRemain(closing: window)
            return
        }
        show()
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Pick up whatever the result sheet has said since this window was last shown —
        // one General Chat conversation, two places to read it.
        GeneralChatWindowModel.shared.reloadFromStore()

        if let window {
            // A minimised window ignores makeKeyAndOrderFront, and one left on another
            // Space would drag the user there. Both read as "the hotkey did nothing".
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.collectionBehavior.insert(.moveToActiveSpace)
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
        // AppKit centres the traffic lights in the TITLEBAR, which is 28pt tall, while the
        // SwiftUI chrome row is 52pt — so the lights sat ~12pt above the sidebar toggle,
        // the history arrows and the Chat/Work pill.
        //
        // An empty unified toolbar fixed that by making AppKit measure a taller strip, and
        // cost every control in it: a toolbar spans the titlebar, so clicks that missed an
        // item became window drags. Both panel toggles, the arrows and the Chat/Work pill
        // stopped responding — the window looked frozen along its whole top edge.
        //
        // The lights are positioned directly instead. Nothing is laid over the chrome row,
        // so every control in it keeps its clicks.
        win.titlebarSeparatorStyle = .none
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
        centreTrafficLights(in: win)
    }

    // MARK: - Traffic lights

    /// Centres the window buttons against the 52pt chrome row.
    ///
    /// Re-applied on resize and on becoming key because AppKit lays the buttons out itself
    /// at those moments and would otherwise put them back at titlebar height.
    private func centreTrafficLights(in win: NSWindow) {
        let chromeHeight: CGFloat = 52
        let buttons: [NSButton] = [.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { win.standardWindowButton($0) }
        guard let container = buttons.first?.superview else { return }
        for button in buttons {
            var frame = button.frame
            // The titlebar container is flipped-origin-at-bottom, so centring means
            // measuring down from the top of the chrome row rather than up from zero.
            frame.origin.y = (container.bounds.height - chromeHeight) / 2
                + (chromeHeight - frame.height) / 2
            button.setFrameOrigin(frame.origin)
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard let win = notification.object as? NSWindow else { return }
        centreTrafficLights(in: win)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let win = notification.object as? NSWindow else { return }
        centreTrafficLights(in: win)
    }

    /// True while the window exists on screen. Used to decide whether the app still needs
    /// to be a regular, menu-bar-owning app.
    var isVisible: Bool { window?.isVisible == true }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        // The window is kept, not dropped. Rebuilding it on the next open would rebuild the
        // SwiftUI view with fresh @State — a new thread selection, a cleared transcript,
        // scroll position gone — which reads as "closing the window deleted my chat".
        AppDelegate.shared?.restoreAccessoryPolicyIfNoWindowsRemain(closing: notification.object as? NSWindow)
    }
}
