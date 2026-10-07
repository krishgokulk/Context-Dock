// ClipboardBoardCard.swift
// Context-Dock
//
// The clipboard, in the shell's result board (owner 2026-10-07).
//
// The clipboard used to be a card of its own in the right-hand corner, raised by every copy
// and by the hotkey. The owner asked for it inside the result sheet instead, laid out the way
// Raycast lays its Clipboard History: the field above (here: below) filters, the clips on the
// left grouped by day, the chosen clip on the right with what it is, and a footer naming what
// Return does. It is the board every other scope uses — one card over the field, at the
// field's own width, list beside preview (#191) — not a second container.
//
// The history, the filters, the selection and the paste are `ClipboardPanelModel`'s and
// `ClipboardPanelController`'s, unchanged. This file only draws them, plus the pure rules the
// board adds: the type filter, the keys, and what the Information section says.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Type filter

/// Raycast's "All Types / Text / Images / Files / Links" menu.
enum ClipboardKindFilter: String, CaseIterable, Identifiable {
    case all, text, images, files, links

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All Types"
        case .text: return "Text Only"
        case .images: return "Images Only"
        case .files: return "Files Only"
        case .links: return "Links Only"
        }
    }

    func matches(_ entry: LauncherView.ClipboardEntry) -> Bool {
        switch self {
        case .all: return true
        case .text: return ClipboardClipInfo.kind(of: entry) == .text
        case .images: return ClipboardClipInfo.kind(of: entry) == .image
        case .files: return ClipboardClipInfo.kind(of: entry) == .file
        case .links: return ClipboardClipInfo.kind(of: entry) == .link
        }
    }
}

// MARK: - What a clip is

/// The words the board shows for a clip — its row title and its Information section. Pure,
/// so the rules are tested rather than eyeballed.
enum ClipboardClipInfo {
    enum Kind: Equatable {
        case text, image, file, link

        var label: String {
            switch self {
            case .text: return "Text"
            case .image: return "Image"
            case .file: return "File"
            case .link: return "Link"
            }
        }
    }

    static func kind(of entry: LauncherView.ClipboardEntry) -> Kind {
        if entry.imageData != nil || entry.imageFileName != nil { return .image }
        if !entry.filePaths.isEmpty {
            return entry.filePaths.allSatisfy(isImagePath) ? .image : .file
        }
        return isLink(entry.text) ? .link : .text
    }

    /// One line, no spaces, with a web scheme: a link, not prose that mentions one.
    static func isLink(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
            let url = URL(string: trimmed), let scheme = url.scheme?.lowercased()
        else { return false }
        return ["http", "https"].contains(scheme) && url.host != nil
    }

    static func isImagePath(_ path: String) -> Bool {
        guard let type = UTType(filenameExtension: (path as NSString).pathExtension) else {
            return false
        }
        return type.conforms(to: .image)
    }

    /// "Image (1200 × 1000)", "Two Mangos.png (640 × 427)", the first line of text.
    static func title(
        of entry: LauncherView.ClipboardEntry, pixelSize: CGSize? = nil
    ) -> String {
        let dims = pixelSize.map { " (\(Int($0.width)) × \(Int($0.height)))" } ?? ""
        if let first = entry.filePaths.first {
            let name = URL(fileURLWithPath: first).lastPathComponent
            let more = entry.filePaths.count > 1 ? " + \(entry.filePaths.count - 1) more" : ""
            return name + (entry.filePaths.count == 1 ? dims : more)
        }
        if kind(of: entry) == .image { return "Image" + dims }
        let line = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty ? "Clipboard Item" : line
    }

    /// The Information section, top to bottom.
    static func details(
        of entry: LauncherView.ClipboardEntry, pixelSize: CGSize? = nil, now: Date = Date()
    ) -> [(label: String, value: String)] {
        var rows: [(String, String)] = []
        rows.append(("Application", entry.sourceAppName.isEmpty ? "Unknown" : entry.sourceAppName))
        rows.append(("Content Type", kind(of: entry).label))
        if let first = entry.filePaths.first {
            rows.append(("Path", (first as NSString).abbreviatingWithTildeInPath))
        }
        if let pixelSize {
            rows.append(("Dimensions", "\(Int(pixelSize.width)) × \(Int(pixelSize.height))"))
        }
        if entry.filePaths.isEmpty, kind(of: entry) != .image {
            let text = entry.text
            rows.append(("Characters", "\(text.count)"))
            let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            rows.append(("Words", "\(words)"))
        }
        rows.append(("Copied", copiedText(entry.timestamp, now: now)))
        return rows
    }

    static func copiedText(_ date: Date, now: Date = Date()) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        return "\(dayTitle(for: date, now: now)) at \(time)"
    }

    /// The list's section headers: Today, Yesterday, then the date.
    static func dayTitle(for date: Date, now: Date = Date(), calendar: Calendar = .current)
        -> String
    {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "Yesterday"
        }
        return date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    /// The image's own pixels, not the points AppKit would draw it at.
    static func pixelSize(of data: Data) -> CGSize? {
        guard let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 0, rep.pixelsHigh > 0
        else { return nil }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}

// MARK: - Keys

/// What a key means while the board is open. Taken by the shell's key monitor before the
/// field sees it, so the arrows walk the clips instead of the caret and Return pastes
/// instead of asking a question.
enum ClipboardBoardKey: Equatable {
    /// Esc, or ← / Backspace on an empty filter: back to what the field was before.
    case back
    /// Esc with something typed: the filter goes first, the board second.
    case clearFilter
    case move(Int, selecting: Bool)
    /// Return: paste into the app the user came from.
    case paste
    /// ⌘Return: put it on the pasteboard and stop there.
    case copy
    /// ⌘Backspace: forget the clip.
    case delete
    /// ⌘Y: Quick Look.
    case quickLook
    /// Tab / ⇧Tab: the type filter.
    case cycleKind(Int)

    static func action(
        keyCode: UInt16, command: Bool, shift: Bool, option: Bool, control: Bool,
        filterEmpty: Bool
    ) -> ClipboardBoardKey? {
        guard !option, !control else { return nil }
        switch keyCode {
        case 53: return filterEmpty ? .back : .clearFilter  // Esc
        case 126: return .move(-1, selecting: shift || command)  // ↑
        case 125: return .move(1, selecting: shift || command)  // ↓
        case 36, 76: return command ? .copy : .paste  // Return, Enter
        case 48: return command ? nil : .cycleKind(shift ? -1 : 1)  // Tab
        case 51:  // Backspace
            if command { return .delete }
            return filterEmpty && !shift ? .back : nil
        case 123: return filterEmpty && !command && !shift ? .back : nil  // ←
        case 16: return command ? .quickLook : nil  // Y
        default: return nil
        }
    }
}

// MARK: - Sections

/// One day of clips in the list.
struct ClipboardBoardSection: Identifiable, Equatable {
    struct Row: Identifiable, Equatable {
        /// Where the clip sits in `visibleEntries`: what the keys move and Return reads.
        let index: Int
        let entry: LauncherView.ClipboardEntry
        var id: UUID { entry.id }

        static func == (lhs: Row, rhs: Row) -> Bool {
            lhs.index == rhs.index && lhs.entry.id == rhs.entry.id
        }
    }

    let title: String
    var rows: [Row]
    var id: String { title }

    /// Consecutive clips from the same day share a section; history is newest first, so
    /// that is one section per day.
    static func group(_ entries: [LauncherView.ClipboardEntry], now: Date) -> [ClipboardBoardSection] {
        var result: [ClipboardBoardSection] = []
        for (index, entry) in entries.enumerated() {
            let title = ClipboardClipInfo.dayTitle(for: entry.timestamp, now: now)
            let row = Row(index: index, entry: entry)
            if result.last?.title == title {
                result[result.count - 1].rows.append(row)
            } else {
                result.append(ClipboardBoardSection(title: title, rows: [row]))
            }
        }
        return result
    }
}

// MARK: - The board

enum ClipboardBoardMetrics {
    static let headerHeight: CGFloat = 36
    static let footerHeight: CGFloat = 38
    static let height: CGFloat = 380

    static var size: CGSize { CGSize(width: DockShellWidth.current, height: height) }
}

struct ClipboardBoardCard: View {
    @ObservedObject var model: ClipboardPanelModel

    private var size: CGSize { ClipboardBoardMetrics.size }

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            HStack(alignment: .top, spacing: 0) {
                list
                    .frame(width: CornerBoardLayout.listWidth(
                        board: size.width, preview: .file(URL(fileURLWithPath: "/"))))
                Color.clear.frame(width: CornerBoardLayout.dividerWidth)
                preview
                    .frame(width: CornerBoardLayout.panelWidth(board: size.width))
                    .padding(.vertical, 8)
                    .padding(.trailing, 8)
            }
            .frame(maxHeight: .infinity)
            hairline
            footer
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.clear)
                .background(GlassBackground(cornerRadius: 22, isDark: true))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.34), radius: 20, y: 10)
        }
    }

    private var hairline: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Clipboard History")
                .font(.system(size: 12, weight: .semibold))
            Text("\(model.visibleEntries.count)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Menu {
                ForEach(ClipboardKindFilter.allCases) { kind in
                    Button {
                        model.setKind(kind)
                    } label: {
                        if kind == model.kindFilter {
                            Label(kind.label, systemImage: "checkmark")
                        } else {
                            Text(kind.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(model.kindFilter.label)
                        .font(.system(size: 11.5, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.1)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Filter by type (Tab)")
        }
        .padding(.horizontal, 16)
        .frame(height: ClipboardBoardMetrics.headerHeight)
    }

    // MARK: List

    /// The visible clips grouped by day, each keeping its index in `visibleEntries` — the
    /// index the keys move and Return reads.
    private var sections: [ClipboardBoardSection] {
        ClipboardBoardSection.group(model.visibleEntries, now: Date())
    }

    @ViewBuilder
    private var list: some View {
        if model.visibleEntries.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 20))
                    .foregroundStyle(.tertiary)
                Text(model.entries.isEmpty ? "Nothing copied yet" : "No matching clips")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(sections) { section in
                            Text(section.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                            ForEach(section.rows) { row in
                                ClipboardBoardRow(
                                    entry: row.entry,
                                    isFocused: row.index == model.focusedEntryIndex,
                                    isSelected: model.isSelected(row.entry)
                                )
                                .id(row.entry.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    model.focusedEntryIndex = row.index
                                    ClipboardPanelController.shared.pasteMany(
                                        model.actionableEntries(fallback: row.entry))
                                }
                                .onTapGesture {
                                    model.focusedEntryIndex = row.index
                                    let flags = NSEvent.modifierFlags
                                    if flags.contains(.command) || flags.contains(.shift) {
                                        model.selectEntry(
                                            row.entry, extend: flags.contains(.shift),
                                            toggle: flags.contains(.command))
                                    } else {
                                        model.clearSelection()
                                    }
                                }
                                .contextMenu { rowMenu(row.entry) }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .onChange(of: model.focusedEntryIndex) { _, index in
                    guard let index, model.visibleEntries.indices.contains(index) else { return }
                    proxy.scrollTo(model.visibleEntries[index].id)
                }
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ entry: LauncherView.ClipboardEntry) -> some View {
        let controller = ClipboardPanelController.shared
        Button("Paste into \(controller.returnAppName)") {
            controller.pasteMany(model.actionableEntries(fallback: entry))
        }
        Button("Copy to Clipboard") {
            controller.copy(model.actionableEntries(fallback: entry))
            controller.finishBoard()
        }
        Divider()
        Button("Quick Look") {
            if let index = model.visibleEntries.firstIndex(where: { $0.id == entry.id }) {
                model.focusedEntryIndex = index
            }
            controller.preview()
        }
        Divider()
        Button("Delete", role: .destructive) {
            model.removeActionableEntries(fallback: entry)
        }
    }

    // MARK: Preview

    @ViewBuilder
    private var preview: some View {
        if let entry = model.focusedEntry {
            ClipboardBoardPreview(entry: entry)
                .id(entry.id)
                .boardPanelCard()
        } else {
            Color.clear.boardPanelCard()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 5))
            Text("Clipboard History")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            footerAction("Paste to \(ClipboardPanelController.shared.returnAppName)", keys: ["↩"])
            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 14)
            footerAction("Copy", keys: ["⌘", "↩"], dimmed: true)
        }
        .padding(.horizontal, 14)
        .frame(height: ClipboardBoardMetrics.footerHeight)
    }

    private func footerAction(_ title: String, keys: [String], dimmed: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(dimmed ? Color.secondary : Color.primary)
                .lineLimit(1)
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}

/// One clip in the list: its picture or kind, its title, and where it came from.
private struct ClipboardBoardRow: View {
    let entry: LauncherView.ClipboardEntry
    let isFocused: Bool
    let isSelected: Bool

    var body: some View {
        let data = ClipboardScopeService.imageData(for: entry)
        HStack(spacing: 10) {
            thumbnail(data)
                .frame(width: 28, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(ClipboardClipInfo.title(of: entry, pixelSize: data.flatMap { ClipboardClipInfo.pixelSize(of: $0) }))
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            isFocused ? Color.primary.opacity(0.11) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func thumbnail(_ data: Data?) -> some View {
        if let data, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFill()
        } else if let first = entry.filePaths.first {
            Image(nsImage: NSWorkspace.shared.icon(forFile: first)).resizable().scaledToFit()
        } else {
            Image(systemName: ClipboardClipInfo.kind(of: entry) == .link ? "link" : "text.alignleft")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.06))
        }
    }
}

/// The chosen clip: the picture, the text or the file, then its Information section.
private struct ClipboardBoardPreview: View {
    let entry: LauncherView.ClipboardEntry

    var body: some View {
        let data = ClipboardScopeService.imageData(for: entry)
            ?? entry.filePaths.first.flatMap { ClipboardClipInfo.isImagePath($0) ? FileManager.default.contents(atPath: $0) : nil }
        let pixels = data.flatMap { ClipboardClipInfo.pixelSize(of: $0) }
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                content(data)
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .background(Color.black.opacity(0.18))
                Text("Information")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                ForEach(
                    Array(ClipboardClipInfo.details(of: entry, pixelSize: pixels).enumerated()),
                    id: \.offset
                ) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(item.element.label)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(item.element.value)
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
                            .padding(.horizontal, 14)
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func content(_ data: Data?) -> some View {
        if let data, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(8)
        } else if !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ScrollView {
                Text(entry.text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
        } else if let first = entry.filePaths.first {
            VStack(spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: first))
                    .resizable()
                    .frame(width: 56, height: 56)
                Text(URL(fileURLWithPath: first).lastPathComponent)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 12)
            }
        } else {
            Text("Nothing to preview")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }
}
