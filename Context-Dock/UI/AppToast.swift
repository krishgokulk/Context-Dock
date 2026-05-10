// AppToast.swift
// Context-Dock
//
// Reusable floating pill notification. Call from anywhere:
//   AppToast.show("File moved to bin", icon: "trash", tint: .red)
//   AppToast.show("Copied!", icon: "link")
//   AppToast.show("AI thinking…", icon: "sparkles", persistent: true, id: "ai")
//   AppToast.hide(id: "ai")

import AppKit
import SwiftUI
import Combine

// MARK: - Toast model

struct ToastItem: Identifiable {
    let id: String
    let icon: String          // SF Symbol name
    let message: String
    let tint: Color
    let persistent: Bool      // if true, won't auto-dismiss
    var isImage: Bool = false  // use NSImage instead of SF Symbol
    var nsImage: NSImage? = nil
    var centered: Bool = false // position at screen centre instead of above dock
}

// MARK: - Manager

@MainActor
final class AppToast: ObservableObject {
    static let shared = AppToast()

    @Published private(set) var toast: ToastItem? = nil

    private var panel: NSPanel?
    private var dismissTimer: Timer?

    // MARK: - Static convenience

    static func show(
        _ message: String,
        icon: String = "bell",
        tint: Color = .white.opacity(0.85),
        duration: TimeInterval = 2.5,
        persistent: Bool = false,
        centered: Bool = false,
        id: String = UUID().uuidString
    ) {
        Task { @MainActor in
            shared.present(ToastItem(
                id: id, icon: icon, message: message,
                tint: tint, persistent: persistent, centered: centered
            ), duration: duration)
        }
    }

    static func hide(id: String? = nil) {
        Task { @MainActor in shared.dismiss(animated: true) }
    }

    // MARK: - Internal

    func present(_ item: ToastItem, duration: TimeInterval = 2.5) {
        dismissTimer?.invalidate()
        toast = item
        if panel == nil { buildPanel() }
        sizePanel(for: item.message)
        position(centered: item.centered)
        if panel?.isVisible == false {
            panel?.alphaValue = 0
            panel?.orderFront(nil)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel?.animator().alphaValue = 1
        }
        guard !item.persistent else { return }
        dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss(animated: true) }
        }
    }

    func dismiss(animated: Bool = true) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard panel?.isVisible == true else { return }
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                panel?.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.panel?.orderOut(nil)
                self?.toast = nil
            })
        } else {
            panel?.orderOut(nil)
            toast = nil
        }
    }

    // MARK: - Panel

    private func buildPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 52),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: ToastPillView().environmentObject(self))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.panel = panel
    }

    private func sizePanel(for message: String) {
        // Approx width: icon(44) + text + padding
        let estimatedTextW = min(CGFloat(message.count) * 7.5 + 80, 340)
        let w = max(180, estimatedTextW)
        panel?.setContentSize(NSSize(width: w, height: 52))
    }

    private func position(centered: Bool = false) {
        guard let screen = NSScreen.main, let panel else { return }
        let sf = screen.visibleFrame
        let pw = panel.frame.width
        let ph = panel.frame.height
        let x = sf.minX + (sf.width - pw) / 2
        let y: CGFloat
        if centered {
            y = sf.minY + (sf.height - ph) / 2
        } else {
            let dockClearance: CGFloat = 144   // above the file pill or dock
            y = sf.minY + dockClearance
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Pill View

struct ToastPillView: View {
    @EnvironmentObject var mgr: AppToast

    var body: some View {
        Group {
            if let t = mgr.toast {
                HStack(spacing: 10) {
                    Image(systemName: t.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(t.tint)
                        .frame(width: 20)

                    Text(t.message)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(toastBackground)
                .clipShape(Capsule())
            }
        }
    }

    private var toastBackground: some View {
        ZStack {
            ToastBlurView()
            Color.white.opacity(0.05)
            Capsule().strokeBorder(.white.opacity(0.13), lineWidth: 1)
        }
    }
}

// MARK: - Blur

private struct ToastBlurView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
