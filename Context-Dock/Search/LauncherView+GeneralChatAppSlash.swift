// LauncherView+GeneralChatAppSlash.swift
// Context-Dock
//
// "/" at the start of the General Chat field filters apps by name, the way Global
// Context filters app icons into its capsule. Picking one puts the app in the
// chat's focus, so the next question is answered about that app.
//
// This replaces guessing the app from the sentence. Name-alias matching read
// "reminder" as no app at all (the alias is "reminders") and read an app name
// mentioned in passing as a target — a typed "/" says which app the user means,
// with no inference in the middle.

import AppKit
import SwiftUI

struct GeneralChatSlashApp: Identifiable, Equatable {
    let name: String
    let bundleId: String
    let icon: NSImage?
    let isRunning: Bool

    var id: String { bundleId.lowercased() }

    static func == (lhs: GeneralChatSlashApp, rhs: GeneralChatSlashApp) -> Bool {
        lhs.id == rhs.id
    }
}

extension LauncherView {





}
