// PreviewController.swift
// Context-Dock
//
// The one owner of "what is being previewed". Before this, two code paths
// (FileQuickLookPanel and showQuickLookURL) both grabbed QLPreviewPanel.shared()'s
// dataSource and delegate, so whichever ran last won and closing one wiped the
// other's selection-restore. Everything now goes through here.
//
// Two window states, one surface:
//   unpinned — one reused window that follows the dock's selection and closes with it
//   pinned   — detached, keeps its content, survives the dock hiding
// Pinning DETACHES, the same move Quick Note and the scoped list panels already make:
// the live window becomes the pinned one and the next preview opens a fresh window.

import AppKit
import Combine
import Quartz
import SwiftUI

@MainActor
final class PreviewSession: ObservableObject {
    @Published var items: [PreviewItem]
    @Published var index: Int
    @Published var isPinned = false
    /// Nil means "not decided yet" so the default can change without overriding a
    /// user who has already toggled it on this session.
    @Published var showsAI: Bool = false

    weak var window: NSPanel?

    init(items: [PreviewItem], index: Int) {
        self.items = items
        self.index = max(0, min(index, max(items.count - 1, 0)))
    }

    var current: PreviewItem? {
        items.indices.contains(index) ? items[index] : items.first
    }

    func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        index = (index + delta + items.count) % items.count
    }
}

@MainActor
final class PreviewController: ObservableObject {
    static let shared = PreviewController()
    private init() {}

    /// The window that follows the dock. Only ever one.
    private var liveSession: PreviewSession?
    private var liveWindow: NSPanel?
    /// Detached windows. Each owns its own session and content.
    private var pinnedWindows: [NSPanel] = []

    private var onClose: (() -> Void)?
    private var escapeMonitor: Any?

    /// Kept alive only for the "System Quick Look" escape hatch — some formats have
    /// QL plugins that QLPreviewView in-process does not load.
    private var systemBridge: SystemQuickLookBridge?

    var isOpen: Bool { liveWindow?.isVisible ?? false }

    var currentURL: URL? { liveSession?.current?.url }

    /// True when the event belongs to a preview window rather than the dock. Note this
    /// does NOT return true merely because a preview is open: unlike the system panel,
    /// our window is not keyboard-modal, so the dock keeps its arrow keys and the
    /// preview follows the selection.
    func ownsEvent(_ event: NSEvent) -> Bool {
        guard let window = event.window else { return false }
        if window === liveWindow { return true }
        return pinnedWindows.contains { $0 === window }
    }

    // MARK: - Presenting

    @discardableResult
    func present(
        items: [PreviewItem],
        focus: Int = 0,
        toggleIfSame: Bool = false,
        onClose: (() -> Void)? = nil
    ) -> Bool {
        guard !items.isEmpty else { return false }
        let target = items[max(0, min(focus, items.count - 1))]

        if toggleIfSame, isOpen, liveSession?.current?.url == target.url {
            close()
            return true
        }

        self.onClose = onClose

        if let session = liveSession, let window = liveWindow, window.isVisible {
            // Reuse: swapping the model, not the window, is what makes arrowing through
            // a list feel continuous instead of flashing a new window per row.
            session.items = items
            session.index = max(0, min(focus, items.count - 1))
            window.orderFrontRegardless()
            return true
        }

        let session = PreviewSession(items: items, index: focus)
        let window = makeWindow(for: session)
        session.window = window
        liveSession = session
        liveWindow = window
        installEscapeMonitor()
        window.orderFrontRegardless()
        return true
    }

    @discardableResult
    func present(url: URL, siblings: [URL] = [], toggleIfSame: Bool = true,
                 onClose: (() -> Void)? = nil) -> Bool {
        guard let target = PreviewItem.any(url) else { return false }
        let pool = siblings.isEmpty ? [target] : siblings.compactMap { PreviewItem.any($0) }
        let items = pool.contains(target) ? pool : [target]
        let focus = items.firstIndex(of: target) ?? 0
        return present(items: items, focus: focus, toggleIfSame: toggleIfSame, onClose: onClose)
    }

    func close() {
        guard let window = liveWindow else { return }
        window.close()
    }

    /// Called when the dock goes away. A pinned preview is a window the user asked to
    /// keep, so it stays; the live one is part of the dock's session and goes with it.
    func closeUnpinned() {
        close()
    }

    // MARK: - Pinning

    func togglePin(_ session: PreviewSession) {
        session.isPinned.toggle()
        guard session.isPinned else {
            session.window?.close()
            return
        }
        guard session === liveSession, let window = liveWindow else { return }
        // Detach: this window stops following the dock, and the next Space opens a new one.
        pinnedWindows.append(window)
        liveSession = nil
        liveWindow = nil
        removeEscapeMonitor()
        // Cascade the next live window so it doesn't land exactly under the pin.
        window.setFrameOrigin(NSPoint(x: window.frame.origin.x - 24,
                                      y: window.frame.origin.y - 24))
    }

    // MARK: - System Quick Look escape hatch

    func openInSystemQuickLook(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        let bridge = SystemQuickLookBridge(urls: [url])
        systemBridge = bridge
        panel.dataSource = bridge
        panel.delegate = bridge
        panel.reloadData()
        panel.orderFront(nil)
    }

    // MARK: - Window

    private func makeWindow(for session: PreviewSession) -> NSPanel {
        let panel = GlassFloatingPanel.make(
            size: NSSize(width: 940, height: 660),
            minSize: NSSize(width: 460, height: 340)
        )
        // Titled (title bar itself stays hidden) so the SwiftUI header's minimise and
        // zoom buttons have a real window to act on.
        panel.title = session.current?.title ?? "Preview"
        panel.contentView = NSHostingView(rootView: PreviewSurfaceView(session: session))
        // Remembers where the user put it, the way a real preview window should.
        panel.setFrameAutosaveName("contextdock.preview")
        if panel.frame.origin == .zero, let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameTopLeftPoint(
                NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.maxY - 60))
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pinnedWindows.removeAll { $0 === panel }
                if panel === self.liveWindow {
                    self.liveWindow = nil
                    self.liveSession = nil
                    self.removeEscapeMonitor()
                    let callback = self.onClose
                    self.onClose = nil
                    callback?()
                }
            }
        }
        return panel
    }

    /// Escape closes the preview before the dock sees it. Installed only while a live
    /// preview is up, and it never swallows Escape for a pinned window — those are
    /// closed from their own header, like any other panel.
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen, event.keyCode == 53 else { return event }
            self.close()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
}

/// Datasource for the system panel, used only by the escape hatch above.
private final class SystemQuickLookBridge: NSObject, QLPreviewPanelDataSource {
    private let urls: [URL]
    init(urls: [URL]) { self.urls = urls }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }
}
