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

class RightClickableQLContainer: NSView {
    var onRightClick: ((CGPoint) -> Void)?
    private var previewView: QLPreviewView?

    func setup(url: URL) {
        previewView?.removeFromSuperview()
        guard let pv = QLPreviewView(frame: bounds, style: .compact) else { return }
        pv.previewItem = url as QLPreviewItem
        pv.autostarts = true
        pv.autoresizingMask = [.width, .height]
        addSubview(pv)
        previewView = pv
    }

    func updateURL(_ url: URL) {
        guard let pv = previewView else { setup(url: url); return }
        if pv.previewItem as? URL != url {
            pv.previewItem = url as QLPreviewItem
            pv.refreshPreviewItem()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        // Convert AppKit origin (bottom-left) → SwiftUI origin (top-left)
        let swiftUIPoint = CGPoint(x: pt.x, y: bounds.height - pt.y)
        onRightClick?(swiftUIPoint)
        // Do NOT call super — this suppresses the native QL context menu
    }
}

struct InlineQLPreview: NSViewRepresentable {
    let url: URL
    var onRightClick: ((CGPoint) -> Void)? = nil

    func makeNSView(context: Context) -> RightClickableQLContainer {
        let container = RightClickableQLContainer()
        container.onRightClick = onRightClick
        container.setup(url: url)
        return container
    }

    func updateNSView(_ container: RightClickableQLContainer, context: Context) {
        container.onRightClick = onRightClick
        container.updateURL(url)
    }
}


