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
        self.isMovableByWindowBackground = true
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

        setupMonitors()
    }

    private final class MonitorBox: @unchecked Sendable {
        var localMouse: Any?
        var globalMouse: Any?
        var mouseUpLocal: Any?
        var mouseUpGlobal: Any?

        func removeAll() {
            if let m = localMouse { NSEvent.removeMonitor(m); localMouse = nil }
            if let m = globalMouse { NSEvent.removeMonitor(m); globalMouse = nil }
            if let m = mouseUpLocal { NSEvent.removeMonitor(m); mouseUpLocal = nil }
            if let m = mouseUpGlobal { NSEvent.removeMonitor(m); mouseUpGlobal = nil }
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

        let onMouseUp: () -> Void = { [weak self] in
            guard let self else { return }
            if self.isOverDock(windowFrame: self.panel.frame) {
                DetachedPetManager.shared.reattachPet(petID: self.petID)
                CornerDockController.shared.activate()
                CornerChatPresentation.shared.showPet(
                    target: CornerChatTarget(name: self.appName, bundleID: self.bundleID)
                )
            }
        }
        monitorBox.mouseUpLocal = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { event in
            onMouseUp()
            return event
        }
        monitorBox.mouseUpGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { _ in
            onMouseUp()
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
        if let dockWindow = CornerDockController.shared.window {
            let dockFrame = dockWindow.frame.insetBy(dx: -30, dy: -30)
            if windowFrame.intersects(dockFrame) || dockFrame.contains(NSEvent.mouseLocation) {
                return true
            }
        }
        if let screen = panel.screen ?? NSScreen.main {
            let dockBottomBand = CGRect(x: screen.visibleFrame.minX, y: screen.frame.minY, width: screen.frame.width, height: 95)
            if windowFrame.intersects(dockBottomBand) {
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
        return CGPoint(x: frame.maxX - 320, y: frame.minY + 120)
    }
}
