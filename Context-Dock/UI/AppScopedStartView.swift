// AppScopedStartView.swift
// Context-Dock
//
// What an app's thread shows before anyone types.
//
// The unscoped chat learned to open on what it can reach; a scoped thread still opened on
// "Where should we begin?" — on the reasoning that a thread named HandBrake already says
// what it is about. It says what it is *about*. It says nothing about what it can do, and
// that is the question a person actually has when they open one: this app, this assistant,
// what now.
//
// The right-hand panel already lists every action, skill, CLI tool and menu command in
// scope, and the user has to know to open it. The same inventory is the material for a
// start screen, so the two can never disagree — and a suggestion built from the inventory
// can never name something that isn't there, which is the failure mode of every generic
// starter list.

import AppKit
import SwiftUI

struct AppScopedStartView: View {
    let appName: String
    let bundleId: String
    /// Fills the composer and sends, so a suggestion stays a question the user asked.
    let onPick: (String) -> Void

    private var inventory: ScopeInventory {
        ScopeInventory.app(bundleId: bundleId, appName: appName)
    }

    var body: some View {
        let inventory = inventory
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 18) {
                header(inventory)
                if starters(from: inventory).isEmpty {
                    nothingLinked
                } else {
                    suggestions(starters(from: inventory))
                }
                reach(inventory)
            }
            .frame(maxWidth: 520)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 28)
    }

    // MARK: - Header

    private func header(_ inventory: ScopeInventory) -> some View {
        HStack(spacing: 12) {
            appIcon
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(appName)
                    .font(.system(size: 20, weight: .semibold))
                Text(summary(inventory))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// What is in scope, counted. "20 menu commands" is the fact that tells someone this
    /// thread can drive the app, and it is the fact the empty screen was withholding.
    private func summary(_ inventory: ScopeInventory) -> String {
        let counts = inventory.groups.map { group in
            "\(group.items.count) \(group.title.lowercased())"
        }
        return counts.isEmpty
            ? "Nothing is linked to \(appName) yet."
            : counts.prefix(4).joined(separator: " · ")
    }

    // MARK: - Suggestions

    private struct Starter: Hashable {
        let title: String
        let subtitle: String
        let symbol: String
        let prompt: String
    }

    /// One opening per kind of capability, in the order a person reaches for them.
    ///
    /// Drawn from the inventory rather than written here, so an app with two CLI tools and
    /// no actions gets suggestions about its CLI tools. The generic "What can you do?" is
    /// last and only when something real exists to answer it with.
    private func starters(from inventory: ScopeInventory) -> [Starter] {
        var starters: [Starter] = []
        for group in inventory.groups {
            guard let first = group.items.first else { continue }
            // Panel labels carry a qualifier for the reader — "Rotate Document — asks
            // first". Sending that to the model as a request would ask it to run a
            // capability whose name includes a caveat about itself.
            let item = first.components(separatedBy: " — ").first ?? first
            switch group.title {
            case "Actions":
                starters.append(Starter(
                    title: item, subtitle: "Run this action",
                    symbol: "bolt.fill", prompt: "\(item) in \(appName)"))
            case "Skills":
                starters.append(Starter(
                    title: item, subtitle: "Your saved workflow",
                    symbol: "brain.head.profile", prompt: "Run \(item)"))
            case "CLI tools":
                starters.append(Starter(
                    title: "Ask \(item) something", subtitle: "Command line · no window opens",
                    symbol: "terminal", prompt: "What can \(item) do?"))
            case "Menu commands":
                starters.append(Starter(
                    title: item, subtitle: "App menu · opens the app",
                    symbol: "filemenu.and.selection", prompt: "\(item) in \(appName)"))
            default:
                continue
            }
        }
        if !starters.isEmpty {
            starters.append(Starter(
                title: "What can you do with \(appName)?",
                subtitle: "Everything in scope for this thread",
                symbol: "questionmark.circle", prompt: "What can you do with \(appName)?"))
        }
        return Array(starters.prefix(4))
    }

    private func suggestions(_ starters: [Starter]) -> some View {
        VStack(spacing: 0) {
            ForEach(starters, id: \.self) { starter in
                Button {
                    onPick(starter.prompt)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: starter.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(starter.title)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
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

                if starter != starters.last {
                    Divider().opacity(0.5)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05)))
    }

    // MARK: - Reach

    /// The same groups the side panel shows, as one line. Not a second copy of the panel:
    /// it says what kinds of thing exist and how many, which is what decides whether a
    /// person opens the panel at all.
    @ViewBuilder
    private func reach(_ inventory: ScopeInventory) -> some View {
        if !inventory.groups.isEmpty {
            HStack(spacing: 10) {
                ForEach(inventory.groups.prefix(5)) { group in
                    HStack(spacing: 4) {
                        Image(systemName: group.symbol)
                            .font(.system(size: 10))
                        Text("\(group.items.count)")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(.tertiary)
                    .help(group.title)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var nothingLinked: some View {
        Text(
            "This thread can answer questions about \(appName), but nothing is linked to it "
                + "yet — no actions, skills, tools or cached menus. Add tools for \(appName) "
                + "from the panel on the right."
        )
        .font(.system(size: 12.5))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var appIcon: some View {
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
