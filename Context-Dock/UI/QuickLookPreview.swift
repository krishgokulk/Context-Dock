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

// MARK: - Quick Look Data Source Wrapper
struct PillContextMenuAction {
    let icon: String
    let title: String
    let destructive: Bool
    let action: () -> Void

    init(icon: String, title: String, destructive: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.destructive = destructive
        self.action = action
    }
}

/// A floating pill-stack context menu that appears at a given position inside a view.
/// Dismiss by tapping outside the pill stack.
struct PillContextMenuPopup: View {
    let items: [PillContextMenuAction]
    let position: CGPoint
    let containerSize: CGSize
    let onDismiss: () -> Void

    private let menuWidth: CGFloat = 210
    private let itemHeight: CGFloat = 40
    private let padding: CGFloat = 6

    private var clampedPosition: CGPoint {
        let menuHeight = CGFloat(items.count) * (itemHeight + 4) + padding * 2
        let x = min(max(position.x, menuWidth / 2 + 8), containerSize.width - menuWidth / 2 - 8)
        let y = min(max(position.y, menuHeight / 2 + 8), containerSize.height - menuHeight / 2 - 8)
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(spacing: 4) {
                ForEach(items.indices, id: \.self) { i in
                    pillItem(items[i])
                }
            }
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.30), radius: 16, x: 0, y: 6)
            .frame(width: menuWidth)
            .position(clampedPosition)
        }
    }

    @ViewBuilder
    private func pillItem(_ item: PillContextMenuAction) -> some View {
        Button {
            item.action()
            onDismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(item.destructive ? Color.red.opacity(0.85) : Color.primary.opacity(0.80))
                    .frame(width: 18)
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(item.destructive ? Color.red.opacity(0.85) : Color.primary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: itemHeight)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                Capsule()
                    .fill(Color.white.opacity(0.07))
                Capsule()
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}
