// FileQuickLookPanel.swift
// Context-Dock
//
// Finder's Space-to-preview, for dock rows that stand for a file.
//
// Distinct from WebQuickLookPanel, which exists because QLPreviewPanel cannot render
// remote URLs. This is the opposite case: local files, where the system panel is
// exactly right and reimplementing it would be worse.

import AppKit
import QuickLookUI

final class FileQuickLookPanel: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = FileQuickLookPanel()
    private override init() { super.init() }

    private var urls: [URL] = []

    /// True when the event belongs to the Quick Look panel, or Quick Look is simply
    /// up. Its own arrow keys walk the preview set; the dock must not also act on them.
    func ownsEvent(_ event: NSEvent) -> Bool {
        if let w = event.window, w is QLPreviewPanel { return true }
        return isOpen
    }

    var isOpen: Bool {
        QLPreviewPanel.sharedPreviewPanelExists()
            && (QLPreviewPanel.shared()?.isVisible ?? false)
    }

    /// Preview a path, or toggle the panel shut if it's already showing that path.
    /// `siblings` lets Quick Look's own arrow keys walk the rest of the list instead
    /// of previewing a single file in isolation.
    func toggle(path: String, siblings: [String] = []) {
        let target = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        guard let panel = QLPreviewPanel.shared() else { return }

        if isOpen, urls.first(where: { $0 == target }) != nil,
           panel.currentPreviewItemIndex == (urls.firstIndex(of: target) ?? -1) {
            panel.orderOut(nil)
            return
        }

        let all = siblings.isEmpty
            ? [target]
            : siblings.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        urls = all.contains(target) ? all : [target]

        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = urls.firstIndex(of: target) ?? 0
        // The dock is a non-activating panel; makeKeyAndOrderFront would steal the
        // field's focus and break the user's typing flow when the preview closes.
        panel.orderFront(nil)
    }

    func close() {
        guard isOpen, let panel = QLPreviewPanel.shared() else { return }
        panel.orderOut(nil)
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as (any QLPreviewItem)
    }
}
