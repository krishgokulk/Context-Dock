// PreviewFolderBrowser.swift
// Context-Dock
//
// A folder, previewed the way the pinned scope panels already show one: thumbnails,
// a selection you can drive from the keyboard, and a list / icon toggle in the corner.
//
// QLPreviewView renders a directory as one large folder icon, which tells the user
// nothing they did not already know. And a plain listing is only half an answer — the
// panels this app already ships let you arrow through a folder and peek a file without
// touching the mouse, so a preview that could not do that would be the odd one out.
//
// Navigation stays inside the window: entering a subfolder pushes onto a stack rather
// than opening Finder, and previewing a file hands the same window over to it.

import AppKit
import SwiftUI

struct PreviewFolderBrowser: View {
    let url: URL
    /// Changes when the assistant's tools touched this folder, so the listing re-reads
    /// instead of showing what was there before the command ran.
    var reloadToken = 0

    @AppStorage("previewFolderGridView") private var gridView = false
    @AppStorage("previewFolderSort") private var sortRaw = SortOrder.name.rawValue
    @AppStorage("previewFolderSortAscending") private var ascending = true

    @State private var entries: [Entry] = []
    /// Folders walked into from here, so Back does not have to reopen anything.
    @State private var stack: [URL] = []
    @State private var selectedID: String?
    /// More than one, because acting on a folder usually means acting on a handful of
    /// its files. Command-click adds, Shift-click takes the run between.
    @State private var selection: Set<String> = []
    @State private var anchorID: String?
    /// Measured, not guessed: a hardcoded column count makes Down crawl in a wide window.
    @State private var gridColumns = 4

    private var currentURL: URL { stack.last ?? url }

    enum SortOrder: String, CaseIterable {
        case name, date, size, kind

        var label: String {
            switch self {
            case .name: return "Name"
            case .date: return "Date Modified"
            case .size: return "Size"
            case .kind: return "Kind"
            }
        }
    }

    struct Entry: Identifiable {
        let id: String
        let url: URL
        let name: String
        let detail: String
        let isDirectory: Bool
        let size: Int
        let modified: Date
        let ext: String
    }

    private var sort: SortOrder { SortOrder(rawValue: sortRaw) ?? .name }

    /// What the user has actually picked. Falls back to the keyboard selection so a
    /// single row never needs command-clicking to be acted on.
    private var actionTargets: [Entry] {
        let chosen = entries.filter { selection.contains($0.id) }
        if !chosen.isEmpty { return chosen }
        return selectedEntry.map { [$0] } ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            if !stack.isEmpty { breadcrumb }

            if entries.isEmpty {
                Text("Empty folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if gridView {
                fileGrid
            } else {
                rowList
            }

            Divider().opacity(0.4)
            viewModeFooter
        }
        .task(id: currentURL) { load() }
        .task(id: reloadToken) { load() }
        .onChange(of: sortRaw) { _, _ in entries = sorted(entries) }
        .onChange(of: ascending) { _, _ in entries = sorted(entries) }
        .onChange(of: url) { _, _ in stack = [] }
        // Focusable so the panel is navigable, but without the ring: a focus halo around
        // the whole window read as the window being broken.
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { move($0) }
        .onKeyPress(.return) {
            guard let entry = selectedEntry else { return .ignored }
            activate(entry)
            return .handled
        }
        .onKeyPress(.space) {
            guard let entry = selectedEntry, !entry.isDirectory else { return .ignored }
            peek(entry)
            return .handled
        }
    }

    private var selectedEntry: Entry? {
        entries.first { $0.id == selectedID } ?? entries.first
    }

    // MARK: - Chrome

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Button { stack.removeLast() } label: {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Back")

            Text(currentURL.lastPathComponent)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05))
    }

    private var viewModeFooter: some View {
        HStack(spacing: 6) {
            Text(selection.count > 1
                ? "\(selection.count) of \(entries.count) selected"
                : "\(entries.count) item\(entries.count == 1 ? "" : "s")")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()

            Menu {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    Button {
                        if sort == order { ascending.toggle() } else { sortRaw = order.rawValue }
                    } label: {
                        if sort == order {
                            Label(order.label, systemImage: ascending ? "chevron.up" : "chevron.down")
                        } else {
                            Text(order.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 9, weight: .semibold))
                    Text(sort.label).font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
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

    // MARK: - List

    private var rowList: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        HStack(spacing: 10) {
                            FileThumbnailImage(
                                filePath: entry.url.path,
                                fallbackImage: nil,
                                systemName: entry.isDirectory ? "folder" : "doc",
                                tint: .accentColor,
                                size: 32,
                                cornerRadius: 4
                            )
                            .frame(width: 26, height: 26)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.name)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(entry.detail)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                            if entry.isDirectory {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            isHighlighted(entry)
                                ? Color.accentColor.opacity(0.18) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { activate(entry) }
                        .simultaneousGesture(TapGesture().modifiers(.command).onEnded {
                            toggle(entry)
                        })
                        .simultaneousGesture(TapGesture().modifiers(.shift).onEnded {
                            extendSelection(to: entry)
                        })
                        .onTapGesture { choose(entry) }
                        .contextMenu { rowMenu(entry) }
                        .modifier(PreviewFileDrag(entry: entry, all: actionTargets))
                        .id(entry.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { scroller.scrollTo(id, anchor: .center) }
            }
        }
    }

    // MARK: - Grid

    private var fileGrid: some View {
        GeometryReader { proxy in
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 88), spacing: 10)], spacing: 10
                    ) {
                        ForEach(entries) { entry in
                            VStack(spacing: 5) {
                                FileThumbnailImage(
                                    filePath: entry.url.path,
                                    fallbackImage: nil,
                                    systemName: entry.isDirectory ? "folder" : "doc",
                                    tint: .accentColor,
                                    size: 72,
                                    cornerRadius: 6
                                )
                                .frame(width: 64, height: 64)
                                Text(entry.name)
                                    .font(.system(size: 10))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .truncationMode(.middle)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .background(
                                isHighlighted(entry)
                                    ? Color.accentColor.opacity(0.18) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                            .onTapGesture(count: 2) { activate(entry) }
                            .simultaneousGesture(TapGesture().modifiers(.command).onEnded {
                                toggle(entry)
                            })
                            .simultaneousGesture(TapGesture().modifiers(.shift).onEnded {
                                extendSelection(to: entry)
                            })
                            .onTapGesture { choose(entry) }
                            .contextMenu { rowMenu(entry) }
                            .modifier(PreviewFileDrag(entry: entry, all: actionTargets))
                            .id(entry.id)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        scroller.scrollTo(id, anchor: .center)
                    }
                }
            }
            .onAppear { recomputeColumns(width: proxy.size.width) }
            .onChange(of: proxy.size.width) { _, width in recomputeColumns(width: width) }
        }
    }

    @ViewBuilder
    private func rowMenu(_ entry: Entry) -> some View {
        // A context menu on a row inside a selection acts on the selection; on a row
        // outside it, on that row. Same rule Finder uses.
        let targets = selection.contains(entry.id) ? actionTargets : [entry]
        let suffix = targets.count > 1 ? " (\(targets.count))" : ""

        Button(entry.isDirectory && targets.count == 1 ? "Enter Folder" : "Preview" + suffix) {
            if targets.count > 1 {
                let files = targets.filter { !$0.isDirectory }.map(\.url)
                if let first = files.first {
                    PreviewController.shared.present(
                        url: first, siblings: files, toggleIfSame: false)
                }
            } else {
                activate(entry)
            }
        }
        Button("Open" + suffix) { targets.forEach { NSWorkspace.shared.open($0.url) } }
        Button("Reveal in Finder" + suffix) {
            NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.url))
        }
        Button("Copy Path" + suffix) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                targets.map(\.url.path).joined(separator: "\n"), forType: .string)
        }
    }

    // MARK: - Behaviour

    private func isHighlighted(_ entry: Entry) -> Bool {
        selection.contains(entry.id) || (selection.isEmpty && selectedID == entry.id)
    }

    /// A plain click replaces the selection — the ordinary case, and the one that must
    /// not require modifiers.
    private func choose(_ entry: Entry) {
        selectedID = entry.id
        anchorID = entry.id
        selection = []
    }

    private func toggle(_ entry: Entry) {
        if selection.isEmpty, let selectedID { selection.insert(selectedID) }
        if selection.contains(entry.id) {
            selection.remove(entry.id)
        } else {
            selection.insert(entry.id)
        }
        selectedID = entry.id
        anchorID = entry.id
    }

    private func extendSelection(to entry: Entry) {
        let ids = entries.map(\.id)
        guard let from = ids.firstIndex(of: anchorID ?? selectedID ?? entry.id),
            let to = ids.firstIndex(of: entry.id)
        else { return }
        selection = Set(ids[min(from, to)...max(from, to)])
        selectedID = entry.id
    }

    /// Grid moves by a row of tiles; the list moves one line — the same arithmetic the
    /// pinned scope panels use, so both folders feel like one control.
    private func move(_ direction: MoveCommandDirection) {
        guard !entries.isEmpty else { return }
        let ids = entries.map(\.id)
        let current = ids.firstIndex(of: selectedID ?? "") ?? 0
        let stride = gridView ? max(1, gridColumns) : 1
        let next: Int
        switch direction {
        case .up: next = current - stride
        case .down: next = current + stride
        case .left: next = current - 1
        case .right: next = current + 1
        default: return
        }
        selectedID = ids[min(max(next, 0), ids.count - 1)]
        anchorID = selectedID
        selection = []
    }

    /// Folders open in place; files hand this window over to their own preview, so a
    /// peek into a folder never sprays panels across the screen.
    private func activate(_ entry: Entry) {
        if entry.isDirectory {
            stack.append(entry.url)
        } else {
            peek(entry)
        }
    }

    private func peek(_ entry: Entry) {
        let siblings = entries.filter { !$0.isDirectory }.map(\.url)
        PreviewController.shared.present(
            url: entry.url, siblings: siblings, toggleIfSame: false)
    }

    /// Mirrors the adaptive grid's own arithmetic: minimum tile 88, spacing 10.
    private func recomputeColumns(width: CGFloat) {
        let usable = max(0, width - 20)
        gridColumns = max(1, Int((usable + 10) / 98))
    }

    private func load() {
        let target = currentURL
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: target, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []

        let mapped = contents.map { child -> Entry in
            let values = try? child.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            let size = values?.fileSize ?? 0
            let modified = values?.contentModificationDate ?? .distantPast
            var detail = isDirectory
                ? "Folder"
                : ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            if modified != .distantPast {
                detail += " · " + modified.formatted(date: .abbreviated, time: .omitted)
            }
            return Entry(
                id: child.path,
                url: child,
                name: child.lastPathComponent,
                detail: detail,
                isDirectory: isDirectory,
                size: size,
                modified: modified,
                ext: child.pathExtension.lowercased()
            )
        }

        entries = sorted(mapped)
        selection = selection.filter { id in entries.contains { $0.id == id } }
        if selectedID == nil || !entries.contains(where: { $0.id == selectedID }) {
            selectedID = entries.first?.id
        }
    }

    /// Folders stay above files whatever the sort — a directory is a place, not a
    /// document, and mixing them by size or date buries the way out of the folder.
    private func sorted(_ input: [Entry]) -> [Entry] {
        let ordered = input.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let result: Bool
            switch sort {
            case .name:
                result = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .date:
                result = lhs.modified < rhs.modified
            case .size:
                result = lhs.size < rhs.size
            case .kind:
                result = lhs.ext == rhs.ext
                    ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    : lhs.ext < rhs.ext
            }
            return ascending ? result : !result
        }
        return ordered
    }
}

/// Files dragged straight out of the preview, the whole selection at once when there
/// is one. A folder you can look at but not take anything from is half a folder.
private struct PreviewFileDrag: ViewModifier {
    let entry: PreviewFolderBrowser.Entry
    let all: [PreviewFolderBrowser.Entry]

    func body(content: Content) -> some View {
        content.onDrag {
            let dragged = all.contains(where: { $0.id == entry.id }) ? all : [entry]
            let providers = dragged.compactMap { NSItemProvider(contentsOf: $0.url) }
            return providers.first ?? NSItemProvider()
        }
    }
}
