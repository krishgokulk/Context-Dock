import AppKit
import Combine
import Foundation
import PDFKit
import Quartz
import SwiftUI

final class AICapabilityApprovalWindowHost: NSObject, NSWindowDelegate {
    static let shared = AICapabilityApprovalWindowHost()
    static var window: NSWindow?

    static func close() {
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        if AICapabilityApprovalCenter.shared.pending != nil {
            AICapabilityApprovalCenter.shared.deny()
        }
        Self.window = nil
    }
}

final class AIPrivacyApprovalWindowHost: NSObject, NSWindowDelegate {
    static let shared = AIPrivacyApprovalWindowHost()
    static var window: NSWindow?

    static func close() {
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        if AIPrivacyApprovalCenter.shared.pending != nil {
            AIPrivacyApprovalCenter.shared.deny()
        }
        Self.window = nil
    }
}

// MARK: - Command Approval Window Host
/// Manages the standalone NSWindow used for command approval dialogs.
class CommandApprovalWindowHost: NSObject, NSWindowDelegate {
    static let shared = CommandApprovalWindowHost()
    static var window: NSWindow?

    static func close() {
        window?.close()
        window = nil
    }

    // Called when user clicks the red X button — treat as deny
    func windowWillClose(_ notification: Notification) {
        if TerminalAIBridge.shared.pendingApproval != nil {
            TerminalAIBridge.shared.denyCommand()
        }
        CommandApprovalWindowHost.window = nil
    }
}

final class AdapterApprovalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Adapter Approval Window Host
/// Manages the standalone NSPanel used for adapter action approval dialogs.
class AdapterApprovalWindowHost: NSObject, NSWindowDelegate {
    static let shared = AdapterApprovalWindowHost()
    static var window: NSPanel?

    var onClose: (() -> Void)?
    private var suppressDenyOnClose = false

    static func close() {
        shared.suppressDenyOnClose = true
        shared.onClose = nil
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        let shouldDeny = !suppressDenyOnClose
        suppressDenyOnClose = false
        let onClose = onClose
        self.onClose = nil
        AdapterApprovalWindowHost.window = nil
        if shouldDeny {
            onClose?()
        }
    }
}

// MARK: - Quick Look Support
class QuickLookDataSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let urls: [URL]
    /// Called after the panel closes via Space/Escape so the caller can restore the
    /// list selection to the file that was being previewed (otherwise focus falls
    /// back to the first result).
    var onClose: (() -> Void)?

    init(urls: [URL]) {
        self.urls = urls
        super.init()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        return urls[index] as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Space (49) and Escape (53) both close the panel. Handle them here — Space
        // would otherwise be swallowed by Quick Look's own toggle, closing the panel
        // without ever restoring our list selection.
        if event.type == .keyDown, event.keyCode == 49 || event.keyCode == 53 {
            panel.orderOut(nil)
            onClose?()
            return true
        }
        return false
    }
}

// ResultRow moved to ResultRow.swift

// MARK: - Folder Preview View
