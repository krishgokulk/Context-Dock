// PreviewOpenWithButton.swift
// Context-Dock
//
// "Open With", as an AppKit menu.
//
// SwiftUI's Menu draws a Label's icon only for symbol and asset images: an
// Image(nsImage:) built from an app's real icon is silently dropped, whatever
// rendering mode or size it is given. The list read as a column of bare names, which
// is the one thing an app picker must not be — people find Preview or VS Code by its
// icon long before they read the word.
//
// NSMenuItem takes an NSImage directly and has always drawn it, so the menu is built
// there and popped up under the button.

import AppKit
import SwiftUI

struct PreviewOpenWithButton: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Open With", target: context.coordinator,
                              action: #selector(Coordinator.showMenu(_:)))
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.contentTintColor = .secondaryLabelColor
        button.imagePosition = .imageTrailing
        button.image = NSImage(
            systemSymbolName: "chevron.down",
            accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.url = url
    }

    @MainActor
    final class Coordinator: NSObject {
        var url: URL
        init(url: URL) { self.url = url }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()

            // Default app first — LSCopyApplicationURLsForURL is already sorted that way.
            for app in DefaultAppResolver.shared.getAllApps(for: url) {
                let item = NSMenuItem(
                    title: app.name, action: #selector(openWith(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = app.path
                let icon = app.icon ?? NSWorkspace.shared.icon(forFile: app.path.path)
                // A menu does not resize what it is handed; a 512pt app icon would give
                // every row the height of a paragraph.
                let sized = icon.copy() as? NSImage ?? icon
                sized.size = NSSize(width: 16, height: 16)
                item.image = sized
                menu.addItem(item)
            }

            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(actionItem("Reveal in Finder", #selector(reveal)))
            menu.addItem(actionItem("Copy Path", #selector(copyPath)))
            menu.addItem(.separator())
            // Escape hatch: a few formats only render through a Quick Look plugin that
            // the system panel loads out of process and QLPreviewView here does not.
            menu.addItem(actionItem("Open in System Quick Look", #selector(systemQuickLook)))

            let origin = NSPoint(x: 0, y: sender.bounds.height + 4)
            menu.popUp(positioning: nil, at: origin, in: sender)
        }

        private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }

        @objc private func openWith(_ sender: NSMenuItem) {
            guard let appURL = sender.representedObject as? URL else { return }
            NSWorkspace.shared.open(
                [url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        }

        @objc private func reveal() {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        @objc private func copyPath() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }

        @objc private func systemQuickLook() {
            PreviewController.shared.openInSystemQuickLook(url)
        }
    }
}
