// DropShelfWindow.swift
// Context-Dock
//
// The Drop Shelf's surface: an invisible strip along the bottom edge that notices a drag,
// and a pill in the bottom-right corner that catches it.
//
// macOS never announces that a drag has started, so the shelf has to be a drop target to
// find out. That makes the strip dangerous by construction — a full-width target sitting
// under everyone else's drops — so it is deliberately toothless: it *declines* every drag
// it sees and only uses the sighting to reveal the pill. The pill is the sole thing that
// accepts a drop. A release over the strip therefore does what it did before the shelf
// existed: the drag springs back to its source, and nothing is stolen.

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum DropShelfMetrics {
    static let collapsedSize = CGSize(width: 200, height: 56)
    static let expandedSize = CGSize(width: 372, height: 404)
    static let shadowPad: CGFloat = 28
    static let screenMargin: CGFloat = 20
    static let hoverTolerance: CGFloat = 6
    /// Shallow on purpose: the strip is the only part of the shelf that overlaps other
    /// apps' drop targets, so it reaches no further up the screen than it must.
    static let edgeStripHeight: CGFloat = 64
    /// Gap left for the clipboard pill sitting below this one in the same corner.
    static let clipboardClearance: CGFloat = 68

    static var panelSize: NSSize {
        NSSize(
            width: expandedSize.width + shadowPad * 2,
            height: expandedSize.height + shadowPad * 2)
    }

    static func cardSize(for phase: DropShelfPhase) -> CGSize {
        phase == .expanded ? expandedSize : collapsedSize
    }

    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, .string]
    }
}

// MARK: - Edge strip

/// Sees drags, accepts none of them.
final class DropShelfEdgeView: NSView {
    weak var controller: DropShelfController?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(DropShelfMetrics.acceptedTypes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Mouse events belong to whatever is underneath; this view is only ever a spotter.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.dragEntered()
        return []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        controller?.dragExitedStrip()
    }
}

// MARK: - Pill

/// Accepts the drop, and is the only part of the shelf that does.
final class DropShelfPillView: NSView {
    weak var controller: DropShelfController?
    /// The card's rect in this view's coordinates. Everything outside it is click-through
    /// so the transparent remainder of the window never swallows anything.
    var interactiveRect: NSRect = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(DropShelfMetrics.acceptedTypes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard interactiveRect.contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.dragEntered()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        controller?.dragExitedPill()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.acceptDrop(sender.draggingPasteboard) ?? false
    }
}

final class DropShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Controller

@MainActor
final class DropShelfController: NSObject {
    static let shared = DropShelfController()

    let store = DropShelfStore.shared
    let presentation = DropShelfPresentation()

    private var edgePanel: NSPanel?
    private var storeSink: AnyCancellable?
    /// The strip and the pill overlap; a drag crossing from one to the other fires an exit
    /// on the first before the enter on the second. Ending the drag on the next runloop
    /// pass lets that hand-off happen without the pill flickering away.
    private var dragEndTask: Task<Void, Never>?

    /// Called once at launch. Until this runs the shelf does not exist and cannot
    /// interfere with anything.
    func activate() {
        ensurePanels()
        presentation.itemCount = store.items.count
        presentation.itemCountChanged()
        storeSink = store.$items.sink { [weak self] items in
            guard let self else { return }
            self.presentation.itemCount = items.count
            self.presentation.itemCountChanged()
        }
    }

    // MARK: Drag lifecycle

    func dragEntered() {
        dragEndTask?.cancel()
        dragEndTask = nil
        presentation.dragEntered()
        ClipboardPanelController.shared.setSuppressed(true)
    }

    func dragExitedStrip() { scheduleDragEnd() }
    func dragExitedPill() { scheduleDragEnd() }

    private func scheduleDragEnd() {
        dragEndTask?.cancel()
        dragEndTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self else { return }
            self.presentation.dragExited()
            ClipboardPanelController.shared.setSuppressed(false)
        }
    }

    func acceptDrop(_ pasteboard: NSPasteboard) -> Bool {
        dragEndTask?.cancel()
        let app = NSWorkspace.shared.frontmostApplication
        let accepted = store.ingest(
            pasteboard: pasteboard,
            source: (name: app?.localizedName ?? "", bundleId: app?.bundleIdentifier ?? ""))
        presentation.itemCount = store.items.count
        presentation.dropCompleted()
        ClipboardPanelController.shared.setSuppressed(false)
        return accepted > 0
    }

    func remove(_ item: DropShelfItem) {
        store.remove(item)
    }

    func reveal(_ item: DropShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([store.url(for: item)])
    }

    // MARK: Windows

    private func ensurePanels() {
        guard edgePanel == nil else { return }
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame

        let edge = NSPanel(
            contentRect: NSRect(
                x: visible.minX, y: visible.minY,
                width: visible.width, height: DropShelfMetrics.edgeStripHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        edge.isOpaque = false
        edge.backgroundColor = .clear
        edge.hasShadow = false
        edge.level = .floating
        edge.hidesOnDeactivate = false
        edge.isFloatingPanel = true
        edge.becomesKeyOnlyIfNeeded = true
        edge.isMovable = false
        edge.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        edge.isReleasedWhenClosed = false
        let edgeView = DropShelfEdgeView(frame: .zero)
        edgeView.controller = self
        edge.contentView = edgeView
        edge.orderFrontRegardless()
        edgePanel = edge

        // The pill itself lives in the shared corner shell, not in a window of its own.
        CornerDockController.shared.activate()
        presentation.onPhaseChange = { _ in
            CornerDockController.shared.refresh()
        }
    }

}
