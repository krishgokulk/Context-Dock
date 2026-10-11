import AppKit
import Combine
import SwiftUI
import Testing
@testable import Context_Dock

// MARK: - The transcript rewrite loop (issue #145)
//
// `LauncherView.body` hands `.onReceive` a FRESH `x.$published.eraseToAnyPublisher()` on every
// evaluation, and a `Published` publisher replays its current value to each new subscriber. A
// handler that writes the transcript when the value is non-nil therefore writes it again every
// time the transcript's own publish re-renders the view — an unbounded loop on the main thread.
//
// Everything here uses its own objects: no process-wide singleton another suite also drives.

@MainActor
private final class LoopTranscript: ObservableObject {
    @Published var messages: [AIChatMessage] = []
}

@MainActor
private final class LoopBridge: ObservableObject {
    @Published var pending: UUID?
}

/// Same shape as `LauncherView`: observes the transcript, subscribes to a bridge's `Published`
/// through a freshly erased publisher, and appends to the transcript from the handler.
private struct LoopProbe: View {
    @ObservedObject var transcript: LoopTranscript
    @ObservedObject var bridge: LoopBridge
    let guarded: Bool

    var body: some View {
        Color.clear
            .frame(width: 20, height: 20)
            .onReceive(bridge.$pending.eraseToAnyPublisher()) { pending in
                guard let pending else { return }
                if guarded {
                    guard !CommandApprovalCard.isShown(id: pending, in: transcript.messages)
                    else { return }
                } else {
                    // The unguarded handler never stops on its own: run for real it livelocks
                    // the main thread inside one SwiftUI update turn (the test host sat at 100 %
                    // CPU for 20 minutes). The cap only lets the reproduction finish.
                    guard transcript.messages.count < 50 else { return }
                }
                transcript.messages.append(
                    CommandApprovalCard.message(
                        id: pending, command: "run ls", purpose: "list", risk: "Low"))
            }
    }
}

@MainActor
struct ChatTranscriptLoopTests {

    /// Hosts the probe in an off-screen window and lets the run loop turn for `seconds`.
    private func appendsAfterPending(guarded: Bool, seconds: TimeInterval = 0.6) async -> Int {
        let transcript = LoopTranscript()
        let bridge = LoopBridge()
        let host = NSHostingView(
            rootView: LoopProbe(transcript: transcript, bridge: bridge, guarded: guarded))
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 40, height: 40),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }

        bridge.pending = UUID()
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            // Stop early when it is plainly runaway; the assertion is only "far more than one".
            if transcript.messages.count > 200 { break }
        }
        return transcript.messages.count
    }

    @Test func anUnguardedHandlerRewritesTheTranscriptInALoop() async {
        let count = await appendsAfterPending(guarded: false)
        // One pending approval must be one card. Unguarded, every append re-renders the view,
        // the fresh publisher replays the pending value, and the handler appends again.
        #expect(count == 50, "expected the replay loop to run to the cap; got \(count) append(s)")
    }

    @Test func aGuardedHandlerWritesTheCardExactlyOnce() async {
        let count = await appendsAfterPending(guarded: true)
        #expect(count == 1)
    }
}
