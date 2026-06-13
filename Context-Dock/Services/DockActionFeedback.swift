// DockActionFeedback.swift
// Context-Dock
//
// Thin wrapper over AppToast — shows feedback for dock-triggered actions
// as a centred floating glassy pill (same style as empty-bin notification).
//
// Usage:
//   let id = DockActionFeedback.start("Opening", subject: "Finder", icon: "arrow.up.right.circle.fill")
//   DockActionFeedback.complete(id, label: "Finder opened")
//   DockActionFeedback.fail(id, label: "Couldn't open Finder")

import SwiftUI

final class DockActionFeedback {

    // MARK: - Static API (matches previous call-sites in ContentView)

    @discardableResult
    static func start(
        _ verb: String,
        subject: String = "",
        icon: String = "bolt.fill",
        tint: Color = .white.opacity(0.85),
        id: String = UUID().uuidString
    ) -> String {
        let message = subject.isEmpty ? verb : "\(verb) \(subject)…"
        AppToast.show(message, icon: icon, tint: tint, persistent: true, centered: true, id: id)
        return id
    }

    static func complete(
        _ id: String,
        label: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        AppToast.hide(id: id)
        if let label, !label.isEmpty {
            AppToast.show(
                label,
                icon: "checkmark.circle.fill",
                tint: .green,
                duration: action == nil ? 2.5 : 7.5,
                centered: true,
                actionTitle: actionTitle,
                action: action
            )
        }
    }

    static func fail(_ id: String, label: String? = nil) {
        AppToast.hide(id: id)
        let msg = (label?.isEmpty == false) ? label! : "Action failed"
        AppToast.show(msg, icon: "exclamationmark.circle.fill", tint: .orange, centered: true)
    }

    static func progress(_ id: String, value: Double) {
        // No-op — AppToast doesn't support progress bars; persistent pill stays visible
    }

    static func playing(_ id: String) {
        // No-op — audio waveform state not needed in glassy pill style
    }

    static func dismiss(_ id: String) {
        AppToast.hide(id: id)
    }
}
