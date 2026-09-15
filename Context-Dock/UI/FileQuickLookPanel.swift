// FileQuickLookPanel.swift
// Context-Dock
//
// Finder's Space-to-preview, for dock rows that stand for a file.
//
// Now a thin forward to PreviewController, which owns the app's own preview surface.
// The system panel was exactly right until the preview had to carry a pin, an
// Open With menu and the assistant — none of which can be attached to chrome macOS
// owns. Kept as a name rather than deleted so the dock's key monitors, which all
// speak to this type, did not have to change in the same commit as the new surface.

import AppKit

@MainActor
final class FileQuickLookPanel {
    static let shared = FileQuickLookPanel()
    private init() {}

    /// True when the event belongs to the preview surface rather than the dock.
    func ownsEvent(_ event: NSEvent) -> Bool {
        PreviewController.shared.ownsEvent(event)
    }

    var isOpen: Bool { PreviewController.shared.isOpen }

    /// Preview a path, or toggle the panel shut if it's already showing that path.
    /// `siblings` gives the surface's stepper the rest of the list to walk.
    func toggle(path: String, siblings: [String] = []) {
        let target = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let pool = siblings.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        PreviewController.shared.present(url: target, siblings: pool, toggleIfSame: true)
    }

    func close() {
        PreviewController.shared.close()
    }
}
