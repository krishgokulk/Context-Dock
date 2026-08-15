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

    /// Known openings for apps worth opening with, then a generic one for anything else
    /// the user has connected — so a connected app is never absent from its own start
    /// screen just because this file has not heard of it.
    private var starters: [Starter] {
        connected.compactMap { adapter in
            switch adapter.bundleId {
            case "com.apple.Safari":
                return Starter(
                    bundleId: adapter.bundleId, title: "Summarise the page I'm reading",
                    subtitle: "Safari", prompt: "Summarise the page I'm reading")
            case "com.apple.mail":
                return Starter(
                    bundleId: adapter.bundleId, title: "What needs a reply?",
                    subtitle: "Mail", prompt: "What in my inbox needs a reply?")
            case "com.apple.iCal":
                return Starter(
                    bundleId: adapter.bundleId, title: "What's next today?",
                    subtitle: "Calendar", prompt: "What's on my calendar for the rest of today?")
            case "com.apple.Notes":
                return Starter(
                    bundleId: adapter.bundleId, title: "Find something in my notes",
                    subtitle: "Notes", prompt: "Search my notes for")
            case "com.apple.reminders":
                return Starter(
                    bundleId: adapter.bundleId, title: "What's still open?",
                    subtitle: "Reminders", prompt: "What reminders are still open?")
            case "com.apple.finder":
                return Starter(
                    bundleId: adapter.bundleId, title: "Tidy up my Downloads",
                    subtitle: "Finder", prompt: "What's taking up space in my Downloads?")
            case "com.microsoft.VSCode":
                return Starter(
                    bundleId: adapter.bundleId, title: "What changed in this project?",
                    subtitle: "Code", prompt: "What changed in my project recently?")
            default:
                return Starter(
                    bundleId: adapter.bundleId,
                    title: "Ask about \(adapter.appName)",
                    subtitle: adapter.appName,
                    prompt: "What can you do with \(adapter.appName)?")
            }
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
            ForEach(connected.prefix(8), id: \.bundleId) { adapter in
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

    private func openAdapterSettings() {
        NotificationCenter.default.post(
            name: NSNotification.Name("openSettingsAppAdapters"), object: nil)
        AppDelegate.shared?.showSettings()
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
