// MultiItemDragSource.swift
// Context-Dock
//
// Dragging more than one file out of a SwiftUI row.
//
// `.onDrag` returns a single `NSItemProvider` and has no multi-item form, so a selection of
// four clips dragged to Finder arrived as one file and the rest were dropped on the floor.
// AppKit has the API SwiftUI does not expose: `beginDraggingSession(with:event:source:)`
// takes an array of `NSDraggingItem`, which is what a real multi-file drag is.
//
// This is an overlay that watches for a drag and gets out of the way otherwise: a press that
// never travels is forwarded as a click, so rows keep their existing behaviour.

import AppKit
import SwiftUI

struct MultiItemDragSource: NSViewRepresentable {
    /// The files this drag carries, resolved when the drag actually starts rather than when
    /// the row was drawn — the selection can change under the pointer.
    var urls: () -> [URL]
    /// A press that never became a drag.
    var onClick: () -> Void
    /// Called as the session begins, so the copy monitor can stand down.
    var onDragBegan: () -> Void = {}

    func makeNSView(context: Context) -> DragHandleView {
        let view = DragHandleView()
        view.urls = urls
        view.onClick = onClick
        view.onDragBegan = onDragBegan
        return view
    }

    func updateNSView(_ view: DragHandleView, context: Context) {
        view.urls = urls
        view.onClick = onClick
        view.onDragBegan = onDragBegan
    }

    final class DragHandleView: NSView, NSDraggingSource {
        var urls: () -> [URL] = { [] }
        var onClick: () -> Void = {}
        var onDragBegan: () -> Void = {}

        private var mouseDownPoint: NSPoint?

        /// Far enough that a click with a shaky hand is still a click.
        private let dragThreshold: CGFloat = 4

        override func mouseDown(with event: NSEvent) {
            mouseDownPoint = event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseDownPoint else { return }
            let travelled = hypot(
                event.locationInWindow.x - start.x, event.locationInWindow.y - start.y)
            guard travelled > dragThreshold else { return }
            mouseDownPoint = nil

            let files = urls()
            guard !files.isEmpty else { return }
            onDragBegan()

            let items: [NSDraggingItem] = files.enumerated().map { index, url in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                // Fanned slightly, so a four-file drag looks like four files.
                let offset = CGFloat(index) * 6
                let frame = NSRect(x: offset, y: -offset, width: 48, height: 48)
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                item.setDraggingFrame(frame, contents: icon)
                return item
            }

            beginDraggingSession(with: items, event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            // Never travelled, so it was a click on the row underneath.
            if mouseDownPoint != nil { onClick() }
            mouseDownPoint = nil
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            // Outside the app a drop is a copy; the shelf and the clipboard never move the
            // original, they hand over a copy of it.
            context == .outsideApplication ? .copy : []
        }
    }
}
