// Context-Dock
//
// The detached host. Same renderer, same runtime, window traits — a plugin opened here is the
// one from the dock or the corner at a different width, never a second implementation.

import AppKit
import SwiftUI

@MainActor
final class PluginWindowManager {
    static let shared = PluginWindowManager()

    private var windows: [String: NSPanel] = [:]

    private init() {}

    func open(_ manifest: PluginManifest) {
        if let existing = windows[manifest.id] {
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            return
        }
        let model = PluginHostModel(manifest: manifest, presentation: .window)
        let traits = model.traits
        let panel = GlassFloatingPanel.make(
            size: NSSize(width: traits.width, height: min(traits.maxHeight, 520)),
            minSize: NSSize(width: 320, height: 240))
        panel.title = manifest.name
        panel.contentView = NSHostingView(
            rootView: PluginHostView(model: model)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))

        // Cascade, so opening a second plugin does not land exactly on the first.
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let step = CGFloat(windows.count) * 28
            panel.setFrameTopLeftPoint(
                NSPoint(x: frame.maxX - traits.width - 60 - step, y: frame.maxY - 80 - step))
        }

        let id = manifest.id
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.windows[id] = nil
                // A closed window must stop its plugin ticking; nothing else is watching.
                PluginRuntime.shared.stopTicking(pluginID: id)
            }
        }

        windows[id] = panel
        MinimizedPanelRegistry.shared.watch(
            panel, id: "plugin:\(manifest.id)", symbol: manifest.icon, title: { manifest.name })
        panel.orderFrontRegardless()
    }
}
