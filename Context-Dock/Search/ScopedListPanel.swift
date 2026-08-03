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

    /// One window per pinned extension, like a sticky note. A single tabbed window
    /// made two unrelated extensions share a size and a position, which is wrong for
    /// panels the user pins precisely because they want them side by side.
    private var panels: [UUID: NSPanel] = [:]

    private init() {}

    func isPinned(_ id: UUID) -> Bool { pinnedCommandIDs.contains(id) }

    func toggle(_ command: SystemCommand) {
        if isPinned(command.id) { unpin(command.id) } else { pin(command) }
    }

    func pin(_ command: SystemCommand) {
        if let existing = panels[command.id] {
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            return
        }
        let p = GlassFloatingPanel.make(
            size: NSSize(width: 460, height: 440),
            minSize: NSSize(width: 340, height: 240)
        )
        p.contentView = NSHostingView(rootView: ScopedListPanelContent(command: command))

        // Cascade so a second pin doesn't land exactly on top of the first.
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let step = CGFloat(panels.count) * 28
            p.setFrameTopLeftPoint(NSPoint(x: f.maxX - 500 - step, y: f.maxY - 80 - step))
        }

        let id = command.id
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: p, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panels[id] = nil
                self?.pinnedCommandIDs.removeAll { $0 == id }
            }
        }

        panels[id] = p
        if !pinnedCommandIDs.contains(id) { pinnedCommandIDs.append(id) }
        p.orderFrontRegardless()
    }

    func unpin(_ id: UUID) {
        panels[id]?.close()
        panels[id] = nil
        pinnedCommandIDs.removeAll { $0 == id }
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
            // Close sits at the leading edge, where macOS puts it — the panel hides
            // the real traffic lights to keep the glass unbroken.
            Button { manager.unpin(command.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(Color.primary.opacity(0.10), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close")

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
            Image(systemName: "pin.fill")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .help("Pinned — the scope also stays available in the dock")
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
