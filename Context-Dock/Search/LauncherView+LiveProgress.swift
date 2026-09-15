// LauncherView+LiveProgress.swift
// Context-Dock
//
// Where the live activity block is drawn while a turn runs.
//
// It used to be a sibling appended after the whole message list. The assistant message is
// added as soon as streaming starts, so the answer rendered above while the activity stayed
// pinned below — and when the turn ended that block was destroyed and a *different* collapsed
// one (`routerTraceView`) was drawn inside the message. Two views, two places, no shared
// identity, which is why the reasoning read as arriving after the result.
//
// Now the steps are handed to the message that is being written, so they appear above the
// answer and collapse in place when it lands. These decide when that is possible: until there
// is an assistant message to hand them to, the trailing block is still the right place,
// because the end of the list is exactly where the answer will appear.

import Foundation

extension LauncherView {

    /// The steps to show for a running turn, or empty when nothing is running.
    static func liveProgressSteps(
        isLoading: Bool, trace: [String], status: String?
    ) -> [String] {
        guard isLoading else { return [] }
        return trace.isEmpty ? [status ?? "Working…"] : trace
    }

    // MARK: - Context Dock chat

    /// The dock has no streaming id, so the message being written is the last one: an
    /// assistant message with something in it. While it is still empty the dock deliberately
    /// renders nothing for it (see the placeholder branch), and the trailing block stands in.
    var dockProgressBelongsToLastMessage: Bool {
        guard l2.isLoading, let last = l2.chatMessages.last, last.role == .assistant else {
            return false
        }
        return !last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var dockLiveProgressSteps: [String] {
        Self.liveProgressSteps(
            isLoading: l2.isLoading, trace: l2.routerTrace, status: l2.loadingStatus)
    }

    /// Steps for one row of the dock transcript — empty for every message except the one
    /// currently being written.
    func dockLiveSteps(for message: AIChatMessage) -> [String] {
        guard dockProgressBelongsToLastMessage, message.id == l2.chatMessages.last?.id else {
            return []
        }
        return dockLiveProgressSteps
    }

    // MARK: - General chat

    var generalLiveProgressSteps: [String] {
        Self.liveProgressSteps(
            isLoading: aiMode.isLoading, trace: aiMode.routerTrace, status: aiMode.loadingStatus)
    }

    func generalLiveSteps(for message: AIChatMessage) -> [String] {
        guard aiMode.isLoading, let streamingId = aiMode.streamingId,
            message.id == streamingId
        else { return [] }
        return generalLiveProgressSteps
    }
}
