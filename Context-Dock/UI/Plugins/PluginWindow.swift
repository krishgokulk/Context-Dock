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
        panel.contentView = NSHostingView(rootView: PluginWindowContent(model: model))

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

/// The window's own chrome. The panel is transparent so Liquid Glass can show the desktop,
/// which means the material has to come from the content — without it the plugin draws
/// straight onto the wallpaper. `ScopedListPanel` carries the same note for the same reason;
/// this is that lesson, not a new one.
private struct PluginWindowContent: View {
    @ObservedObject var model: PluginHostModel
    @ObservedObject private var settings = AppSettings.shared

    init(model: PluginHostModel) { self.model = model }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: model.manifest.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(model.manifest.name)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
            }
            PluginHostView(model: model)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.10 + 0.45 * settings.glassDarkness)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }
}
