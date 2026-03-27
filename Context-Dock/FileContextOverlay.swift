// FileContextOverlay.swift
// Context-Dock
//
// Non-activating floating pill that appears above the dock when
// the user selects file(s) in Finder — no context switch needed.

import AppKit
import Combine
import SwiftUI

// MARK: - Controller

@MainActor
final class FileContextOverlayController: ObservableObject {
    static let shared = FileContextOverlayController()

    @Published private(set) var selectedFiles: [URL] = []

    private var panel: NSPanel?
    private var dismissTimer: Timer?

    // MARK: - Public API

    func update(files: [URL]) {
        dismissTimer?.invalidate()
        dismissTimer = nil

        if files.isEmpty {
            hide(animated: true)
        } else {
            selectedFiles = files
            if panel == nil { buildPanel() }
            position()
            if panel?.isVisible == false {
                panel?.alphaValue = 0
                panel?.orderFront(nil)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.panel?.animator().alphaValue = 1
                }
            }
        }
    }

    func hide(animated: Bool = true) {
        guard panel?.isVisible == true else { return }
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                panel?.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.panel?.orderOut(nil)
                self?.selectedFiles = []
            })
        } else {
            panel?.orderOut(nil)
            selectedFiles = []
        }
    }

    // MARK: - Actions

    func quickLook() {
        guard let url = selectedFiles.first else { return }
        // Reveal in Finder with selection, then send Space to trigger QL
        NSWorkspace.shared.activateFileViewerSelecting(selectedFiles)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let src = CGEventSource(stateID: .hidSystemState)
            CGEvent(keyboardEventSource: src, virtualKey: 0x31, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 0x31, keyDown: false)?.post(tap: .cghidEventTap)
            _ = url // suppress warning
        }
    }

    func openFiles() {
        selectedFiles.forEach { NSWorkspace.shared.open($0) }
        hide()
    }

    func moveToTrash() {
        let count = selectedFiles.count
        for url in selectedFiles {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        hide()
        let msg = count == 1 ? "Moved to Bin" : "\(count) items moved to Bin"
        AppToast.show(msg, icon: "trash", tint: .red.opacity(0.9))
    }

    func copyPath() {
        let paths = selectedFiles.map { $0.path }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths, forType: .string)
        AppToast.show("Path copied", icon: "link", tint: .white.opacity(0.85))
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    func getInfo() {
        let escaped = selectedFiles.map { "POSIX file \"\($0.path)\"" }.joined(separator: ", ")
        let script = "tell application \"Finder\" to open information window of {\(escaped)}"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
    }

    // MARK: - Panel

    private func buildPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 56),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: FileContextPillView().environmentObject(self))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.panel = panel
    }

    private func position() {
        guard let screen = NSScreen.main, let panel else { return }
        let sf = screen.visibleFrame
        let panelW: CGFloat = 380
        let panelH: CGFloat = 56
        let dockClearance: CGFloat = 72   // dock bar height + gap
        let x = sf.minX + (sf.width - panelW) / 2
        let y = sf.minY + dockClearance + 10
        panel.setFrame(NSRect(x: x, y: y, width: panelW, height: panelH), display: false)
    }
}

// MARK: - Pill View

struct FileContextPillView: View {
    @EnvironmentObject var ctrl: FileContextOverlayController

    private var files: [URL] { ctrl.selectedFiles }
    private var primary: URL? { files.first }

    private var label: String {
        files.count == 1
            ? (primary?.lastPathComponent ?? "")
            : "\(files.count) items"
    }

    var body: some View {
        HStack(spacing: 0) {

            // File icon
            Group {
                if let url = primary {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: "doc")
                        .font(.system(size: 20))
                }
            }
            .padding(.leading, 14)

            // Name
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 8)
                .frame(maxWidth: 120, alignment: .leading)

            // Separator
            pillDivider

            // Actions
            HStack(spacing: 2) {
                pillAction("eye",           "Quick Look") { ctrl.quickLook() }
                pillAction("arrow.up.right.square", "Open") { ctrl.openFiles() }
                pillAction("link",          "Copy Path")  { ctrl.copyPath() }
                pillAction("info.circle",   "Get Info")   { ctrl.getInfo() }
                pillAction("trash",         "Move to Bin", tint: .red.opacity(0.85)) { ctrl.moveToTrash() }
            }
            .padding(.trailing, 10)
        }
        .frame(width: 380, height: 56)
        .background(pillBackground)
        .clipShape(Capsule())
    }

    // MARK: Sub-views

    private var pillBackground: some View {
        ZStack {
            PillBlurView()
            Color.white.opacity(0.05)
            Capsule()
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
    }

    private var pillDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.12))
            .frame(width: 1, height: 28)
            .padding(.horizontal, 10)
    }

    @ViewBuilder
    private func pillAction(
        _ icon: String,
        _ tip: String,
        tint: Color = .white.opacity(0.8),
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tip)
    }
}

// MARK: - Blur background (NSViewRepresentable)

private struct PillBlurView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
