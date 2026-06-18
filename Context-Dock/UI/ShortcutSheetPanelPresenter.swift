import AppKit
import SwiftUI

private final class ShortcutSheetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onKeyDown: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true {
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
final class ShortcutSheetPanelPresenter {
    static let shared = ShortcutSheetPanelPresenter()

    private var panel: NSPanel?

    private init() {}

    func show<Content: View>(
        rootView: Content,
        initialHeight: CGFloat = 560,
        onKeyDown: @escaping (NSEvent) -> Bool
    ) {
        close()

        let width: CGFloat = 420
        let height = initialHeight
        let panel = ShortcutSheetPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.onKeyDown = onKeyDown
        panel.contentView = NSHostingView(rootView: AnyView(rootView))

        let screenFrame = (NSScreen.main?.visibleFrame) ?? .zero
        let mouse = NSEvent.mouseLocation
        let x = min(max(mouse.x - width / 2, screenFrame.minX + 16), screenFrame.maxX - width - 16)
        let y = min(max(mouse.y - height - 18, screenFrame.minY + 16), screenFrame.maxY - height - 16)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)

        self.panel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    func update<Content: View>(rootView: Content) {
        // Reuse the existing hosting view so @State and keyboard focus survive
        // per-keystroke updates. Creating a new NSHostingView would reset focus.
        if let hostingView = panel?.contentView as? NSHostingView<AnyView> {
            hostingView.rootView = AnyView(rootView)
        } else {
            panel?.contentView = NSHostingView(rootView: AnyView(rootView))
        }
    }

    func resize(width: CGFloat? = nil, height: CGFloat, keepTopEdge: Bool = true) {
        guard let panel else { return }
        let current = panel.frame
        let newWidth = width ?? current.width
        let newX = current.midX - newWidth / 2
        let newY = keepTopEdge ? current.maxY - height : current.minY
        panel.setFrame(
            NSRect(x: newX, y: newY, width: newWidth, height: height),
            display: true,
            animate: true
        )
    }

    func close() {
        (panel as? ShortcutSheetPanel)?.onKeyDown = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
