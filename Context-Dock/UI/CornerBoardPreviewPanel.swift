// CornerBoardPreviewPanel.swift
// Context-Dock
//
// The split board's right column (#191): what the highlighted row is, shown — a file's
// preview, an app, a menu command. It follows the arrows; it never takes the keys.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CornerBoardPreviewPanel: View {
    let preview: CornerBoardPreview
    let height: CGFloat

    var body: some View {
        Group {
            switch preview {
            case .file(let url): FilePreview(url: url)
            case .app(let bundleID, let name): AppPreview(bundleID: bundleID, name: name)
            case .command(let title, let path, let appName, let bundleID):
                CommandPreview(title: title, path: path, appName: appName, bundleID: bundleID)
            }
        }
        // A new row is a new panel, so its preview never shows the last row's for a frame.
        .id(preview)
        .padding(16)
        .frame(width: CornerBoardLayout.panelWidth, height: height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background {
            // The list card's own glass, so the two columns read as one board.
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
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
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
        VStack(alignment: .leading, spacing: 10) {
            if isFolder {
                header(icon: NSWorkspace.shared.icon(forFile: url.path))
                FolderListing(url: url)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                    Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(thumbnail == nil ? 36 : 6)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                Text(url.lastPathComponent)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                facts
            }
            Spacer(minLength: 0)
        }
        .onAppear(perform: loadThumbnail)
    }

    private func header(icon: NSImage) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: icon).resizable().frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(Self.displayPath(url.deletingLastPathComponent()))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var facts: some View {
        let values = try? url.resourceValues(forKeys: [
            .localizedTypeDescriptionKey, .fileSizeKey, .contentModificationDateKey,
        ])
        return VStack(alignment: .leading, spacing: 4) {
            if let kind = values?.localizedTypeDescription {
                fact("Kind", kind)
            }
            if let size = values?.fileSize {
                fact("Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
            }
            if let date = values?.contentModificationDate {
                fact("Modified", date.formatted(date: .abbreviated, time: .shortened))
            }
            fact("Where", Self.displayPath(url.deletingLastPathComponent()))
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func loadThumbnail() {
        let path = url.path
        ThumbnailGenerator.shared.getThumbnail(
            for: path, size: CGSize(width: 600, height: 300)
        ) { image in
            DispatchQueue.main.async {
                if url.path == path { thumbnail = image }
            }
        }
    }

    /// `~/Documents/Work` rather than `/Users/name/Documents/Work`.
    static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return path.hasPrefix(home) ? "~" + String(path.dropFirst(home.count)) : path
    }
}

/// A folder's first few items, folders first — what Finder would show at the top.
private struct FolderListing: View {
    let url: URL
    private static let limit = 9

    var body: some View {
        let items = Self.items(in: url)
        VStack(alignment: .leading, spacing: 6) {
            if items.isEmpty {
                Text("Empty folder")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            ForEach(items.prefix(Self.limit), id: \.self) { item in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                        .resizable()
                        .frame(width: 18, height: 18)
                    Text(item.lastPathComponent)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if items.count > Self.limit {
                Text("+\(items.count - Self.limit) more")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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

    private var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    private var running: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Group {
                    if let appURL {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                            .resizable()
                    } else {
                        Image(systemName: "app.dashed").resizable()
                    }
                }
                .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(running == nil ? Color.secondary.opacity(0.4) : .green)
                            .frame(width: 6, height: 6)
                        Text(running == nil ? "Not running" : "Running")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let appURL, let bundle = Bundle(url: appURL) {
                VStack(alignment: .leading, spacing: 4) {
                    if let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                        as? String
                    {
                        row("Version", version)
                    }
                    row("Where", FilePreview.displayPath(appURL.deletingLastPathComponent()))
                }
            }
            Text(running == nil ? "↩ opens it" : "↩ brings it forward · → steps into it")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Command

private struct CommandPreview: View {
    let title: String
    let path: [String]
    let appName: String
    let bundleID: String

    private var appIcon: NSImage? {
        guard !bundleID.isEmpty,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let appIcon {
                    Image(nsImage: appIcon).resizable().frame(width: 36, height: 36)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                    if !appName.isEmpty {
                        Text(appName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // Where it lives: the menu path, the way the menu bar would lead you there.
            Text(([appName].filter { !$0.isEmpty } + path).joined(separator: "  ▸  "))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Text("↩ runs it")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}
