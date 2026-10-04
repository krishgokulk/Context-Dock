// DropShelfWindow.swift
// Context-Dock
//
// The Drop Shelf's surface: an invisible strip along the bottom edge that notices a drag,
// and the shelf icon at the end of every dock row — in the Dock and in the Corner — that
// catches it. There is no card of its own: the icon is one more item in the shell's row.
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
    static let expandedSize = CGSize(width: 372, height: 404)
    static let shadowPad: CGFloat = 28
    static let screenMargin: CGFloat = 20
    static let hoverTolerance: CGFloat = 6
    /// Shallow on purpose: the strip is the only part of the shelf that overlaps other
    /// apps' drop targets, so it reaches no further up the screen than it must.
    static let edgeStripHeight: CGFloat = 64
    /// The bottom-right region a drag heading for the shelf passes through. Wide enough to
    /// catch that approach, small enough that it is not a full-screen drag interceptor.
    static let cornerSpotterSize = CGSize(width: 460, height: 460)
    /// Gap left for the clipboard pill sitting below this one in the same corner.
    static let clipboardClearance: CGFloat = 68

    static var panelSize: NSSize {
        NSSize(
            width: expandedSize.width + shadowPad * 2,
            height: expandedSize.height + shadowPad * 2)
    }

    /// The card of items, when the shelf is open; nothing otherwise — collapsed, the shelf is
    /// only its icon in the row.
    static func cardSize(for phase: DropShelfPhase) -> CGSize? {
        phase.isCardShown ? expandedSize : nil
    }

    /// What counts as a drag worth showing the shelf for.
    ///
    /// `.string` alone missed most text dragged out of other apps: a Pages or Safari
    /// selection is offered as RTF or HTML and only *also* as plain text, and an app that
    /// promises rich text first never matched, so the shelf stayed hidden for exactly the
    /// drags it exists to catch. Images dragged from a browser are the same story in TIFF
    /// and PNG.
    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        [
            .fileURL, .URL, .string,
            .rtf, .rtfd, .html,
            .tiff, .png,
            .init("public.text"),
            .init("public.utf8-plain-text"),
            .init("public.image"),
        ]
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

// MARK: - Icon drop target

extension DropShelfMetrics {
    /// What the shelf's icon (and open card) take from a SwiftUI drop: files, links and text.
    /// Rich-text and image drags carry a plain-text or file form as well, which is the one
    /// the shelf files.
    static let dropTypes: [UTType] = [.fileURL, .url, .plainText, .utf8PlainText]
}

/// Makes a view the shelf's drop target — the icon in the row and, while it is open, the
/// card. Shared by the Dock and the Corner. The pointer on it with a drag is `isTargeted`:
/// it opens like any drag target, so the drop is seen to land.
struct DropShelfDropTarget: ViewModifier {
    let presentation: DropShelfPresentation
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: DropShelfMetrics.dropTypes, isTargeted: $isTargeted) { providers in
                DropShelfController.shared.acceptDrop(providers: providers, into: presentation)
            }
            .onChange(of: isTargeted) { _, inside in
                if inside {
                    DropShelfController.shared.iconDragEntered(presentation)
                } else {
                    DropShelfController.shared.iconDragExited(presentation)
                }
            }
    }
}

extension View {
    func dropShelfTarget(_ presentation: DropShelfPresentation) -> some View {
        modifier(DropShelfDropTarget(presentation: presentation))
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
    /// The Corner's. The Dock keeps its own (`dockPresentation`); the store is the one shelf.
    let presentation = DropShelfPresentation()
    let dockPresentation = DropShelfPresentation()

    private var edgePanels: [NSPanel] = []
    private var screenSink: AnyCancellable?
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
        dockPresentation.itemCount = store.items.count
        storeSink = store.$items.sink { [weak self] items in
            self?.presentation.itemCount = items.count
            self?.dockPresentation.itemCount = items.count
        }
    }

    // MARK: Drag lifecycle

    func dragEntered() {
        dragEndTask?.cancel()
        dragEndTask = nil
        presentation.dragEntered()
        ClipboardPanelController.shared.setSuppressed(true)
        // The icon is the drop target, and it lives in the shell: bring the shell up for the
        // drag if nothing has it on screen.
        CornerDockController.shared.revealForShelfDrag()
    }

    /// The icon itself is under the drag, or the drag has left it. `presentation` is the
    /// shell's own: the Corner's is the controller's, the Dock keeps one of its own so that
    /// opening the shelf in one shell never opens a card in the other.
    func iconDragEntered(_ presentation: DropShelfPresentation) {
        if presentation === self.presentation {
            dragEndTask?.cancel()
            dragEndTask = nil
        }
        presentation.dragEntered()
        presentation.iconDragEntered()
        ClipboardPanelController.shared.setSuppressed(true)
    }

    func iconDragExited(_ presentation: DropShelfPresentation) {
        presentation.iconDragExited()
        if presentation === self.presentation {
            scheduleDragEnd()
        } else {
            presentation.dragExited()
            ClipboardPanelController.shared.setSuppressed(false)
        }
    }

    /// An item is leaving the shelf by drag. The copy monitor stands down for the duration,
    /// or the file the drag hands over comes straight back as a clip of itself.
    func beginDrag() {
        ClipboardPanelController.shared.setSuppressed(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            ClipboardPanelController.shared.setSuppressed(false)
        }
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
            CornerDockController.shared.shelfDragEnded()
        }
    }

    /// A drop on the icon or the open card. Reads what the providers carry — files and links
    /// first, text only when there is nothing else, as `DropShelfStore.ingest` does for a
    /// pasteboard — and files it. A dragged pin (the strip's own reorder drag) is not a drop.
    func acceptDrop(providers: [NSItemProvider], into target: DropShelfPresentation) -> Bool {
        let carrying = providers.filter {
            $0.canLoadObject(ofClass: NSURL.self) || $0.canLoadObject(ofClass: NSString.self)
        }
        guard !carrying.isEmpty else { return false }
        dragEndTask?.cancel()
        // The drag is over the moment the drop is taken, not when its data has been read: the
        // pointer leaving the icon right after the release must not read as the drag leaving
        // without dropping, which would put an open shelf away before the item arrived.
        target.dropCompleted()
        if target !== presentation { presentation.dropCompleted() }
        ClipboardPanelController.shared.setSuppressed(false)
        let app = NSWorkspace.shared.frontmostApplication
        let source = (name: app?.localizedName ?? "", bundleId: app?.bundleIdentifier ?? "")
        let group = DispatchGroup()
        let collected = DropCollection()
        for provider in carrying {
            if provider.canLoadObject(ofClass: NSURL.self) {
                group.enter()
                _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                    if let url = object as? URL { collected.add(url: url) }
                    group.leave()
                }
            } else {
                group.enter()
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    if let text = object as? String { collected.add(text: text) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let (urls, text) = collected.snapshot()
                self.store.ingest(urls: urls, text: DropShelfDropRule.shelvableText(text), source: source)
                self.presentation.itemCount = self.store.items.count
                self.dockPresentation.itemCount = self.store.items.count
                CornerDockController.shared.shelfDragEnded()
            }
        }
        return true
    }

    func remove(_ item: DropShelfItem) {
        store.remove(item)
    }

    func reveal(_ item: DropShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([store.url(for: item)])
    }

    // MARK: Windows

    /// One spotter per screen, rebuilt when the screens change.
    ///
    /// There used to be exactly one, on `NSScreen.main`, created once at launch. Drag a
    /// file on any other display and nothing was watching, so the shelf never appeared —
    /// and plugging in or unplugging a monitor left the single strip measuring a screen
    /// that had moved or gone.
    private func ensurePanels() {
        guard edgePanels.isEmpty else { return }
        for screen in NSScreen.screens {
            makeEdgePanel(on: screen)
            makeCornerSpotter(on: screen)
        }
        screenSink = NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )
        .sink { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildEdgePanels() }
        }
    }

    private func rebuildEdgePanels() {
        edgePanels.forEach { $0.orderOut(nil) }
        edgePanels.removeAll()
        for screen in NSScreen.screens {
            makeEdgePanel(on: screen)
            makeCornerSpotter(on: screen)
        }
    }

    /// A spotter over the corner the shelf actually appears in.
    ///
    /// The bottom strip only catches a drag that reaches the very edge of the screen. When
    /// something was already in the corner the drag was caught anyway — the corner panel
    /// registers the same types — so the shelf appeared reliably *only* once the clipboard
    /// or a chat had put a pill there. Dragging toward an empty corner found nothing
    /// watching, which is exactly when the user is reaching for the shelf.
    private func makeCornerSpotter(on screen: NSScreen) {
        let visible = screen.visibleFrame
        let size = DropShelfMetrics.cornerSpotterSize
        let panel = NSPanel(
            contentRect: NSRect(
                x: visible.maxX - size.width, y: visible.minY,
                width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        let view = DropShelfEdgeView(frame: .zero)
        view.controller = self
        panel.contentView = view
        panel.orderFrontRegardless()
        edgePanels.append(panel)
    }

    private func makeEdgePanel(on screen: NSScreen) {
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
        edgePanels.append(edge)

        // The pill itself lives in the shared corner shell, not in a window of its own.
        CornerDockController.shared.activate()
        presentation.onPhaseChange = { _ in
            CornerDockController.shared.refresh()
        }
    }

}

/// What a drop's providers have given up so far; filled from their callback queues.
final class DropCollection: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var texts: [String] = []

    func add(url: URL) { lock.withLock { urls.append(url) } }
    func add(text: String) { lock.withLock { texts.append(text) } }
    func snapshot() -> (urls: [URL], texts: [String]) { lock.withLock { (urls, texts) } }
}

enum DropShelfDropRule {
    /// The text a drop leaves on the shelf: everything dropped as text, joined — and nothing
    /// for a dragged pin, whose reorder drag travels as a `dockpin:` string and is not
    /// something the user means to keep.
    static func shelvableText(_ texts: [String]) -> String? {
        let kept = texts.filter { !$0.hasPrefix("dockpin:") }
        return kept.isEmpty ? nil : kept.joined(separator: "\n")
    }
}
