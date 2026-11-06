// ComputerUseSession.swift
// Context-Dock
//
// Phase 3.6: the user can always see that DoraX is operating an app, and can always stop it.
//
// A small floating pill — "DoraX is operating Pages · Stop" — is shown while `ax_act` steps
// are running, and disappears a few seconds after the last one. Stop (the button, or Esc
// pressed anywhere) refuses every further window action for a cooldown, so a model that is
// mid-loop cannot simply carry on with its next step.

import AppKit
import Combine
import SwiftUI

@MainActor
final class ComputerUseSession: ObservableObject {
    static let shared = ComputerUseSession()

    @Published private(set) var appName: String?
    private var bundleID: String?

    /// How long a Stop holds. Long enough to outlast the model's next few tool calls, short
    /// enough that asking again a moment later is not blocked all session.
    static let stopCooldown: TimeInterval = 30
    /// The pill hides this long after the last step.
    static let idleHide: TimeInterval = 6

    private var stoppedAt: Date?
    private var hideTask: Task<Void, Never>?
    private var panel: NSPanel?
    private var escMonitor: Any?

    private init() {}

    var isStopped: Bool {
        guard let stoppedAt else { return false }
        return Date().timeIntervalSince(stoppedAt) < Self.stopCooldown
    }

    /// Call at the start of every window action. Shows the pill and arms Esc.
    func began(appName: String, bundleID: String) {
        self.appName = appName
        self.bundleID = bundleID
        showPanel()
        armEscape()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleHide * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.idleEnd()
        }
    }

    func stop() {
        stoppedAt = Date()
        // A stopped run is not a route worth remembering.
        ComputerUseSkillRecorder.shared.discard(bundleID: bundleID)
        end()
    }

    /// The run went quiet: save it as a skill if it earned one.
    private func idleEnd() {
        if let bundleID { ComputerUseSkillRecorder.shared.finish(bundleID: bundleID) }
        end()
    }

    private func end() {
        hideTask?.cancel()
        hideTask = nil
        appName = nil
        panel?.orderOut(nil)
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }
    }

    // MARK: Esc

    private func armEscape() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }  // Esc
            Task { @MainActor in self?.stop() }
        }
    }

    // MARK: Pill

    private func showPanel() {
        if panel == nil {
            let host = NSHostingView(rootView: ComputerUsePill(session: self))
            host.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
            let p = NSPanel(
                contentRect: host.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            p.contentView = host
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .statusBar
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = p
        }
        if let screen = NSScreen.main, let panel {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(
                NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - panel.frame.height - 12))
        }
        panel?.orderFrontRegardless()
    }
}

private struct ComputerUsePill: View {
    @ObservedObject var session: ComputerUseSession

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.green).frame(width: 8, height: 8)
            Text("DoraX is operating \(session.appName ?? "an app")")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Stop  esc") { session.stop() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(width: 300, height: 40)
        .background(.regularMaterial, in: Capsule())
    }
}
