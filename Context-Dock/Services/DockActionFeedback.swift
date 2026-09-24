// DockActionFeedback.swift
// Context-Dock
//
// Thin wrapper over inline dock feedback for dock-triggered actions.
//
// Usage:
//   let id = DockActionFeedback.start("Opening", subject: "Finder", icon: "arrow.up.right.circle.fill")
//   DockActionFeedback.complete(id, label: "Finder opened")
//   DockActionFeedback.fail(id, label: "Couldn't open Finder")

import SwiftUI

extension Notification.Name {
    static let dockInlineFeedbackChanged = Notification.Name("dockInlineFeedbackChanged")
}

final class DockActionFeedback {

    // MARK: - Static API (matches previous call-sites in ContentView)

    @discardableResult
    static func start(
        _ verb: String,
        subject: String = "",
        icon: String = "bolt.fill",
        tint: Color = .white.opacity(0.85),
        bundleID: String? = nil,
        id: String = UUID().uuidString
    ) -> String {
        let message = subject.isEmpty ? verb : "\(verb) \(subject)…"
        post(id: id, title: message, icon: icon, phase: "progress", subject: subject, bundleID: bundleID)
        return id
    }

    static func complete(
        _ id: String,
        label: String? = nil,
        subject: String? = nil,
        bundleID: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        if let label, !label.isEmpty {
            post(
                id: id,
                title: label,
                icon: "checkmark.circle.fill",
                phase: "success",
                subject: subject,
                bundleID: bundleID
            )
            return
        }
        post(
            id: id,
            title: "Done",
            icon: "checkmark.circle.fill",
            phase: "success",
            subject: subject,
            bundleID: bundleID
        )
    }

    static func fail(_ id: String, label: String? = nil) {
        let msg = (label?.isEmpty == false) ? label! : "Action failed"
        post(id: id, title: msg, icon: "exclamationmark.circle.fill", phase: "failure")
    }

    static func showResult(
        _ title: String,
        icon: String,
        success: Bool,
        id: String = UUID().uuidString,
        subject: String? = nil,
        bundleID: String? = nil
    ) {
        post(
            id: id,
            title: title,
            icon: icon,
            phase: success ? "success" : "failure",
            subject: subject,
            bundleID: bundleID
        )
    }

    // MARK: - The two an app surface reports

    /// An app is being opened or brought forward. A launch is watched, not reported: the
    /// line stands while it happens and leaves when the app is there, so what the user gets
    /// is "Opening Messages…" and then their app — never a tick for something they watched
    /// happen. Carries the bundle id, which is what lets the shell take the app's own
    /// colour. `AppActivation` owns the other end; the id it returns is how it lets go.
    @discardableResult
    static func appOpening(
        _ name: String, bundleID: String?, id: String = UUID().uuidString
    ) -> String {
        post(
            id: id, title: "Opening \(name)…", icon: "arrow.up.forward.app",
            phase: "progress", subject: name, bundleID: bundleID)
        return id
    }

    /// An app was asked to quit. "Quit" in the title is what makes the result read red
    /// wherever it lands (`ActionFeedbackTint.isDestructive`), so the wording is part of
    /// the contract rather than a label.
    static func appQuit(
        _ name: String, bundleID: String?, succeeded: Bool = true,
        id: String = UUID().uuidString
    ) {
        showResult(
            succeeded ? "Quit \(name)" : "Couldn't quit \(name)",
            icon: "xmark.circle.fill", success: succeeded, id: id,
            subject: name, bundleID: bundleID)
    }

    static func progress(_ id: String, value: Double) {
        // No-op — AppToast doesn't support progress bars; persistent pill stays visible
    }

    static func playing(_ id: String) {
        // No-op — audio waveform state not needed in glassy pill style
    }

    static func dismiss(_ id: String) {
        NotificationCenter.default.post(
            name: .dockInlineFeedbackChanged,
            object: nil,
            userInfo: ["id": id, "dismiss": true]
        )
    }

    private static func post(
        id: String,
        title: String,
        icon: String,
        phase: String,
        subject: String? = nil,
        bundleID: String? = nil
    ) {
        NotificationCenter.default.post(
            name: .dockInlineFeedbackChanged,
            object: nil,
            userInfo: [
                "id": id,
                "title": title,
                "icon": icon,
                "phase": phase,
                "subject": subject ?? "",
                "bundleID": bundleID ?? ""
            ]
        )
    }
}
