// DynamicNotchWindow.swift
// Context-Dock
//
// Standalone Dynamic Island notch window positioned flush with the MacBook
// camera notch (or simulated at the top-center on external notchless screens).
// Runs independently of the launcher presentation mode (Center of Display or Bottom Dock).

import AppKit
import Combine
import SwiftUI

final class DynamicNotchPanel: NSPanel {
    /// Can become key when expanded so buttons, scrubber, and text fields receive clicks immediately
    override var canBecomeKey: Bool {
        DynamicNotchState.shared.isExpanded
    }
    override var canBecomeMain: Bool { false }

    /// Critical for notch alignment: allows window to sit flush at screen.frame.maxY
    /// embracing the camera notch, without AppKit clamping it 38pt below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

final class DynamicNotchHostView: NSView {
    weak var controller: DynamicNotchController?
    private var trackingArea: NSTrackingArea?

    /// Essential for notch alignment: pins the coordinate system to the top bezel
    /// so the window frame animates and glides strictly downwards from the notch,
    /// rather than anchoring to the bottom and expanding upwards.
    override var isFlipped: Bool { true }

    /// Essential for non-activating floating utilities: delivers clicks on the very first tap
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .mouseMoved,
            .activeAlways,
            .inVisibleRect
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let screen = ScreenNotchMetrics.screenWithNotch ?? NSScreen.main ?? NSScreen.screens.first
        let notchH = max(ScreenNotchMetrics.notchHeight(on: screen ?? NSScreen.main ?? NSScreen.screens[0]), 32)
        let notchRect = ScreenNotchMetrics.notchRect(on: screen ?? NSScreen.main ?? NSScreen.screens[0])
        let hasNotch = ScreenNotchMetrics.hasHardwareNotch(on: screen ?? NSScreen.main ?? NSScreen.screens[0])

        let isExpanded = DynamicNotchState.shared.isExpanded
        let islandW: CGFloat
        let islandH: CGFloat

        if isExpanded {
            islandW = 384
            islandH = 182
        } else {
            if hasNotch {
                let showWings = MediaPlayerObserver.shared.isPlaying ||
                    DropShelfStore.shared.items.count > 0 ||
                    ApprovalCenter.shared.pending != nil ||
                    CornerActionFeedback.shared.progressTitle != nil ||
                    !AppSettings.shared.notchCompactIslandAtRest
                islandW = showWings ? (notchRect.width + 104) : (notchRect.width + 24)
            } else {
                islandW = 160
            }
            islandH = notchH + 2
        }

        // With isFlipped == true, y = 0 is flush with the top screen bezel.
        let islandBounds = NSRect(
            x: (bounds.width - islandW) / 2 - 4,
            y: -2,
            width: islandW + 8,
            height: islandH + 4
        )
        guard islandBounds.contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func scrollWheel(with event: NSEvent) {
        guard DynamicNotchState.shared.isExpanded else {
            super.scrollWheel(with: event)
            return
        }

        let dx = event.scrollingDeltaX
        if abs(dx) > abs(event.scrollingDeltaY) || event.phase != [] {
            DynamicNotchState.shared.handleTrackpadScroll(dx: dx, phase: event.phase)
            return
        }
        super.scrollWheel(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        controller?.handleMouseEntered()
    }

    override func mouseExited(with event: NSEvent) {
        controller?.handleMouseExited()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        DropShelfController.shared.dragEntered()
        DynamicNotchState.shared.expand(page: 1)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        DropShelfController.shared.dragExitedPill()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let count = DropShelfStore.shared.ingest(
            pasteboard: sender.draggingPasteboard,
            source: (name: "Finder", bundleId: "com.apple.finder")
        )
        if count > 0 {
            DynamicNotchState.shared.expand(page: 1)
            return true
        }
        return false
    }
}

@MainActor
final class DynamicNotchController: NSObject, ObservableObject {
    static let shared = DynamicNotchController()

    static let padH: CGFloat = 24
    static let padBottom: CGFloat = 24

    private var panel: DynamicNotchPanel?
    private var hostView: DynamicNotchHostView?
    private var cancellables: Set<AnyCancellable> = []
    private var mouseMonitors: [Any] = []
    private var hoverExpandWorkItem: DispatchWorkItem?
    private var hoverCollapseWorkItem: DispatchWorkItem?

    private override init() {
        super.init()
    }

    func start() {
        guard panel == nil else { return }
        buildPanel()
        bindObservers()
        installMouseMonitors()
        updatePosition(animated: false)
    }

    private func buildPanel() {
        let screen = ScreenNotchMetrics.screenWithNotch ?? NSScreen.main ?? NSScreen.screens.first
        let screenRect = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        // The window frame is sized to comfortably host both the resting notch and expanded island.
        // It stays stationary against the top display bezel (screen.frame.maxY), eliminating any
        // AppKit window server resizing jerk or bottom-anchored coordinate flipping.
        let windowW: CGFloat = 384 + Self.padH * 2
        let windowH: CGFloat = 182 + Self.padBottom

        let frame = NSRect(
            x: screenRect.midX - windowW / 2,
            y: screenRect.maxY - windowH,
            width: windowW,
            height: windowH
        )

        let p = DynamicNotchPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .mainMenu + 3 // Above main menu bar so it embraces the camera bezel
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.isMovable = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.acceptsMouseMovedEvents = true

        let host = DynamicNotchHostView(frame: NSRect(origin: .zero, size: frame.size))
        host.controller = self
        host.autoresizingMask = [.width, .height]
        host.registerForDraggedTypes(DropShelfMetrics.acceptedTypes)

        let hosting = NSHostingView(
            rootView: DynamicNotchWrapperView(
                prompt: CornerDockController.shared.prompt,
                onExpand: { [weak self] in
                    self?.updatePosition(animated: false)
                }
            )
        )
        hosting.frame = host.bounds
        hosting.autoresizingMask = [.width, .height]
        host.addSubview(hosting)
        p.contentView = host

        self.panel = p
        self.hostView = host

        if AppSettings.shared.notchLiveActivityEnabled {
            p.orderFrontRegardless()
        }
    }

    private func bindObservers() {
        // Observe screen changes
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.updatePosition(animated: false)
            }
            .store(in: &cancellables)

        // Observe AppSettings toggle via UserDefaults notification
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .compactMap { _ in AppSettings.shared.notchLiveActivityEnabled }
            .removeDuplicates()
            .sink { [weak self] enabled in
                if enabled {
                    self?.panel?.orderFrontRegardless()
                    self?.updatePosition(animated: false)
                } else {
                    self?.panel?.orderOut(nil)
                }
            }
            .store(in: &cancellables)

        // Observe approval center
        ApprovalCenter.shared.$pending
            .receive(on: DispatchQueue.main)
            .sink { pending in
                if pending != nil {
                    // Automatically pop page 2 for immediate user glance
                    DynamicNotchState.shared.expand(page: 2)
                }
            }
            .store(in: &cancellables)
    }

    func updatePosition(isExpanded: Bool? = nil, animated: Bool = false) {
        guard let panel, AppSettings.shared.notchLiveActivityEnabled else { return }
        let screen = ScreenNotchMetrics.screenWithNotch ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let windowW: CGFloat = 384 + Self.padH * 2
        let windowH: CGFloat = 182 + Self.padBottom

        let newOrigin = NSPoint(
            x: screen.frame.midX - windowW / 2,
            y: screen.frame.maxY - windowH
        )
        let newFrame = NSRect(origin: newOrigin, size: CGSize(width: windowW, height: windowH))

        if panel.frame != newFrame {
            panel.setFrame(newFrame, display: true)
        }
    }

    // MARK: - Global Mouse Tracking (Reliable inside-the-notch hover)

    private func installMouseMonitors() {
        guard mouseMonitors.isEmpty else { return }

        // Global monitor: receives mouseMoved events across the entire OS (including Menu Bar & camera notch bezel)
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            self?.evaluateMousePosition()
        }) {
            mouseMonitors.append(global)
        }

        // Local monitor: receives mouse events when Context-Dock is the active app
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            self?.evaluateMousePosition()
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func removeMouseMonitors() {
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseMonitors.removeAll()
    }

    /// Evaluates cursor position in global screen coordinates.
    /// Perfectly detects when cursor enters inside the camera notch cutout, touching the top bezel,
    /// or hovering over the expanded island.
    func evaluateMousePosition() {
        guard AppSettings.shared.notchLiveActivityEnabled,
              AppSettings.shared.notchOpenOnHover,
              let panel else { return }

        let mouse = NSEvent.mouseLocation
        let screen = ScreenNotchMetrics.screenWithNotch ?? NSScreen.main ?? NSScreen.screens[0]

        // Ensure cursor is on the display that hosts the Dynamic Notch
        guard screen.frame.contains(mouse) || mouse.y >= screen.frame.maxY - 5 else {
            if DynamicNotchState.shared.isExpanded {
                scheduleCollapse()
            }
            return
        }

        let isExpanded = DynamicNotchState.shared.isExpanded

        if isExpanded {
            // Generous bounding area covering the expanded card and top screen bezel
            let expandedRect = panel.frame.insetBy(dx: -20, dy: -20)
            let fullExpandedArea = CGRect(
                x: expandedRect.minX,
                y: min(expandedRect.minY, screen.frame.maxY - 220),
                width: expandedRect.width,
                height: screen.frame.maxY - expandedRect.minY + 12
            )

            if fullExpandedArea.contains(mouse) {
                hoverCollapseWorkItem?.cancel()
                hoverCollapseWorkItem = nil
            } else {
                scheduleCollapse()
            }
        } else {
            // Collapsed: trigger strictly when cursor touches the camera notch or top bezel
            let notchRect = ScreenNotchMetrics.notchRect(on: screen)
            let hasNotch = ScreenNotchMetrics.hasHardwareNotch(on: screen)
            let notchH = max(ScreenNotchMetrics.notchHeight(on: screen), 32)

            // Strictly bounds to the notch cutout + minimal resting margin (8pt each side)
            let collarW: CGFloat = hasNotch ? (notchRect.width + 16) : 170
            // Height strictly matches the camera notch (+1pt tolerance at the lower edge)
            let collarH: CGFloat = notchH + 1

            // Flush with the top display bezel (screen.frame.maxY)
            let collarRect = CGRect(
                x: screen.frame.midX - collarW / 2,
                y: screen.frame.maxY - collarH,
                width: collarW,
                height: collarH + 3
            )

            if collarRect.contains(mouse) {
                scheduleExpand()
            } else {
                hoverExpandWorkItem?.cancel()
                hoverExpandWorkItem = nil
            }
        }
    }

    func handleMouseEntered() {
        evaluateMousePosition()
    }

    func handleMouseExited() {
        evaluateMousePosition()
    }

    private func scheduleExpand() {
        hoverCollapseWorkItem?.cancel()
        hoverCollapseWorkItem = nil

        guard hoverExpandWorkItem == nil, !DynamicNotchState.shared.isExpanded else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverExpandWorkItem = nil
            let mouse = NSEvent.mouseLocation
            let screen = ScreenNotchMetrics.screenWithNotch ?? NSScreen.main ?? NSScreen.screens[0]
            let notchRect = ScreenNotchMetrics.notchRect(on: screen)
            let hasNotch = ScreenNotchMetrics.hasHardwareNotch(on: screen)
            let notchH = max(ScreenNotchMetrics.notchHeight(on: screen), 32)
            let collarW: CGFloat = hasNotch ? (notchRect.width + 16) : 170
            let collarH: CGFloat = notchH + 1
            let collarRect = CGRect(
                x: screen.frame.midX - collarW / 2,
                y: screen.frame.maxY - collarH,
                width: collarW,
                height: collarH + 3
            )

            if collarRect.contains(mouse) {
                DynamicNotchState.shared.expand()
                if DropShelfStore.shared.items.count > 0 {
                    DynamicNotchState.shared.selectedPage = 1
                } else if ApprovalCenter.shared.pending != nil {
                    DynamicNotchState.shared.selectedPage = 2
                } else if MediaPlayerObserver.shared.isPlaying {
                    DynamicNotchState.shared.selectedPage = 0
                }
            }
        }
        hoverExpandWorkItem = work
        // Dwell of 160ms: user must actually touch and dwell on the notch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    private func scheduleCollapse() {
        hoverExpandWorkItem?.cancel()
        hoverExpandWorkItem = nil

        guard hoverCollapseWorkItem == nil, DynamicNotchState.shared.isExpanded else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverCollapseWorkItem = nil
            let mouse = NSEvent.mouseLocation
            let screen = ScreenNotchMetrics.screenWithNotch ?? NSScreen.main ?? NSScreen.screens[0]
            if let panel = self.panel {
                let expandedRect = panel.frame.insetBy(dx: -20, dy: -20)
                let fullArea = CGRect(
                    x: expandedRect.minX,
                    y: min(expandedRect.minY, screen.frame.maxY - 220),
                    width: expandedRect.width,
                    height: screen.frame.maxY - expandedRect.minY + 12
                )
                if !fullArea.contains(mouse) {
                    // Do not collapse while dragging items onto the drop shelf
                    if !DropShelfController.shared.presentation.phase.isCardShown {
                        DynamicNotchState.shared.collapse()
                    }
                }
            }
        }
        hoverCollapseWorkItem = work
        // Dwell of 350ms: generous grace period so users can move to click controls
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}

/// Host wrapper to position DynamicNotchLiveActivityView flush at top of window with shadow margin
struct DynamicNotchWrapperView: View {
    @ObservedObject var prompt: AppChatPromptModel
    var onExpand: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DynamicNotchLiveActivityView(
                prompt: prompt,
                onExpand: onExpand
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DynamicNotchController.padH)
        .padding(.bottom, DynamicNotchController.padBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
