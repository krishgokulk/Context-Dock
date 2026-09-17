// CornerActionFeedback.swift
// Context-Dock
//
// What the corner shows when something it ran has finished.
//
// The dock answers a finished action with an inline result — icon, colour, a line of text,
// gone after a couple of seconds. The corner ran the same actions through the same pipeline
// and answered with nothing: the result went to the dock's own feedback, which the user
// was not looking at, or to a floating pill of its own at the bottom of the screen. This
// is the corner's half of that answer, listening to the same notification the dock
// consumes, so a result reaches whichever surface the user is actually on.
//
// The shape is the clipboard's: a transient icon in the strip's tools region and beside
// the field, and a tint on the shell, all gone after `holdDuration`.

import AppKit
import Combine
import Foundation
import SwiftUI

/// The colour a result carries. The dock's rules, lifted out of `LauncherView` so the
/// corner cannot drift from them: red for anything destructive whatever its phase, the
/// acted-on app's own colour when there is one, else the phase.
enum ActionFeedbackTint {
    static func color(for phase: DockInlineFeedback.Phase) -> Color {
        switch phase {
        case .progress: return .blue
        case .success: return .green
        case .failure: return .orange
        }
    }

    static func isDestructive(_ feedback: DockInlineFeedback) -> Bool {
        let title = feedback.title.lowercased()
        let icon = feedback.icon.lowercased()
        return title.contains("quit")
            || title.contains("delet")
            || title.contains("trash")
            || title.contains("remove")
            || icon.contains("trash")
            || icon.contains("xmark")
    }

    static func color(for feedback: DockInlineFeedback, appColor: Color? = nil) -> Color {
        if isDestructive(feedback) { return .red }
        if let appColor { return appColor }
        return color(for: feedback.phase)
    }
}

@MainActor
final class CornerActionFeedback: ObservableObject {
    static let shared = CornerActionFeedback()

    /// The result on show, if any. Progress stays until its own completion or dismissal;
    /// a finished result leaves after `holdDuration`.
    @Published private(set) var current: DockInlineFeedback?

    /// Long enough to be read, short enough that the strip is not wearing a badge.
    static let holdDuration: TimeInterval = 3

    private var clearTask: Task<Void, Never>?
    private var subscription: AnyCancellable?

    /// The app uses `shared`; a test builds its own so two tests never share a clock.
    init() {
        subscription = NotificationCenter.default.publisher(for: .dockInlineFeedbackChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                MainActor.assumeIsolated { self?.handle(note) }
            }
    }

    /// Exposed for tests; the notification path is the one the app uses.
    func show(_ feedback: DockInlineFeedback, hold: TimeInterval = CornerActionFeedback.holdDuration) {
        clearTask?.cancel()
        current = feedback
        guard feedback.phase != .progress else { return }
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
            guard !Task.isCancelled, let self, self.current?.id == feedback.id else { return }
            self.current = nil
        }
    }

    func dismiss(id: String) {
        guard current?.id == id else { return }
        clearTask?.cancel()
        current = nil
    }

    /// The app the result was about, as an icon, when the result names one.
    func appIcon(for feedback: DockInlineFeedback) -> NSImage? {
        guard let bundleID = feedback.bundleID, !bundleID.isEmpty,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func handle(_ note: Notification) {
        guard let userInfo = note.userInfo, let id = userInfo["id"] as? String else { return }
        if (userInfo["dismiss"] as? Bool) == true {
            dismiss(id: id)
            return
        }
        guard let title = userInfo["title"] as? String,
            let icon = userInfo["icon"] as? String,
            let phaseRaw = userInfo["phase"] as? String,
            let phase = DockInlineFeedback.Phase(rawValue: phaseRaw)
        else { return }
        let subject = userInfo["subject"] as? String
        let bundleID = userInfo["bundleID"] as? String
        show(
            DockInlineFeedback(
                id: id, title: title, icon: icon, phase: phase,
                subject: subject?.isEmpty == false ? subject : nil,
                bundleID: bundleID?.isEmpty == false ? bundleID : nil))
    }
}
