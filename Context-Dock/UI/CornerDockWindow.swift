// CornerDockWindow.swift
// Context-Dock
//
// The single floating shell in the bottom-right corner. The clipboard and the Drop Shelf
// keep separate jobs, separate stores, and separate rules — but they share this one
// window, because the Unified Dock Surface rule is one shell with mode-specific content,
// and two floating containers stacked in the same corner is what it forbids.
//
// The window is fixed at the size of the largest thing it will ever hold and never
// resizes; every pill/card morph is a SwiftUI frame change inside it.

import AppKit
import Combine
import SwiftUI

final class CornerDockPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Hosts both pills. Mouse events are answered only where a pill actually is, so the
/// transparent remainder of the shell never swallows a click meant for the app beneath.
final class CornerDockHostView: NSView {
    weak var controller: CornerDockController?
    var interactiveRects: [NSRect] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(DropShelfMetrics.acceptedTypes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard interactiveRects.contains(where: { $0.contains(local) }) else { return nil }
        return super.hitTest(point)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        DropShelfController.shared.dragEntered()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        DropShelfController.shared.dragExitedPill()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        DropShelfController.shared.acceptDrop(sender.draggingPasteboard)
    }
}

@MainActor
final class CornerDockController: NSObject {
    static let shared = CornerDockController()

    private var panel: CornerDockPanel?
    private var hostView: CornerDockHostView?
    private var hoverMonitors: [Any] = []
    private var sinks: Set<AnyCancellable> = []

    private var clipboardModel: ClipboardPanelModel { ClipboardPanelController.shared.model }
    private var shelf: DropShelfPresentation { DropShelfController.shared.presentation }
    let prompt = AppChatPromptModel()

    var window: NSPanel? { panel }

    func activate() {
        ensurePanel()
        refresh()
    }

    // MARK: - Window

    private func ensurePanel() {
        guard panel == nil else { return }
        let p = CornerDockPanel(
            contentRect: NSRect(origin: .zero, size: CornerDockLayout.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        // SwiftUI draws the glass shadow; a native one would square off the cards.
        p.hasShadow = false
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.isMovable = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.acceptsMouseMovedEvents = true
        p.identifier = GlassFloatingPanel.identifier

        let host = CornerDockHostView(
            frame: NSRect(origin: .zero, size: CornerDockLayout.panelSize))
        host.controller = self
        host.autoresizingMask = [.width, .height]
        let hosting = NSHostingView(rootView: CornerDockSurface())
        hosting.frame = host.bounds
        hosting.autoresizingMask = [.width, .height]
        host.addSubview(hosting)
        p.contentView = host

        panel = p
        hostView = host
        position()

        // One shell, two independent surfaces: it follows both and shows itself whenever
        // either has something to say.
        // Leaving for another Space is leaving. Following the user there with a card
        // about the corner they walked away from is an interruption, not a service.
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ClipboardPanelController.shared.model.userLeftTheSpace()
                DropShelfController.shared.presentation.autoHide()
                CornerDockController.shared.prompt.userLeftTheSpace()
            }
        }

        clipboardModel.$phase.sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }.store(in: &sinks)
        shelf.$phase.sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }.store(in: &sinks)
        prompt.$phase.sink { [weak self] phase in
            Task { @MainActor in
                self?.refresh()
                // The prompt is a text field the user asked for by name, so unlike the
                // ambient pills it takes focus the moment it appears.
                if phase.showsInput {
                    self?.armKeyboard()
                } else if phase == .hidden {
                    self?.disarmKeyboard()
                }
            }
        }.store(in: &sinks)
    }

    private func position() {
        guard let panel else { return }
        let screen =
            NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let pad = CornerDockLayout.pad
        let margin: CGFloat = 20
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(
                x: visible.maxX - margin + pad - size.width,
                y: visible.minY + margin - pad))
    }

    // MARK: - Visibility

    func refresh() {
        guard let panel, let hostView else { return }
        let slots = currentSlots()
        hostView.interactiveRects = [slots.shelf, slots.clipboard, slots.prompt]
            .compactMap { $0 }

        let shouldShow = slots.shelf != nil || slots.clipboard != nil || slots.prompt != nil
        if shouldShow {
            if !panel.isVisible {
                position()
                panel.orderFrontRegardless()
            }
            startHoverWatch()
        } else {
            panel.orderOut(nil)
            // The corner keeps answering the pointer while the shelf still holds
            // something, or a stood-down shelf would strand its items.
            if DropShelfController.shared.store.items.isEmpty {
                stopHoverWatch()
            } else {
                startHoverWatch()
            }
        }
    }

    /// Sizes come from each surface's own phase; the placement comes from the shared
    /// layout, so what is drawn and what is hit-tested cannot drift apart.
    private func currentSlots() -> (shelf: CGRect?, clipboard: CGRect?, prompt: CGRect?) {
        CornerDockLayout.slots(
            shelf: shelf.phase.isVisible
                ? DropShelfMetrics.cardSize(for: shelf.phase) : nil,
            clipboard: clipboardModel.phase.isVisible
                ? ClipboardPillMetrics.cardSize(for: clipboardModel.phase) : nil,
            prompt: prompt.phase.isVisible ? promptSize : nil)
    }

    private var promptSize: CGSize {
        AppChatPromptMetrics.size(for: prompt.phase, suggestions: prompt.suggestions.count)
    }

    /// Where a stood-down shelf pill would reappear, so the corner can be reached again.
    private func dormantShelfRect() -> CGRect? {
        guard !DropShelfController.shared.store.items.isEmpty else { return nil }
        return CornerDockLayout.slots(
            shelf: DropShelfMetrics.collapsedSize,
            clipboard: clipboardModel.phase.isVisible
                ? ClipboardPillMetrics.cardSize(for: clipboardModel.phase) : nil,
            prompt: prompt.phase.isVisible ? promptSize : nil
        ).shelf
    }

    // MARK: - Keyboard

    /// The clipboard card was clicked. `.nonactivatingPanel` keeps the ambient pills
    /// harmless and is also exactly what stops this window becoming key, so the style is
    /// dropped for as long as the card holds the keyboard.
    func armKeyboard() {
        guard let panel else { return }
        panel.styleMask = [.borderless]
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func disarmKeyboard() {
        panel?.styleMask = [.borderless, .nonactivatingPanel]
    }

    // MARK: - Hover

    private func startHoverWatch() {
        guard hoverMonitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved],
            handler: { [weak self] _ in self?.evaluateHover() })
        {
            hoverMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved],
            handler: { [weak self] event in
                self?.evaluateHover()
                return event
            })
        {
            hoverMonitors.append(local)
        }
    }

    private func stopHoverWatch() {
        hoverMonitors.forEach { NSEvent.removeMonitor($0) }
        hoverMonitors.removeAll()
    }

    /// Routes the pointer to whichever pill is under it. Only one card is ever open: the
    /// corner is one surface, not two competing ones.
    private func evaluateHover() {
        guard let panel else { return }
        if !panel.isVisible { position() }
        let origin = panel.frame.origin
        let mouse = NSEvent.mouseLocation
        let slack = ClipboardPillMetrics.hoverTolerance

        func contains(_ rect: CGRect?) -> Bool {
            guard let rect else { return false }
            return rect
                .offsetBy(dx: origin.x, dy: origin.y)
                .insetBy(dx: -slack, dy: -slack)
                .contains(mouse)
        }

        let slots = currentSlots()
        let overShelf = contains(slots.shelf) || contains(dormantShelfRect())
        let overClipboard = contains(slots.clipboard)
        let overPrompt = contains(slots.prompt)

        if overPrompt {
            shelf.hoverEnded()
            clipboardModel.hoverEnded()
            prompt.hoverBegan()
        } else if overShelf {
            clipboardModel.hoverEnded()
            shelf.hoverBegan()
        } else if overClipboard {
            shelf.hoverEnded()
            clipboardModel.hoverBegan()
        } else {
            shelf.hoverEnded()
            clipboardModel.hoverEnded()
        }
    }
}

/// Both pills in the one shell: the shelf above, the clipboard in the corner, each
/// dropping out of the stack when it has nothing to show.
struct CornerDockSurface: View {
    @ObservedObject private var clipboardModel = ClipboardPanelController.shared.model
    @ObservedObject private var shelf = DropShelfController.shared.presentation
    @ObservedObject private var shelfStore = DropShelfController.shared.store
    @ObservedObject private var prompt = CornerDockController.shared.prompt

    var body: some View {
        VStack(alignment: .trailing, spacing: CornerDockLayout.gap) {
            if shelf.phase.isVisible {
                DropShelfPill(presentation: shelf, store: shelfStore)
            }
            if clipboardModel.phase.isVisible {
                ClipboardDockPill(model: clipboardModel)
            }
            if prompt.phase.isVisible {
                AppChatPromptPill(model: prompt)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(CornerDockLayout.pad)
        .animation(
            .spring(response: 0.34, dampingFraction: 0.84), value: shelf.phase.isVisible
        )
        .animation(
            .spring(response: 0.34, dampingFraction: 0.84),
            value: clipboardModel.phase.isVisible)
        .animation(
            .spring(response: 0.34, dampingFraction: 0.84), value: prompt.phase)
    }
}
