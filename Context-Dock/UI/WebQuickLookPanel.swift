// WebQuickLookPanel.swift
// Context-Dock
//
// Quick Look for websites: Space on a link row peeks the live page in a
// floating WKWebView panel — QLPreviewPanel can't render remote URLs.
// Non-activating, so the launcher keeps key focus and Space toggles it
// closed again, exactly like file Quick Look.

import AppKit
import SwiftUI
import WebKit

private final class WebQuickLookNSPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class WebQuickLookPanel: NSObject, NSToolbarDelegate {
    static let shared = WebQuickLookPanel()
    private override init() {}

    private var panel: NSPanel?
    private var webView: WKWebView?
    private(set) var currentURL: URL?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Space semantics: same URL toggles closed; a different URL retargets.
    func toggle(url: URL) {
        if isVisible, currentURL == url {
            close()
            return
        }
        show(url: url)
    }

    func show(url: URL) {
        let panel = ensurePanel()
        currentURL = url
        panel.title = url.host(percentEncoded: false) ?? "Web Preview"
        webView?.load(URLRequest(url: url))
        positionPanel(panel)
        panel.orderFrontRegardless()
        AppDelegate.shared?.launcherWindow?.makeKey()
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        webView?.load(URLRequest(url: URL(string: "about:blank")!))
        currentURL = nil
    }

    // MARK: - Panel construction

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        if webView.responds(to: Selector(("setDrawsBackground:"))) {
            webView.setValue(false, forKey: "drawsBackground")
        }

        let size = NSSize(width: 960, height: 660)
        let newPanel = WebQuickLookNSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        newPanel.title = "Web Preview"
        newPanel.titleVisibility = .hidden
        newPanel.titlebarAppearsTransparent = true
        newPanel.isMovableByWindowBackground = true
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        newPanel.isReleasedWhenClosed = false
        newPanel.hidesOnDeactivate = false
        newPanel.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.18)
        newPanel.isOpaque = false
        newPanel.hasShadow = true
        newPanel.toolbarStyle = .unifiedCompact
        let toolbar = NSToolbar(identifier: "WebQuickLookToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        newPanel.toolbar = toolbar
        let visual = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        visual.material = .hudWindow
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.autoresizingMask = [.width, .height]
        webView.autoresizingMask = [.width, .height]
        webView.frame = visual.bounds
        visual.addSubview(webView)
        newPanel.contentView = visual

        self.panel = newPanel
        self.webView = webView
        return newPanel
    }

    private func positionPanel(_ panel: NSPanel) {
        let screen =
            AppDelegate.shared?.launcherWindow?.screen
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    // MARK: - Toolbar

    private enum ToolbarID {
        static let open = NSToolbarItem.Identifier("WebQuickLookOpen")
        static let share = NSToolbarItem.Identifier("WebQuickLookShare")
        static let spacer = NSToolbarItem.Identifier.flexibleSpace
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, ToolbarID.open, ToolbarID.share]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, ToolbarID.open, ToolbarID.share]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarID.open:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Open in Browser"
            item.paletteLabel = "Open in Browser"
            item.toolTip = "Open in default browser"
            item.image = NSImage(systemSymbolName: "safari", accessibilityDescription: "Open")
            item.target = self
            item.action = #selector(openInDefaultBrowser)
            return item
        case ToolbarID.share:
            let button = NSButton(
                image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")
                    ?? NSImage(),
                target: self,
                action: #selector(showSharePicker(_:))
            )
            button.bezelStyle = .texturedRounded
            button.isBordered = true
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Share"
            item.paletteLabel = "Share"
            item.toolTip = "Share link"
            item.view = button
            return item
        default:
            return nil
        }
    }

    @objc private func openInDefaultBrowser() {
        guard let currentURL else { return }
        NSWorkspace.shared.open(currentURL)
    }

    @objc private func showSharePicker(_ sender: NSButton) {
        guard let currentURL else { return }
        let picker = NSSharingServicePicker(items: [currentURL])
        picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
}
