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

    private var url: URL?

    var isOpen: Bool {
        QLPreviewPanel.sharedPreviewPanelExists()
            && (QLPreviewPanel.shared()?.isVisible ?? false)
    }

    /// Preview a path, or toggle the panel shut if it's already showing that path.
    func toggle(path: String) {
        let target = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: target.path) else { return }

        guard let panel = QLPreviewPanel.shared() else { return }

        if isOpen, url == target {
            panel.orderOut(nil)
            return
        }

        url = target
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        // The dock is a non-activating panel; makeKeyAndOrderFront would steal the
        // field's focus and break the user's typing flow when the preview closes.
        panel.orderFront(nil)
    }

    func close() {
        guard isOpen, let panel = QLPreviewPanel.shared() else { return }
        panel.orderOut(nil)
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        url as (any QLPreviewItem)?
    }
}
