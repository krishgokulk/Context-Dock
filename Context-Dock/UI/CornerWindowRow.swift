import AppKit
import SwiftUI

enum CornerWindowRowMetrics {
    static let thumb = CGSize(width: 160, height: 100)
    static let gap: CGFloat = 8
    static let inset: CGFloat = 12
    static let titleHeight: CGFloat = 16
    /// Pure: count in, size out. The row is a corner slot and hit-tested by this number.
    static func size(count: Int) -> CGSize {
        let n = CGFloat(max(1, count))
        return CGSize(
            width: 2 * inset + n * thumb.width + (n - 1) * gap,
            height: 2 * inset + thumb.height + 4 + titleHeight)
    }
}

/// The hovered app's windows, one thumbnail each — the Dock's Exposé, at strip size. A
/// click raises that window; the × that appears on hover closes it; dragging a thumbnail
/// onto the screen puts the window there (edges tile, the top maximises, elsewhere moves).
/// With Screen Recording refused the titles still show, so the row says what is open rather
/// than showing nothing and looking broken.
struct CornerWindowRow: View {
    let bundleID: String
    @ObservedObject var model: AppChatPromptModel
    @ObservedObject private var snapshots = AppWindowSnapshotService.shared
    @State private var hoveredWindowID: CGWindowID?

    private typealias M = CornerWindowRowMetrics

    var body: some View {
        let windows = snapshots.windowSnapshots(for: bundleID)
        let size = M.size(count: windows.count)
        HStack(spacing: M.gap) {
            if windows.isEmpty {
                placeholder
            }
            ForEach(windows) { window in
                thumbnail(window)
            }
        }
        .padding(M.inset)
        .frame(width: size.width, height: size.height)
        .onHover { inside in model.windowRowHovered(inside) }
        .onAppear { snapshots.refreshWindows(bundleID: bundleID) }
        .onChange(of: bundleID) { _, next in snapshots.refreshWindows(bundleID: next) }
    }

    private func thumbnail(_ window: WindowSnapshot) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                if let image = window.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: M.thumb.width, height: M.thumb.height)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Image(systemName: "macwindow")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                        .frame(width: M.thumb.width, height: M.thumb.height)
                }
                // A press that never travels is a click (raise); one that travels is a drag
                // (place). AppKit owns the session because SwiftUI's `onDrag` cannot say
                // where a drag ended, and "where" is the whole point of this one.
                WindowThumbnailDragSource(
                    window: window, bundleID: bundleID,
                    onClick: { raise(window) },
                    onDropped: { point in place(window, at: point) })
                if hoveredWindowID == window.id {
                    Button { close(window) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Color.black.opacity(0.55), in: Circle())
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .padding(5)
                    .help("Close window")
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .frame(width: M.thumb.width, height: M.thumb.height)
            .animation(.easeOut(duration: 0.12), value: hoveredWindowID)
            Text(window.title.isEmpty ? "Untitled" : window.title)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(width: M.thumb.width, height: M.titleHeight)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hoveredWindowID = inside ? window.id : (hoveredWindowID == window.id ? nil : hoveredWindowID)
        }
        .accessibilityLabel(window.title)
        .accessibilityAddTraits(.isButton)
    }

    private var placeholder: some View {
        let loading = snapshots.isCapturingWindows(for: bundleID)
        return VStack(spacing: 6) {
            if loading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: snapshots.isDenied ? "eye.slash" : "macwindow")
                    .font(.system(size: 24)).foregroundStyle(.secondary)
            }
            Text(
                loading
                    ? "Looking…"
                    : (snapshots.isDenied ? "Allow Screen Recording to see windows" : "No windows")
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(width: M.thumb.width, height: M.thumb.height + 4 + M.titleHeight)
    }

    // MARK: Actions

    private func raise(_ window: WindowSnapshot) {
        AXWindowControl.raise(windowID: window.id, bundleID: bundleID)
        model.dismiss()
    }

    private func close(_ window: WindowSnapshot) {
        AXWindowControl.close(windowID: window.id, bundleID: bundleID)
        // The row is a picture of the machine; take another one once the app has acted.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            snapshots.forgetWindows(bundleID: bundleID)
            snapshots.refreshWindows(bundleID: bundleID)
        }
    }

    private func place(_ window: WindowSnapshot, at appKitPoint: NSPoint) {
        // A snap zone under the pointer places it; anywhere else moves the window there.
        if !SnapZoneOverlay.shared.drop(windowID: window.id, bundleID: bundleID) {
            guard let (point, screen) = AXWindowControl.axPointAndScreen(fromAppKit: appKitPoint),
                let current = AXWindowControl.frame(windowID: window.id, bundleID: bundleID)
            else { return }
            let target = WindowPlacement.frame(drop: point, screen: screen, size: current.size)
            AXWindowControl.place(windowID: window.id, bundleID: bundleID, frame: target)
        }
        AXWindowControl.raise(windowID: window.id, bundleID: bundleID)
        model.dismiss()
    }
}

/// An AppKit drag session for one window thumbnail. Carries a private pasteboard type only,
/// so a drop on the desktop creates nothing — Finder makes text clippings out of strings.
struct WindowThumbnailDragSource: NSViewRepresentable {
    let window: WindowSnapshot
    let bundleID: String
    var onClick: () -> Void
    /// The AppKit screen point the pointer was released at.
    var onDropped: (NSPoint) -> Void

    static let pasteboardType = NSPasteboard.PasteboardType("com.krishgokul.contextdock.window")

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.window_ = window
        view.bundleID = bundleID
        view.onClick = onClick
        view.onDropped = onDropped
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.window_ = window
        view.bundleID = bundleID
        view.onClick = onClick
        view.onDropped = onDropped
    }

    final class DragView: NSView, NSDraggingSource {
        var window_: WindowSnapshot?
        var bundleID = ""
        var onClick: () -> Void = {}
        var onDropped: (NSPoint) -> Void = { _ in }
        private var mouseDownPoint: NSPoint?
        private let dragThreshold: CGFloat = 4

        override func mouseDown(with event: NSEvent) {
            mouseDownPoint = event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseDownPoint, let window_ else { return }
            let travelled = hypot(
                event.locationInWindow.x - start.x, event.locationInWindow.y - start.y)
            guard travelled > dragThreshold else { return }
            mouseDownPoint = nil

            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(
                "\(window_.id)", forType: WindowThumbnailDragSource.pasteboardType)
            let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
            let size = CornerWindowRowMetrics.thumb
            item.setDraggingFrame(
                NSRect(origin: .zero, size: size),
                contents: window_.image ?? NSImage(
                    systemSymbolName: "macwindow", accessibilityDescription: nil))
            beginDraggingSession(with: [item], event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            if mouseDownPoint != nil { onClick() }
            mouseDownPoint = nil
        }

        func draggingSession(
            _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            .generic
        }

        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            guard let window_ else { return }
            let frame = AXWindowControl.frame(windowID: window_.id, bundleID: bundleID)
                ?? CGRect(x: 0, y: 0, width: 900, height: 600)
            SnapZoneOverlay.shared.begin(at: screenPoint, windowID: window_.id, windowFrame: frame)
        }

        func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
            SnapZoneOverlay.shared.update(to: screenPoint)
        }

        func draggingSession(
            _ session: NSDraggingSession, endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            // Released back over this thumbnail is a change of mind, not a placement. The
            // panel itself is corner-sized, so its frame is not the test; this view's is.
            if let panel = self.window {
                let own = panel.convertToScreen(convert(bounds, to: nil))
                if own.contains(screenPoint) {
                    SnapZoneOverlay.shared.end()
                    return
                }
            }
            onDropped(screenPoint)
        }
    }
}
