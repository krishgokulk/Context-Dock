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
            rootView: PluginWindowContent(model: model, window: { [weak panel] in panel }))

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
    /// The panel this content sits in, for the controls the hidden traffic lights would
    /// have given it. Looked up, not held: the panel owns the view, not the other way.
    let window: () -> NSPanel?
    /// Above every other window (how it opens), or an ordinary window that other windows
    /// can cover. The pin is what the other floating panels mean by "keep this open".
    @State private var isFloating = true
    @State private var preZoomFrame: NSRect?

    init(model: PluginHostModel, window: @escaping () -> NSPanel?) {
        self.model = model
        self.window = window
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
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

    /// Close, minimise and zoom at the leading edge in macOS's order — the panel hides the
    /// real traffic lights to keep the glass unbroken, the way ScopedListPanel does — then
    /// the plugin's name, then the pin.
    private var header: some View {
        HStack(spacing: 8) {
            control("xmark", size: 9, help: "Close") { window()?.close() }
            control("minus", size: 9, help: "Minimise") { window()?.miniaturize(nil) }
            control("arrow.up.left.and.arrow.down.right", size: 8, help: "Zoom") { toggleZoom() }

            Image(systemName: model.manifest.icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            Text(model.manifest.name)
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)

            Button {
                isFloating.toggle()
                window()?.level = isFloating ? .floating : .normal
            } label: {
                Image(systemName: isFloating ? "pin.fill" : "pin")
                    .font(.system(size: 12))
                    .foregroundStyle(isFloating ? Color.accentColor : .secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isFloating ? "Pinned above other windows" : "Keep above other windows")
        }
    }

    private func control(
        _ symbol: String, size: CGFloat, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .background(Color.primary.opacity(0.10), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Fill the screen and back again; real full screen is not open to a floating panel.
    private func toggleZoom() {
        guard let window = window(), let screen = window.screen ?? NSScreen.main else { return }
        let target = screen.visibleFrame
        if window.frame.equalTo(target) {
            window.setFrame(
                preZoomFrame ?? target.insetBy(dx: 120, dy: 80), display: true, animate: true)
        } else {
            preZoomFrame = window.frame
            window.setFrame(target, display: true, animate: true)
        }
    }
}
