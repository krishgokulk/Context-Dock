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

    /// The corner runs the same screen in a third of the width. Window type sizes there
    /// left no room for the two labels on the connections row, and SwiftUI resolved that
    /// by wrapping them mid-word — "Connect ed", "Manag e" — rather than by dropping an
    /// icon. Compact changes the measurements; it does not change what the screen says.
    var compact = false

    @ObservedObject private var adapterManager = AppAdapterManager.shared

    private var connected: [AppAdapter] {
        adapterManager.adapters.filter(\.isEnabled)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: Metrics.blockSpacing(compact)) {
                header

                if connected.isEmpty {
                    notConnectedYet
                } else {
                    suggestions
                    connections
                }
            }
            .frame(maxWidth: compact ? .infinity : 520)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Metrics.horizontalPadding(compact))
        .padding(.vertical, compact ? Metrics.outerVertical : 0)
    }

    // MARK: - Measurements

    /// One set of numbers, read by the view that draws the screen and by the corner that
    /// has to know how tall it will be before it draws. Two sets is how a fixed 350-point
    /// card came to hold 234 points of content.
    enum Metrics {
        static let outerVertical: CGFloat = 12
        static let compactHeaderHeight: CGFloat = 40
        static let compactRowHeight: CGFloat = 42
        static let compactConnectionsHeight: CGFloat = 20
        static let dividerHeight: CGFloat = 1
        static let maxStarters = 3

        static func blockSpacing(_ compact: Bool) -> CGFloat { compact ? 12 : 20 }
        static func horizontalPadding(_ compact: Bool) -> CGFloat { compact ? 14 : 28 }
        static func titleSize(_ compact: Bool) -> CGFloat { compact ? 15 : 22 }
        static func rowVerticalPadding(_ compact: Bool) -> CGFloat { compact ? 7 : 10 }
        /// Five is what fits beside both labels at the corner's width without either of
        /// them giving up a character.
        static func maxIcons(_ compact: Bool) -> Int { compact ? 5 : 8 }

        /// What the compact screen will measure, given what it has to show.
        static func compactHeight(starters: Int, hasConnections: Bool) -> CGFloat {
            let rows = CGFloat(min(starters, maxStarters))
            guard rows > 0 else {
                return outerVertical * 2 + compactHeaderHeight
            }
            let list = rows * compactRowHeight + max(rows - 1, 0) * dividerHeight
            var height = outerVertical * 2 + compactHeaderHeight + blockSpacing(true) + list
            if hasConnections {
                height += blockSpacing(true) + compactConnectionsHeight
            }
            return height
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            Text("What are we working on?")
                .font(.system(size: Metrics.titleSize(compact), weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(
                connected.isEmpty
                    ? "Connect an app and this chat can read and act on it."
                    : "Ask anything, or start with one of these."
            )
            .font(.system(size: compact ? 11.5 : 12.5))
            .foregroundStyle(.secondary)
            .lineLimit(compact ? 1 : 2)
        }
        .frame(height: compact ? Metrics.compactHeaderHeight : nil, alignment: .topLeading)
    }

    // MARK: - Suggestions

    /// One suggestion per connected app, in the order the user connected them.
    ///
    /// Grounded rather than generic: "Summarise the page I'm reading" is only offered when
    /// Safari's adapter is on, so the suggestion and the capability can never disagree.
    private var suggestions: some View {
        VStack(spacing: 0) {
            ForEach(Array(shownStarters), id: \.prompt) { starter in
                Button {
                    onPick(starter.prompt)
                } label: {
                    HStack(spacing: 10) {
                        appIcon(for: starter.bundleId)
                            .frame(width: compact ? 17 : 18, height: compact ? 17 : 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(starter.title)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(starter.subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, Metrics.rowVerticalPadding(compact))
                    .frame(height: compact ? Metrics.compactRowHeight : nil)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if starter.prompt != shownStarters.last?.prompt {
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
        // Both labels are fixed and the icons are what yields. Without this the row is
        // three flexible things competing for one width, and SwiftUI takes the space out
        // of the text: at the corner's width that reads "Connect ed … Manag e".
        HStack(spacing: 8) {
            Text("Connected")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()

            HStack(spacing: 6) {
                ForEach(shownConnections, id: \.bundleId) { adapter in
                    appIcon(for: adapter.bundleId)
                        .frame(width: 16, height: 16)
                        .help(adapter.appName)
                }
                if connected.count > shownConnections.count {
                    Text("+\(connected.count - shownConnections.count)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .layoutPriority(-1)
            .clipped()

            Spacer(minLength: 4)

            Button("Manage") { openAdapterSettings() }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(height: compact ? Metrics.compactConnectionsHeight : nil)
    }

    private var shownStarters: [Starter] {
        Array(starters.prefix(Metrics.maxStarters))
    }

    private var shownConnections: [AppAdapter] {
        Array(connected.sorted { rank($0) < rank($1) }.prefix(Metrics.maxIcons(compact)))
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
