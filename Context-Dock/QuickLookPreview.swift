//
//  QuickLookPreview.swift
//  ILauncher
//
//  Quick Look preview integration for files
//

import Foundation
import Quartz
import AppKit
import SwiftUI

class QuickLookPreviewManager {
    static let shared = QuickLookPreviewManager()

    private var previewPanel: QLPreviewPanel?
    private var dataSource: QuickLookDataSourceWrapper?

    private init() {}

    /// Show Quick Look preview for a file
    func showPreview(for filePath: String) {
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("⚠️ File does not exist: \(filePath)")
            return
        }

        let url = URL(fileURLWithPath: filePath)

        // Use QLPreviewPanel
        if QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().close()
        }

        // Create data source wrapper
        let wrapper = QuickLookDataSourceWrapper(urls: [url])
        self.dataSource = wrapper

        // Show preview panel
        let panel = QLPreviewPanel.shared()
        panel?.dataSource = wrapper
        panel?.delegate = wrapper
        panel?.makeKeyAndOrderFront(nil)

        // Keep strong reference
        self.previewPanel = panel
    }

    /// Toggle Quick Look preview panel
    func togglePreview() {
        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.close()
        } else {
            // If panel exists but not visible, show it
            QLPreviewPanel.shared()?.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Inline QL Preview (embeds QLPreviewView inside SwiftUI for the live panel)
struct InlineQLPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact)!
        view.previewItem = url as QLPreviewItem
        view.autostarts = true
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem as? URL != url {
            view.previewItem = url as QLPreviewItem
            view.refreshPreviewItem()
        }
    }
}

// MARK: - Quick Look Data Source Wrapper
// Note: This wrapper exists to avoid conflicts with existing QuickLookDataSource in ContentView
class QuickLookDataSourceWrapper: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private let urls: [URL]

    init(urls: [URL]) {
        self.urls = urls
        super.init()
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        return urls[index] as QLPreviewItem
    }

    // MARK: - QLPreviewPanelDelegate

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Handle escape key to close
        if event.type == .keyDown && event.keyCode == 53 { // Escape key
            panel.close()
            return true
        }
        return false
    }
}
