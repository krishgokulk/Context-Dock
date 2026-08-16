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

    @AppStorage("previewFolderGridView") private var gridView = false

    @State private var entries: [Entry] = []
    /// Folders walked into from here, so Back does not have to reopen anything.
    @State private var stack: [URL] = []
    @State private var selectedID: String?
    /// Measured, not guessed: a hardcoded column count makes Down crawl in a wide window.
    @State private var gridColumns = 4

    private var currentURL: URL { stack.last ?? url }

    struct Entry: Identifiable {
        let id: String
        let url: URL
        let name: String
        let detail: String
        let isDirectory: Bool
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
            Text("\(entries.count) item\(entries.count == 1 ? "" : "s")")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
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
                            selectedID == entry.id
                                ? Color.accentColor.opacity(0.18) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedID = entry.id }
                        .onTapGesture(count: 2) { activate(entry) }
                        .contextMenu { rowMenu(entry) }
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
                                selectedID == entry.id
                                    ? Color.accentColor.opacity(0.18) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                            .onTapGesture { selectedID = entry.id }
                            .onTapGesture(count: 2) { activate(entry) }
                            .contextMenu { rowMenu(entry) }
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
        Button(entry.isDirectory ? "Enter Folder" : "Preview") { activate(entry) }
        Button("Open") { NSWorkspace.shared.open(entry.url) }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.url.path, forType: .string)
        }
    }

    // MARK: - Behaviour

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
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: target,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        entries = contents
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
            .map { child in
                let values = try? child.resourceValues(
                    forKeys: [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey])
                let isDirectory = values?.isDirectory ?? false
                let size = values?.fileSize ?? 0
                var detail = isDirectory
                    ? "Folder"
                    : ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                if let modified = values?.contentModificationDate {
                    detail += " · " + modified.formatted(date: .abbreviated, time: .omitted)
                }
                return Entry(
                    id: child.path,
                    url: child,
                    name: child.lastPathComponent,
                    detail: detail,
                    isDirectory: isDirectory
                )
            }

        if selectedID == nil || !entries.contains(where: { $0.id == selectedID }) {
            selectedID = entries.first?.id
        }
    }
}
