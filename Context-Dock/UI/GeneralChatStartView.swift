// GeneralChatStartView.swift
// Context-Dock
//
// What a fresh General chat shows before anyone types.
//
// The window opened on one line — "Where should we begin?" — and nothing else. The user had
// to already know what this thing could do, which is the one thing a new window is worst at
// telling them. Meanwhile the app knows exactly what it can reach: the adapters the user
// enabled are sitting in AppAdapterManager, and the model is told about them on every
// question. The user was the only party in the conversation who could not see them.
//
// So the start screen is built from what is actually connected. Every suggestion names an
// app whose adapter is enabled, so a click can never lead to an access gate for something
// the screen implied was already available — a promise the window makes and the next screen
// breaks is worse than an empty window.
//
// Nothing here reads live state. Opening a window must not cost a round of accessibility
// reads across half a dozen apps, and a suggestion that takes a second to appear is worse
// than one that was never offered.

import AppKit
import SwiftUI

struct GeneralChatStartView: View {
    /// Fills the composer and sends, so a suggestion is a question the user asked rather
    /// than a command the window ran on their behalf.
    let onPick: (String) -> Void

    @ObservedObject private var adapterManager = AppAdapterManager.shared

    private var connected: [AppAdapter] {
        adapterManager.adapters.filter(\.isEnabled)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 20) {
                header

                if connected.isEmpty {
                    notConnectedYet
                } else {
                    suggestions
                    connections
                }
            }
            .frame(maxWidth: 520)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 28)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What are we working on?")
                .font(.system(size: 22, weight: .semibold))
            Text(
                connected.isEmpty
                    ? "Connect an app and this chat can read and act on it."
                    : "Ask anything, or start with one of these."
            )
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Suggestions

    /// One suggestion per connected app, in the order the user connected them.
    ///
    /// Grounded rather than generic: "Summarise the page I'm reading" is only offered when
    /// Safari's adapter is on, so the suggestion and the capability can never disagree.
    private var suggestions: some View {
        VStack(spacing: 0) {
            ForEach(Array(starters.prefix(3)), id: \.prompt) { starter in
                Button {
                    onPick(starter.prompt)
                } label: {
                    HStack(spacing: 10) {
                        appIcon(for: starter.bundleId)
                            .frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(starter.title)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.primary)
                            Text(starter.subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if starter.prompt != starters.prefix(3).last?.prompt {
                    Divider().opacity(0.5)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05)))
    }

    private struct Starter {
        let bundleId: String
        let title: String
        let subtitle: String
        let prompt: String
    }

    /// How useful an app is to *open with*, highest first.
    ///
    /// Adapter order is installation order, which on a Mac with fifty adapters put System
    /// Settings, a media player and a proxy utility at the top — three suggestions nobody
    /// starts a day with. An app with a real opening beats one running beats one merely
    /// installed, so the three on offer are the three worth offering.
    private func rank(_ adapter: AppAdapter) -> Int {
        if Self.openings[adapter.bundleId] != nil { return 0 }
        let isRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == adapter.bundleId && $0.activationPolicy == .regular
        }
        return isRunning ? 1 : 2
    }

    /// The apps worth starting a conversation with, and what to say to them.
    private static let openings: [String: (String, String, String)] = [
        "com.apple.Safari": (
            "Summarise the page I'm reading", "Safari", "Summarise the page I'm reading"
        ),
        "com.apple.mail": (
            "What needs a reply?", "Mail", "What in my inbox needs a reply?"
        ),
        "com.apple.iCal": (
            "What's next today?", "Calendar",
            "What's on my calendar for the rest of today?"
        ),
        "com.apple.Notes": (
            "Find something in my notes", "Notes", "Search my notes for"
        ),
        "com.apple.reminders": (
            "What's still open?", "Reminders", "What reminders are still open?"
        ),
        "com.apple.finder": (
            "Tidy up my Downloads", "Finder", "What's taking up space in my Downloads?"
        ),
        "com.microsoft.VSCode": (
            "What changed in this project?", "Code",
            "What changed in my project recently?"
        ),
        "com.apple.MobileSMS": (
            "Catch me up on Messages", "Messages", "What messages have I not replied to?"
        ),
    ]

    /// Known openings first, then anything else the user has connected — so a connected app
    /// is never absent from its own start screen just because this file has not heard of it.
    private var starters: [Starter] {
        connected.sorted { rank($0) < rank($1) }.compactMap { adapter in
            if let opening = Self.openings[adapter.bundleId] {
                return Starter(
                    bundleId: adapter.bundleId, title: opening.0,
                    subtitle: opening.1, prompt: opening.2)
            }
            return Starter(
                bundleId: adapter.bundleId,
                title: "Ask about \(adapter.appName)",
                subtitle: adapter.appName,
                prompt: "What can you do with \(adapter.appName)?")
        }
    }

    // MARK: - Connections

    /// What this chat can reach, as the apps themselves.
    ///
    /// The capability block already tells the model all of this on every question; showing
    /// it here means the user and the model finally know the same thing.
    private var connections: some View {
        HStack(spacing: 8) {
            Text("Connected")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            ForEach(connected.sorted { rank($0) < rank($1) }.prefix(8), id: \.bundleId) {
                adapter in
                appIcon(for: adapter.bundleId)
                    .frame(width: 16, height: 16)
                    .help(adapter.appName)
            }
            if connected.count > 8 {
                Text("+\(connected.count - 8)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button("Manage") { openAdapterSettings() }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
    }

    /// The screen for someone who has connected nothing. Saying so plainly, with the one
    /// action that changes it, beats an empty prompt that looks like the app is thinking.
    private var notConnectedYet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "No apps are connected yet. This chat can still answer questions, but it "
                    + "can't read or act on anything on your Mac until you enable an app "
                    + "adapter."
            )
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                openAdapterSettings()
            } label: {
                Text("Connect an app")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.accentColor.opacity(0.9)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }

    /// Opens Settings *on* App Adapters, rather than opening Settings and leaving the user
    /// to find it. The old post went to "openSettingsAppAdapters", a name nothing listens
    /// for — so the button landed on whichever page was last open, and a button named
    /// Manage that arrives somewhere unrelated reads as a bug in the app.
    private func openAdapterSettings() {
        AppDelegate.shared?.showSettings()
        // The settings window has to exist before it can be navigated.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NotificationCenter.default.post(
                name: .openSettingsPage, object: nil,
                userInfo: ["page": SettingsPage.frontmostAppAdapters.rawValue])
        }
    }

    private func appIcon(for bundleId: String) -> some View {
        let image =
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        return Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed").resizable()
            }
        }
        .aspectRatio(contentMode: .fit)
    }
}
