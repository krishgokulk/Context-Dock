// ScopedListPanel.swift
// Context-Dock
//
// Detaches a live list extension out of the dock into a floating panel — the same
// move Quick Note already offers, now available to every `provider:custom` scope.
//
// Inline in the dock is the primary surface: type the extension's name, its rows
// render under the input, it closes when you're done. Pinning is for the ones you
// want to keep watching (ports, containers, a converter) while you work elsewhere.
// Both read the same CustomListProviderService cache, so a pinned panel and the
// inline scope can never disagree.

import AppKit
import Combine
import SwiftUI

@MainActor
final class ScopedListPanelManager: ObservableObject {
    static let shared = ScopedListPanelManager()

    @Published private(set) var pinnedCommandIDs: [UUID] = []
    @Published var activeCommandID: UUID?

    private var panel: NSPanel?

    private init() {}

    func isPinned(_ id: UUID) -> Bool { pinnedCommandIDs.contains(id) }

    func toggle(_ command: SystemCommand) {
        if isPinned(command.id) { unpin(command.id) } else { pin(command) }
    }

    func pin(_ command: SystemCommand) {
        ensureWindow()
        if !pinnedCommandIDs.contains(command.id) { pinnedCommandIDs.append(command.id) }
        activeCommandID = command.id
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
    }

    func unpin(_ id: UUID) {
        guard let idx = pinnedCommandIDs.firstIndex(of: id) else { return }
        pinnedCommandIDs.remove(at: idx)
        if activeCommandID == id {
            activeCommandID = pinnedCommandIDs.indices.contains(idx)
                ? pinnedCommandIDs[idx]
                : pinnedCommandIDs.last
        }
        if pinnedCommandIDs.isEmpty { panel?.close() }
    }

    private func ensureWindow() {
        guard panel == nil else { return }
        let p = GlassFloatingPanel.make(
            size: NSSize(width: 480, height: 460),
            minSize: NSSize(width: 360, height: 260)
        )
        p.contentView = NSHostingView(rootView: ScopedListPanelRootView())

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameTopLeftPoint(NSPoint(x: f.maxX - 520, y: f.maxY - 80))
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: p, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel = nil
                self?.pinnedCommandIDs = []
                self?.activeCommandID = nil
            }
        }
        panel = p
        p.orderFrontRegardless()
    }
}

// MARK: - Root

struct ScopedListPanelRootView: View {
    @ObservedObject private var manager = ScopedListPanelManager.shared

    private var command: SystemCommand? {
        guard let id = manager.activeCommandID else { return nil }
        return SystemCommandsRegistry.shared.commands.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            if manager.pinnedCommandIDs.count > 1 { tabStrip }
            if let command {
                ScopedListPanelContent(command: command)
                    .id(command.id)
            } else {
                Spacer()
                Text("Nothing pinned").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(manager.pinnedCommandIDs, id: \.self) { id in
                    if let cmd = SystemCommandsRegistry.shared.commands.first(where: { $0.id == id }) {
                        Button { manager.activeCommandID = id } label: {
                            Text(cmd.name)
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    manager.activeCommandID == id
                                        ? Color.accentColor.opacity(0.25)
                                        : Color.primary.opacity(0.06),
                                    in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
        }
    }
}

// MARK: - Content

struct ScopedListPanelContent: View {
    let command: SystemCommand

    @ObservedObject private var manager = ScopedListPanelManager.shared
    @State private var rows: [CustomListRow] = []
    @State private var query = ""
    @State private var ticker: Timer?

    private var isComputed: Bool { CustomListProviderService.isLiveQuery(command) }

    private var hasAI: Bool { CustomListProviderService.hasAIPanel(command) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            searchField
            Divider().opacity(0.3)
            rowList
            if hasAI {
                Divider().opacity(0.3)
                ExtensionPanelAIComposer(
                    title: command.name,
                    subtitle: command.description,
                    extraPrompt: aiContext
                )
                .frame(minHeight: 190)
            }
        }
        .onAppear { start() }
        .onDisappear { ticker?.invalidate() }
    }

    /// Hand the model what the panel is currently showing. Without it the assistant
    /// is talking about the extension in the abstract while the user is looking at
    /// concrete rows.
    private var aiContext: String {
        let lines = displayedRows.prefix(20).map { row -> String in
            let sub = (row.subtitle?.isEmpty == false) ? " — \(row.subtitle!)" : ""
            return "• \(row.title)\(sub)"
        }
        guard !lines.isEmpty else { return "" }
        return "Rows currently shown in this panel:\n" + lines.joined(separator: "\n")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: command.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tint)
            Text(command.name).font(.system(size: 13, weight: .semibold))
            if hasAI {
                Text("AI")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
            Spacer()
            Button { manager.unpin(command.id) } label: {
                Image(systemName: "pin.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Unpin — the scope stays available in the dock")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            TextField(isComputed ? "Type input…" : "Filter…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onChange(of: query) { _, _ in refresh() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var rowList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(displayedRows) { row in
                    Button {
                        CustomListProviderService.shared.runAction(
                            command, row: row, query: query)
                        refresh()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: symbol(row.icon))
                                .font(.system(size: 11))
                                .foregroundStyle(.tint)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.title).font(.system(size: 12, weight: .medium))
                                if let sub = row.subtitle, !sub.isEmpty {
                                    Text(sub).font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if let badge = row.badge, !badge.isEmpty {
                                Text(badge).font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Computed panels already accounted for the query inside their script, so
    /// filtering their output again would hide the very answer they produced.
    private var displayedRows: [CustomListRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !isComputed, !q.isEmpty else { return rows }
        return rows.filter {
            $0.title.lowercased().contains(q)
                || ($0.subtitle?.lowercased().contains(q) ?? false)
        }
    }

    private func symbol(_ icon: String?) -> String {
        guard let icon, !icon.isEmpty, !icon.contains("/") else { return "doc" }
        return icon
    }

    private func start() {
        refresh()
        // Same cadence the inline scope uses, so a pinned panel is never staler
        // than the dock would have been.
        ticker = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in refresh() }
        }
    }

    private func refresh() {
        let service = CustomListProviderService.shared
        if service.isStale(command, query: query) {
            service.refresh(command, query: query) {
                rows = service.rows(for: command)
            }
        }
        rows = service.rows(for: command)
    }
}
