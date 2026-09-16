// PreviewFileDragSource.swift
// Context-Dock
//
// Dragging a selection out of the preview, all of it.
//
// SwiftUI's .onDrag hands over exactly one NSItemProvider, so a four-file selection
// dragged to the desktop delivered one file and silently dropped the rest — worse than
// not offering the drag, because the user believes the other three arrived.
//
// A real dragging session takes an array of NSDraggingItems, so the rows are backed by
// an AppKit view that starts one. It owns the clicks too: it already has to watch
// mouse-down to tell a click from the start of a drag, and SwiftUI's modifier-tap
// gestures cannot see a command-click reliably enough to drive a selection.

import AppKit
import SwiftUI

struct PreviewFileDragSource: NSViewRepresentable {
    /// What a drag from this row carries: the whole selection when this row is part of
    /// it, this row alone otherwise.
    let urls: [URL]
    let onClick: (NSEvent.ModifierFlags) -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.apply(urls: urls, onClick: onClick, onDoubleClick: onDoubleClick)
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.apply(urls: urls, onClick: onClick, onDoubleClick: onDoubleClick)
    }

    final class DragView: NSView, NSDraggingSource {
        private var urls: [URL] = []
        private var onClick: ((NSEvent.ModifierFlags) -> Void)?
        private var onDoubleClick: (() -> Void)?
        private var mouseDownPoint: NSPoint?
        private var draggingStarted = false

        func apply(
            urls: [URL],
            onClick: @escaping (NSEvent.ModifierFlags) -> Void,
            onDoubleClick: @escaping () -> Void
        ) {
            self.urls = urls
            self.onClick = onClick
            self.onDoubleClick = onDoubleClick
        }

        override func mouseDown(with event: NSEvent) {
            mouseDownPoint = event.locationInWindow
            draggingStarted = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard !draggingStarted, let start = mouseDownPoint, !urls.isEmpty else { return }
            let dx = event.locationInWindow.x - start.x
            let dy = event.locationInWindow.y - start.y
            // A few points of slop, so a click with a shaky hand stays a click.
            guard (dx * dx + dy * dy).squareRoot() > 4 else { return }
            draggingStarted = true
            beginDrag(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            defer {
                mouseDownPoint = nil
                draggingStarted = false
            }
            guard !draggingStarted else { return }
            if event.clickCount >= 2 {
                onDoubleClick?()
            } else {
                onClick?(event.modifierFlags)
            }
        }

        private func beginDrag(with event: NSEvent) {
            let icons = urls.map { NSWorkspace.shared.icon(forFile: $0.path) }
            let items: [NSDraggingItem] = urls.enumerated().map { index, url in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                // Fanned out slightly, the way Finder stacks a multi-file drag, so the
                // count being carried is visible while it is in flight.
                let offset = CGFloat(index) * 4
                let frame = NSRect(
                    x: bounds.midX - 16 + offset, y: bounds.midY - 16 - offset,
                    width: 32, height: 32)
                item.setDraggingFrame(frame, contents: icons[index])
                return item
            }
            beginDraggingSession(with: items, event: event, source: self)
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            // Copy, never move: the preview is a place to look at files, and a drag that
            // quietly removed them from the folder would be a destructive gesture with no
            // confirmation anywhere.
            .copy
        }

        /// Scroll belongs to the list, not to the row under the pointer.
        override func scrollWheel(with event: NSEvent) {
            nextResponder?.scrollWheel(with: event)
        }
    }
}
