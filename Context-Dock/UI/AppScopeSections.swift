// AppScopeSections.swift
// Context-Dock
//
// The groups of the app's settings card — Can do · Knows · Sees now · Allowed — as pieces
// both the Corner's card (AppScopeCard) and Settings ▸ App Packs draw. One copy: a change
// to how a group reads lands in both places.

import SwiftUI

extension ScopeInventory {
    /// The inventory groups that are what the app *knows* (steering text), not what it can
    /// run. Everything else is "Can do".
    static let knowsGroupTitles: Set<String> = ["Skills"]

    var canDoGroups: [Group] { groups.filter { !Self.knowsGroupTitles.contains($0.title) } }
    var knowsGroups: [Group] { groups.filter { Self.knowsGroupTitles.contains($0.title) } }
}

/// A titled group: "CAN DO", "KNOWS", "SEES NOW", "ALLOWED".
struct AppScopeSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            content
        }
    }
}

/// A row with a count that opens onto its items.
struct AppScopeDisclosure<Content: View>: View {
    let id: String
    let symbol: String
    let title: String
    let count: Int
    @Binding var expanded: Set<String>
    let content: Content

    init(
        id: String, symbol: String, title: String, count: Int, expanded: Binding<Set<String>>,
        @ViewBuilder content: () -> Content
    ) {
        self.id = id; self.symbol = symbol; self.title = title; self.count = count
        self._expanded = expanded
        self.content = content()
    }

    var body: some View {
        let open = expanded.contains(id)
        VStack(alignment: .leading, spacing: 3) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    if open { expanded.remove(id) } else { expanded.insert(id) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: symbol).frame(width: 16).foregroundStyle(.secondary)
                    Text(title).font(.system(size: 12))
                    Spacer(minLength: 0)
                    Text("\(count)").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(count)")
            .accessibilityHint(open ? "Collapses the list" : "Expands the list")
            if open { content }
        }
    }
}

/// Inventory groups as disclosures listing their items by name.
struct AppScopeInventoryGroups: View {
    let groups: [ScopeInventory.Group]
    @Binding var expanded: Set<String>
    var limit = 12

    var body: some View {
        ForEach(groups) { group in
            AppScopeDisclosure(
                id: group.title, symbol: group.symbol, title: group.title,
                count: group.items.count, expanded: $expanded
            ) {
                ForEach(Array(group.items.prefix(limit).enumerated()), id: \.offset) { _, item in
                    Text(item)
                        .font(group.isMonospaced
                            ? .system(size: 11.5, design: .monospaced) : .system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 24)
                }
                if group.items.count > limit {
                    Text("+\(group.items.count - limit) more")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .padding(.leading, 24)
                }
            }
        }
    }
}

/// "Sees now": what the next question would carry, one line each.
struct AppScopeSeesNowList: View {
    let lines: [AppScopeContextLine]
    var emptyText = "Only what you type."

    var body: some View {
        if lines.isEmpty {
            Text(emptyText).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        ForEach(lines) { line in
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: line.symbol).frame(width: 16)
                    .foregroundStyle(line.isRefused ? Color.orange : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(line.title).font(.system(size: 12)).lineLimit(1)
                    Text(line.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// "Allowed": Computer Use for the app, the menu commands that run without asking, and the
/// provider questions go to. Reads and writes the same stores Settings does.
struct AppScopeAllowedList: View {
    let bundleID: String
    @ObservedObject private var computerUse = ComputerUseConsentStore.shared
    @State private var allowedCommands: [String] = []

    init(bundleID: String) { self.bundleID = bundleID }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow.click.2").frame(width: 16).foregroundStyle(.secondary)
                Text("Computer Use").font(.system(size: 12))
                Spacer(minLength: 0)
                Menu {
                    ForEach(ComputerUseMode.allCases, id: \.self) { mode in
                        Button {
                            computerUse.setMode(mode, for: bundleID)
                        } label: {
                            if computerUse.mode(for: bundleID) == mode {
                                Label(mode.title, systemImage: "checkmark")
                            } else {
                                Text(mode.title)
                            }
                        }
                    }
                } label: {
                    Text(computerUse.mode(for: bundleID).title).font(.system(size: 11.5))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .help(computerUse.isMasterEnabled
                ? computerUse.mode(for: bundleID).explanation
                : "Computer Use is off for every app in Settings")
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield").frame(width: 16).foregroundStyle(.secondary)
                Text(allowedCommands.isEmpty
                    ? "No commands run without asking"
                    : "\(allowedCommands.count) command\(allowedCommands.count == 1 ? "" : "s") run without asking")
                    .font(.system(size: 12))
                    .help(allowedCommands.joined(separator: "\n"))
                Spacer(minLength: 0)
                if !allowedCommands.isEmpty {
                    Button("Forget") {
                        AppMenuConsentStore.shared.forget(bundleId: bundleID)
                        allowedCommands = []
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.accentColor)
                }
            }
            HStack(spacing: 8) {
                AIProviderIcon(provider: AppSettings.shared.selectedAIProvider, size: 14)
                    .frame(width: 16)
                Text(AppSettings.shared.selectedAIProvider.displayName).font(.system(size: 12))
                Spacer(minLength: 0)
            }
        }
        .onAppear { allowedCommands = AppMenuConsentStore.shared.allowedCommands(bundleId: bundleID) }
        .onChange(of: bundleID) { _, id in
            allowedCommands = AppMenuConsentStore.shared.allowedCommands(bundleId: id)
        }
    }
}
