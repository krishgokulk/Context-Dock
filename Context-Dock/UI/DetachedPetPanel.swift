// DetachedPetPanel.swift
// Context-Dock
//
// Floating AppKit panel and controller for a detached desktop Pet mascot (#342).
// Non-activating, floating window with translucent SwiftUI content.

import AppKit
import SwiftUI

/// Non-activating floating panel for a desktop Pet companion.
final class DetachedPetPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.level = .floating
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.isMovable = true
        self.isMovableByWindowBackground = false
        self.acceptsMouseMovedEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool {
        // Only become key when typing into the inline input field
        true
    }

    override var canBecomeMain: Bool { false }
}

/// Controller managing a single detached Pet panel on the desktop.
@MainActor
final class DetachedPetController: NSObject, NSWindowDelegate {
    let petID: AppPetID
    let appName: String
    let bundleID: String
    let viewModel: DetachedPetViewModel
    let panel: DetachedPetPanel

    init(
        petID: AppPetID,
        appName: String,
        bundleID: String,
        initialPosition: CGPoint,
        appIcon: NSImage? = nil,
        pinnedBubbles: [AppPetActionBubble] = []
    ) {
        self.petID = petID.normalized
        self.appName = appName
        self.bundleID = bundleID

        let vm = DetachedPetViewModel(
            petID: petID,
            appName: appName,
            bundleID: bundleID,
            appIcon: appIcon,
            pinnedBubbles: pinnedBubbles
        )
        self.viewModel = vm

        let initialSize = NSSize(width: 280, height: 260)
        let rect = NSRect(
            origin: initialPosition == .zero ? Self.defaultScreenPosition() : initialPosition,
            size: initialSize
        )
        let panel = DetachedPetPanel(contentRect: rect)
        self.panel = panel
        super.init()

        panel.delegate = self
        let hostingView = NSHostingView(rootView: DetachedPetView(viewModel: vm))
        panel.contentView = hostingView

        vm.onReattachToDock = { [weak self] in
            guard let self else { return }
            DetachedPetManager.shared.reattachPet(petID: self.petID)
        }

        vm.onJumpToExpandedWindow = { [weak self] in
            guard let self else { return }
            GeneralChatWindowController.shared.show(
                opening: .app(bundleId: self.bundleID),
                title: self.appName
            )
        }

        vm.onJumpToLauncher = { [weak self] in
            guard let self else { return }
            CornerDockController.shared.showAppChatSheet(
                appName: self.appName,
                bundleID: self.bundleID
            )
        }

        vm.onToggleInlineInput = { [weak self] isInput in
            guard let self else { return }
            if isInput {
                self.panel.makeKeyAndOrderFront(nil)
            } else {
                AppDelegate.shared?.previousFrontmostApp?.activate(options: [.activateIgnoringOtherApps])
            }
        }

        vm.onDragPositionChanged = { [weak self] delta in
            guard let self else { return }
            let origin = self.panel.frame.origin
            let newOrigin = CGPoint(x: origin.x + delta.x, y: origin.y + delta.y)
            self.panel.setFrameOrigin(newOrigin)
            self.viewModel.isHoveringDock = self.isOverDock(windowFrame: self.panel.frame)
        }

        vm.onDragEnded = { [weak self] in
            guard let self else { return }
            let overDock = self.isOverDock(windowFrame: self.panel.frame)
            self.viewModel.isHoveringDock = false
            if overDock {
                DetachedPetManager.shared.reattachPet(petID: self.petID)
                CornerDockController.shared.activate()
                CornerChatPresentation.shared.showPet(
                    target: CornerChatTarget(name: self.appName, bundleID: self.bundleID)
                )
            } else {
                self.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: self.panel))
            }
        }

        setupMonitors()
    }

    nonisolated private final class MonitorBox: @unchecked Sendable {
        var localMouse: Any?
        var globalMouse: Any?

        func removeAll() {
            if let m = localMouse { NSEvent.removeMonitor(m); localMouse = nil }
            if let m = globalMouse { NSEvent.removeMonitor(m); globalMouse = nil }
        }
    }
    private let monitorBox = MonitorBox()

    private func setupMonitors() {
        monitorBox.localMouse = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.updatePupilFocus()
            return event
        }
        monitorBox.globalMouse = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.updatePupilFocus()
        }
    }

    private func updatePupilFocus() {
        let mouse = NSEvent.mouseLocation
        let windowFrame = panel.frame
        let mascotCenter = CGPoint(x: windowFrame.midX, y: windowFrame.minY + 60)
        let dx = mouse.x - mascotCenter.x
        let dy = mouse.y - mascotCenter.y
        let dist = hypot(dx, dy)
        let maxOffset: CGFloat = 2.4
        if dist > 1.0 {
            let factor = min(1.0, dist / 80.0)
            let ox = (dx / dist) * maxOffset * factor
            let oy = -(dy / dist) * maxOffset * factor
            viewModel.pupilOffset = CGSize(width: ox, height: oy)
        } else {
            viewModel.pupilOffset = .zero
        }
    }

    private func isOverDock(windowFrame: NSRect) -> Bool {
        let mascotCenter = CGPoint(x: windowFrame.midX, y: windowFrame.minY + 60)
        if let dockWindow = CornerDockController.shared.window, dockWindow.isVisible {
            let dockFrame = dockWindow.frame.insetBy(dx: -20, dy: -20)
            if dockFrame.contains(mascotCenter) || dockFrame.contains(NSEvent.mouseLocation) {
                return true
            }
        }
        if let screen = panel.screen ?? NSScreen.main {
            let dockBottomBand = CGRect(x: screen.visibleFrame.minX, y: screen.frame.minY, width: screen.frame.width, height: 50)
            if dockBottomBand.contains(mascotCenter) || dockBottomBand.contains(NSEvent.mouseLocation) {
                return true
            }
        }
        return false
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func close() {
        removeMonitors()
        panel.orderOut(nil)
    }

    deinit {
        removeMonitors()
    }

    nonisolated private func removeMonitors() {
        monitorBox.removeAll()
    }

    func windowDidMove(_ notification: Notification) {
        let currentOrigin = panel.frame.origin
        viewModel.isHoveringDock = isOverDock(windowFrame: panel.frame)
        var record = DetachedPetStore.record(for: petID) ?? DetachedPetRecord(
            petID: petID,
            appName: appName,
            bundleID: bundleID,
            position: currentOrigin
        )
        record.position = currentOrigin
        record.pinnedBubbles = viewModel.pinnedBubbles
        record.mascotState = viewModel.mascotState
        record.microBarState = viewModel.microBarState
        DetachedPetStore.upsertRecord(record)
    }

    private static func defaultScreenPosition() -> CGPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return CGPoint(x: frame.maxX - 320, y: frame.minY + 140)
    }
}
