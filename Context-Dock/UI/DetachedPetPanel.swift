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
            CornerChatPresentation.shared.showPet(
                target: CornerChatTarget(name: self.appName, bundleID: self.bundleID)
            )
        }
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
    }

    func windowDidMove(_ notification: Notification) {
        let currentOrigin = panel.frame.origin
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
