// PreviewRenderer.swift
// Context-Dock
//
// Kind → view. Documents, images and text all go through QLPreviewView, which is the
// same renderer the system panel uses — the difference is that this one is a subview
// we own, so a header, a pin and an assistant can sit around it.

import AppKit
import QuickLookUI
import SwiftUI
import WebKit

struct PreviewRenderer: View {
    let item: PreviewItem
    /// Bumped when a tool changed what is on disk.
    var reloadToken = 0

    var body: some View {
        switch item.kind {
        case .text where PreviewTextEditor.handles(item.url):
            PreviewTextEditor(url: item.url)
        case .document, .image, .text:
            InlineQLPreview(url: item.url)
        case .folder:
            PreviewFolderBrowser(url: item.url, reloadToken: reloadToken)
        case .web:
            PreviewWebView(url: item.url)
        }
    }
}

// MARK: - Web

private struct PreviewWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard view.url != url else { return }
        view.load(URLRequest(url: url))
    }
}
