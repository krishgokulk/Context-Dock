import SwiftUI
import AppKit
import Combine

// MARK: - Mini Player Controller
// Manages a floating NSPanel that shows when a music/media tool is running.
// The panel stays on top across all Spaces and provides pause/next/stop controls.

@MainActor
class MiniPlayerController: ObservableObject {
    static let shared = MiniPlayerController()

    @Published var playerInfo: PlayerInfo?

    private var overlayPanel: NSPanel?

    struct PlayerInfo {
        let workerID: UUID
        let toolName: String    // e.g. "ymc"
        var isPlaying: Bool = true
        var currentSong: String? = nil
        var intentLabel: String = "Music"
    }

    // MARK: - Show / Hide

    func show(workerID: UUID, toolName: String, intent: L2ToolIntent = .musicPlayer) {
        playerInfo = PlayerInfo(
            workerID: workerID,
            toolName: toolName,
            intentLabel: intent.displayName
        )
        if overlayPanel == nil { buildPanel() }
        positionPanel()
        overlayPanel?.orderFront(nil)
    }

    func hide() {
        playerInfo = nil
        overlayPanel?.orderOut(nil)
    }

    // MARK: - Transport Controls

    func togglePlayPause() {
        guard let info = playerInfo else { return }
        let cmd = info.isPlaying ? "\(info.toolName) pause" : "\(info.toolName) play"
        Task { await TerminalAIBridge.shared.processAICommand(cmd, purpose: info.isPlaying ? "Pause" : "Resume") }
        playerInfo?.isPlaying.toggle()
    }

    func next() {
        guard let info = playerInfo else { return }
        Task { await TerminalAIBridge.shared.processAICommand("\(info.toolName) next", purpose: "Skip to next") }
    }

    func previous() {
        guard let info = playerInfo else { return }
        Task { await TerminalAIBridge.shared.processAICommand("\(info.toolName) prev", purpose: "Previous track") }
    }

    func stop() {
        guard let info = playerInfo else { return }
        // Terminate background worker
        BackgroundWorkerPool.shared.terminate(info.workerID)
        // Send stop command (best-effort)
        Task { await TerminalAIBridge.shared.processAICommand("\(info.toolName) stop", purpose: "Stop playback") }
        hide()
    }

    /// Update the currently playing song title (called when terminal output is parsed).
    func updateCurrentSong(_ song: String) {
        playerInfo?.currentSong = song
    }

    // MARK: - Panel Construction

    private func buildPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 270, height: 72),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false

        let view = NSHostingView(rootView: MiniPlayerView().environmentObject(self))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view

        overlayPanel = panel
    }

    private func positionPanel() {
        guard let screen = NSScreen.main else { return }
        let sFrame = screen.visibleFrame
        // Bottom-right corner, 16px from edges
        let x = sFrame.maxX - 286
        let y = sFrame.minY + 16
        overlayPanel?.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Mini Player SwiftUI View

struct MiniPlayerView: View {
    @EnvironmentObject var controller: MiniPlayerController

    var body: some View {
        HStack(spacing: 12) {
            // Left: icon + info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "music.note")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.green)
                    Text(controller.playerInfo?.toolName ?? "")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.primary)
                }

                if let song = controller.playerInfo?.currentSong {
                    Text(song)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(controller.playerInfo?.isPlaying == true ? "Playing" : "Paused")
                        .font(.system(size: 10))
                        .foregroundColor(controller.playerInfo?.isPlaying == true ? .green : .secondary)
                }
            }

            Spacer()

            // Right: transport controls
            HStack(spacing: 11) {
                ControlButton(icon: "backward.fill", size: 12) { controller.previous() }
                ControlButton(
                    icon: controller.playerInfo?.isPlaying == true ? "pause.fill" : "play.fill",
                    size: 14
                ) { controller.togglePlayPause() }
                ControlButton(icon: "forward.fill", size: 12) { controller.next() }
                ControlButton(icon: "stop.fill", size: 12, color: .red.opacity(0.85)) { controller.stop() }
                ControlButton(icon: "xmark", size: 10, color: .secondary) { controller.hide() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 270, height: 72)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.green.opacity(0.35), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 4)
        }
    }
}

private struct ControlButton: View {
    let icon: String
    var size: CGFloat = 13
    var color: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(color)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
    }
}
