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
            size: NSSize(width: 620, height: 440),
            minSize: NSSize(width: 380, height: 240)
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

    /// Every panel can show the assistant; the keyword only decides the default.
    /// A user who wants AI on an extension that never declared it should not have to
    /// go and edit the extension.
    @State private var showAI: Bool? = nil
    @State private var gridView = false
    private var aiVisible: Bool { showAI ?? CustomListProviderService.hasAIPanel(command) }

    /// The panel's own field filters rows. A computed extension takes its input from
    /// the dock, so a second box here would be a duplicate that does nothing useful.
    private var showsFilterField: Bool { !isComputed }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            // AI sits beside the content, not under it — the same split Quick Note
            // uses. Stacked, the assistant pushed the rows into a sliver and the
            // panel stopped being useful for the thing it was pinned for.
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if showsFilterField {
                        searchField
                        Divider().opacity(0.3)
                    }
                    if gridView && hasFileRows { fileGrid } else { rowList }
                    if hasFileRows {
                        Divider().opacity(0.3)
                        viewModeFooter
                    }
                }
                .frame(maxWidth: .infinity)

                if aiVisible {
                    Divider()
                    ExtensionPanelAIComposer(
                        title: command.name,
                        subtitle: command.description,
                        extraPrompt: aiContext
                    )
                    .frame(width: 300)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The panel itself is transparent so Liquid Glass can show the desktop; the
        // material has to come from the content. Removing the old tabbed root view
        // took the background with it and left the rows floating on the wallpaper.
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
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
            Spacer()

            Button { showAI = !aiVisible } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(aiVisible ? Color.accentColor : .secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(aiVisible ? "Hide assistant" : "Show assistant")

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
                    if row.isCompare {
                        PanelCompareCard(row: row, command: command, query: query) {
                            CustomListProviderService.shared.invalidate(command)
                            refresh()
                        }
                    } else {
                    Button {
                        CustomListProviderService.shared.runAction(
                            command, row: row, query: query)
                        refresh()
                    } label: {
                        HStack(spacing: 8) {
                            // Same treatment the inline dock rows get: a row whose id is
                            // a real file shows that file, not a generic glyph. The panel
                            // had its own simpler renderer and missed out.
                            FileThumbnailImage(
                                filePath: filePath(for: row),
                                fallbackImage: nil,
                                systemName: symbol(row.icon),
                                tint: .accentColor,
                                size: 22,
                                cornerRadius: 4
                            )
                            .frame(width: 22, height: 22)
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

    /// A row stands for a file when its id (or icon) is a path that exists.
    private func filePath(for row: CustomListRow) -> String? {
        for candidate in [row.id, row.icon].compactMap({ $0 }) {
            guard candidate.hasPrefix("/") || candidate.hasPrefix("~") else { continue }
            let path = (candidate as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
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


// MARK: - Compare card (panel)

/// The same two-value card the dock renders, so a converter looks identical whether
/// it is inline or pinned. Separate from the dock's copy because that one lives on
/// LauncherView and reads its state.
struct PanelCompareCard: View {
    let row: CustomListRow
    let command: SystemCommand
    let query: String
    let onChanged: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            pane(value: row.left ?? "", caption: row.title,
                 drill: row.leftQuery, isResult: false)

            Image(systemName: row.centerAction != nil
                  ? "arrow.left.arrow.right" : (row.centerIcon ?? "arrow.right"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(row.centerAction != nil
                                 ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: 26, height: 26)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .contentShape(Circle())
                .onTapGesture {
                    guard let action = row.centerAction else { return }
                    let synthetic = CustomListRow(
                        id: action, title: action, subtitle: nil, badge: nil, icon: nil)
                    CustomListProviderService.shared.runAction(
                        command, row: synthetic, query: query
                    ) { onChanged() }
                }

            pane(value: row.right ?? "", caption: row.badge,
                 drill: row.rightQuery, isResult: true)
        }
        .frame(height: 92)
        .overlay { Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 1) }
        .background(Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func pane(value: String, caption: String?,
                      drill: String?, isResult: Bool) -> some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.system(size: 18, weight: isResult ? .bold : .semibold, design: .rounded))
                .foregroundStyle(isResult ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let caption, !caption.isEmpty {
                if let drill {
                    CompareCaptionPill(caption: caption, drillQuery: drill,
                                       commandID: command.id, onPicked: onChanged)
                } else {
                    Text(caption)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }
}


// MARK: - File grid

extension ScopedListPanelContent {
    /// Only a panel whose rows are files gains a grid — a list of ports or branches
    /// has nothing to show as a tile.
    var hasFileRows: Bool {
        displayedRows.contains { filePath(for: $0) != nil }
    }

    var viewModeFooter: some View {
        HStack(spacing: 6) {
            Spacer()
            ForEach([false, true], id: \.self) { isGrid in
                Button { gridView = isGrid } label: {
                    Image(systemName: isGrid ? "square.grid.2x2" : "list.bullet")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(gridView == isGrid
                                         ? AnyShapeStyle(Color.accentColor)
                                         : AnyShapeStyle(.secondary))
                        .frame(width: 22, height: 18)
                        .background(gridView == isGrid
                                    ? Color.accentColor.opacity(0.15) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isGrid ? "Icon view" : "List view")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    var fileGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 10)], spacing: 10) {
                ForEach(displayedRows) { row in
                    Button {
                        CustomListProviderService.shared.runAction(
                            command, row: row, query: query)
                    } label: {
                        VStack(spacing: 5) {
                            FileThumbnailImage(
                                filePath: filePath(for: row),
                                fallbackImage: nil,
                                systemName: "doc",
                                tint: .accentColor,
                                size: 64,
                                cornerRadius: 6
                            )
                            .frame(width: 64, height: 64)
                            Text(row.title)
                                .font(.system(size: 10))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
    }
}
