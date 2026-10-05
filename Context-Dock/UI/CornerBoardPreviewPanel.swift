// CornerBoardPreviewPanel.swift
// Context-Dock
//
// The split board's right half (#191): what the highlighted row is, shown — a file's
// preview, an app, a menu command — as an inset card inside the list's own card, laid out
// the way Claude's Progress panel is (owner 2026-10-05): a header, hairlines, titled
// sections, and rows of an icon, a name and a dimmed trailing kind. It follows the arrows;
// it never takes the keys.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CornerBoardPreviewPanel: View {
    let preview: CornerBoardPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch preview {
            case .file(let url): FilePreview(url: url)
            case .app(let bundleID, let name): AppPreview(bundleID: bundleID, name: name)
            case .command(let title, let path, let appName, let bundleID):
                CommandPreview(title: title, path: path, appName: appName, bundleID: bundleID)
            }
            Spacer(minLength: 0)
        }
        // A new row is a new card, so it never shows the last row's contents for a frame.
        .id(preview)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            // Inset in the board's glass: a shade lifted, a hairline edge — a card, not a pane.
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.trailing, 10)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The card's parts, shared by every kind

/// The card's title line: what this is, and one dimmed line under it.
private struct PanelHeader: View {
    let icon: NSImage?
    let title: String
    let subtitle: String
    var status: Color? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 30, height: 30)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    if let status {
                        Circle().fill(status).frame(width: 6, height: 6)
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 10)
    }
}

/// The hairline between sections.
private struct PanelDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(height: 1)
            .padding(.vertical, 8)
    }
}

/// A section's name, as Claude titles "Context" or "Outputs".
private struct PanelSection: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .padding(.bottom, 6)
    }
}

/// One line of a section: an icon or a label, a name, and a dimmed trailing kind.
private struct PanelRow: View {
    var icon: NSImage? = nil
    var symbol: String? = nil
    var label: String? = nil
    let value: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 16, height: 16)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            if let label {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
            }
            Text(value)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .frame(height: 24)
    }
}

/// `~/Documents/Work` rather than `/Users/name/Documents/Work`.
private func boardPanelPath(_ url: URL) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let path = url.path
    return path.hasPrefix(home) ? "~" + String(path.dropFirst(home.count)) : path
}

/// A file's kind the way Claude labels it: its extension, upper-cased, or "Folder".
private func boardPanelKind(_ url: URL) -> String {
    if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
        url.pathExtension != "app"
    {
        return "Folder"
    }
    return url.pathExtension.isEmpty ? "File" : url.pathExtension.uppercased()
}

// MARK: - File

private struct FilePreview: View {
    let url: URL
    @State private var thumbnail: NSImage?

    private var isFolder: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            && url.pathExtension != "app"
    }

    var body: some View {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(
                icon: icon, title: url.lastPathComponent,
                subtitle: boardPanelPath(url.deletingLastPathComponent()))
            if isFolder {
                PanelDivider()
                FolderListing(url: url)
            } else {
                // The file itself, as Quick Look draws it.
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.18))
                    Image(nsImage: thumbnail ?? icon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(thumbnail == nil ? 28 : 6)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 118)
                PanelDivider()
                PanelSection(title: "Details")
                details
            }
        }
        .onAppear(perform: loadThumbnail)
    }

    private var details: some View {
        let values = try? url.resourceValues(forKeys: [
            .localizedTypeDescriptionKey, .fileSizeKey, .contentModificationDateKey,
        ])
        return VStack(alignment: .leading, spacing: 0) {
            if let kind = values?.localizedTypeDescription {
                PanelRow(label: "Kind", value: kind, trailing: boardPanelKind(url))
            }
            if let size = values?.fileSize {
                PanelRow(
                    label: "Size",
                    value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
            }
            if let date = values?.contentModificationDate {
                PanelRow(
                    label: "Modified", value: date.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private func loadThumbnail() {
        guard !isFolder else { return }
        let path = url.path
        ThumbnailGenerator.shared.getThumbnail(
            for: path, size: CGSize(width: 560, height: 240)
        ) { image in
            DispatchQueue.main.async {
                if url.path == path { thumbnail = image }
            }
        }
    }
}

/// A folder's first items, folders first — each a row with its kind, as Claude lists files.
private struct FolderListing: View {
    let url: URL
    private static let limit = 7

    var body: some View {
        let items = Self.items(in: url)
        VStack(alignment: .leading, spacing: 0) {
            PanelSection(title: items.isEmpty ? "Empty folder" : "\(items.count) items")
            ForEach(items.prefix(Self.limit), id: \.self) { item in
                PanelRow(
                    icon: NSWorkspace.shared.icon(forFile: item.path),
                    value: item.lastPathComponent, trailing: boardPanelKind(item))
            }
            if items.count > Self.limit {
                Text("+\(items.count - Self.limit) more")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    static func items(in url: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return contents.sorted { a, b in
            let aDir = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let bDir = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if aDir != bDir { return aDir }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent)
                == .orderedAscending
        }
    }
}

// MARK: - App

private struct AppPreview: View {
    let bundleID: String
    let name: String

    var body: some View {
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        let bundle = appURL.flatMap { Bundle(url: $0) }
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(
                icon: appURL.map { NSWorkspace.shared.icon(forFile: $0.path) },
                title: name,
                subtitle: running == nil ? "Not running" : "Running",
                status: running == nil ? Color.secondary.opacity(0.5) : .green)
            PanelDivider()
            PanelSection(title: "Details")
            if let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String
            {
                PanelRow(label: "Version", value: version)
            }
            if let appURL {
                PanelRow(label: "Where", value: boardPanelPath(appURL.deletingLastPathComponent()))
            }
            PanelDivider()
            PanelSection(title: "Actions")
            PanelRow(
                symbol: "return", value: running == nil ? "Open" : "Bring forward", trailing: "↩")
            if running != nil {
                PanelRow(symbol: "arrow.right", value: "Step into its Context Dock", trailing: "→")
            }
        }
    }
}

// MARK: - Command

private struct CommandPreview: View {
    let title: String
    let path: [String]
    let appName: String
    let bundleID: String

    var body: some View {
        let appIcon: NSImage? = {
            guard !bundleID.isEmpty,
                let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        }()
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(
                icon: appIcon, title: title,
                subtitle: appName.isEmpty ? "Menu command" : "\(appName) menu command")
            PanelDivider()
            // Where it lives: one row per menu level, the way the menu bar leads there.
            PanelSection(title: "Menu")
            ForEach(Array(path.enumerated()), id: \.offset) { index, step in
                PanelRow(
                    symbol: index == path.count - 1 ? "command" : "chevron.right",
                    value: step)
            }
            PanelDivider()
            PanelRow(symbol: "return", value: "Run it", trailing: "↩")
        }
    }
}
