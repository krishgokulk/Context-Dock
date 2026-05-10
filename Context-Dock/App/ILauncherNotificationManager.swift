//
//  ILauncherNotificationManager.swift
//  ILauncher
//
//  Unified notification system for ILauncher.
//
//  In-App notifications: stored in memory, shown as a badge on the user icon
//  and listed in the notification panel.
//
//  System notifications (UNUserNotification): fires a macOS system banner so
//  the user can be alerted even when the launcher is hidden.
//
//  Usage:
//    // Post in-app only (tool result, AI completion, etc.)
//    ILauncherNotificationManager.shared.post(
//        title: "Shell finished",
//        body: "npm run build exited 0",
//        icon: "checkmark.circle.fill",
//        accentColor: "green"
//    )
//
//    // Post system banner + in-app
//    ILauncherNotificationManager.shared.postSystem(
//        title: "AI Task Complete",
//        body: "Your research summary is ready.",
//        icon: "sparkles"
//    )
//
//    // Post with an action that runs when the user taps the notification
//    ILauncherNotificationManager.shared.post(
//        title: "File ready",
//        body: "report.pdf has been exported",
//        icon: "doc.fill",
//        action: { NSWorkspace.shared.open(reportURL) }
//    )
//

import Foundation
import AppKit
import UserNotifications
import Combine

// MARK: - ILauncherNotification

struct ILauncherNotification: Identifiable {
    let id: UUID
    let title: String
    let body: String
    let icon: String          // SF Symbol name
    let accentColor: String   // Color name ("green", "red", "blue", "orange", "purple", "gray")
    let date: Date
    var isRead: Bool
    var action: (() -> Void)? // Optional tap action

    init(title: String, body: String, icon: String = "bell.fill",
         accentColor: String = "blue", action: (() -> Void)? = nil) {
        self.id = UUID()
        self.title = title
        self.body = body
        self.icon = icon
        self.accentColor = accentColor
        self.date = Date()
        self.isRead = false
        self.action = action
    }
}

// MARK: - ILauncherNotificationManager

@MainActor
final class ILauncherNotificationManager: ObservableObject {
    static let shared = ILauncherNotificationManager()

    @Published private(set) var notifications: [ILauncherNotification] = []

    var unreadCount: Int { notifications.filter { !$0.isRead }.count }

    private init() {
        requestSystemPermission()
    }

    // MARK: - Posting

    /// Post an in-app notification (badge + panel entry).
    func post(title: String, body: String,
              icon: String = "bell.fill", accentColor: String = "blue",
              action: (() -> Void)? = nil) {
        let n = ILauncherNotification(title: title, body: body,
                                      icon: icon, accentColor: accentColor, action: action)
        notifications.insert(n, at: 0)
        // Cap at 50 entries
        if notifications.count > 50 { notifications = Array(notifications.prefix(50)) }
    }

    /// Post both a system banner and an in-app notification.
    func postSystem(title: String, body: String,
                    icon: String = "bell.fill", accentColor: String = "blue",
                    action: (() -> Void)? = nil) {
        post(title: title, body: body, icon: icon, accentColor: accentColor, action: action)
        if AppSettings.shared.notifySystemBanners {
            fireSystemBanner(title: title, body: body)
        }
    }

    // MARK: - Reading

    func markRead(_ id: UUID) {
        guard let i = notifications.firstIndex(where: { $0.id == id }) else { return }
        notifications[i].isRead = true
    }

    func markAllRead() {
        for i in notifications.indices { notifications[i].isRead = true }
    }

    func remove(_ id: UUID) {
        notifications.removeAll { $0.id == id }
    }

    func clearAll() { notifications.removeAll() }

    // MARK: - Tap

    func tap(_ id: UUID) {
        markRead(id)
        notifications.first(where: { $0.id == id })?.action?()
    }

    // MARK: - System (UNUserNotification)

    private func requestSystemPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func fireSystemBanner(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

// MARK: - Convenience shortcuts for common event types

extension ILauncherNotificationManager {

    /// Notify when a shell command (CLI tool) finishes.
    func shellFinished(command: String, exitCode: Int32) {
        let success = exitCode == 0
        post(title: success ? "Command succeeded" : "Command failed",
             body: command,
             icon: success ? "checkmark.circle.fill" : "xmark.circle.fill",
             accentColor: success ? "green" : "red")
    }

    /// Notify when an AI task completes.
    func aiTaskFinished(summary: String, action: (() -> Void)? = nil) {
        postSystem(title: "AI Task Complete",
                   body: summary,
                   icon: "sparkles",
                   accentColor: "purple",
                   action: action)
    }

    /// Notify when a file operation finishes (export, conversion, etc.).
    func fileReady(name: String, url: URL? = nil) {
        post(title: "File ready",
             body: name,
             icon: "doc.fill",
             accentColor: "teal",
             action: url.map { u in { NSWorkspace.shared.activateFileViewerSelecting([u]) } })
    }

    /// Notify for context dock / adapter events.
    func adapterEvent(appName: String, message: String, icon: String = "app.badge") {
        post(title: appName, body: message, icon: icon, accentColor: "blue")
    }

    /// Notify for a browser / tab event.
    func browserEvent(title: String, url: String) {
        post(title: title, body: url, icon: "safari", accentColor: "blue")
    }
}
