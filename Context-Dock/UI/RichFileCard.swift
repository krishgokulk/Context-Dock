//
//  RichFileCard.swift
//  Rich card for a local file shown in a chat answer: icon, name, metadata and
//  "Open in {Default App}". Every button is a direct AppKit call, never the provider.
//

import SwiftUI
import AppKit

/// Pure display model for `RichFileCard`. No NSWorkspace, no disk access: the caller
/// injects the default app name, size, date and home directory so tests stay offline.
struct RichFileCardModel: Equatable {
    let url: URL
    let defaultAppName: String?
    let byteCount: Int64?
    let modified: Date?
    let homeDirectory: String
    let exists: Bool

    var name: String { url.lastPathComponent }

    /// "Open in Preview", or plain "Open" when no default app is known.
    var openLabel: String {
        guard let app = defaultAppName, !app.isEmpty else { return "Open" }
        return "Open in \(app)"
    }

    /// Containing folder with the home directory shown as `~`.
    var folderDisplay: String {
        let folder = url.deletingLastPathComponent().path
        guard !homeDirectory.isEmpty else { return folder }
        if folder == homeDirectory { return "~" }
        if folder.hasPrefix(homeDirectory + "/") {
            return "~" + folder.dropFirst(homeDirectory.count)
        }
        return folder
    }

    var sizeDisplay: String? {
        byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    var dateDisplay: String? {
        modified.map { $0.formatted(.dateTime.year().month(.abbreviated).day()) }
    }

    /// "1.2 MB · ~/Documents · Nov 10, 2026"; a missing file says so instead.
    var metadataLine: String {
        guard exists else { return "\(folderDisplay) · File not found" }
        return [sizeDisplay, folderDisplay, dateDisplay].compactMap { $0 }.joined(separator: " · ")
    }

    /// Reads the live file system once, for the view. Tests build the model directly.
    static func live(url: URL) -> RichFileCardModel {
        let exists = FileManager.default.fileExists(atPath: url.path)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return RichFileCardModel(
            url: url,
            defaultAppName: exists ? DefaultAppResolver.shared.getDefaultApp(for: url)?.displayName : nil,
            byteCount: values?.fileSize.map(Int64.init),
            modified: values?.contentModificationDate,
            homeDirectory: NSHomeDirectory(),
            exists: exists
        )
    }
}

struct RichFileCard: View {
    let url: URL
    var onPreview: ((URL) -> Void)?

    /// Read once per file, not on every re-render of the transcript: the default-app
    /// lookup and the disk read are too slow for a view initialiser.
    @State private var loaded: RichFileCardModel?
    @State private var appIcon: NSImage?
    @State private var fileIcon: NSImage?

    private var model: RichFileCardModel {
        loaded ?? RichFileCardModel(
            url: url, defaultAppName: nil, byteCount: nil, modified: nil,
            homeDirectory: NSHomeDirectory(), exists: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(nsImage: fileIcon ?? NSWorkspace.shared.icon(forFile: model.url.path))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(model.metadataLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Button {
                    NSWorkspace.shared.open(model.url)
                } label: {
                    HStack(spacing: 4) {
                        if let appIcon {
                            Image(nsImage: appIcon).resizable().frame(width: 12, height: 12)
                        }
                        Text(model.openLabel).lineLimit(1)
                    }
                }
                .help("\(model.openLabel): \(model.name)")
                .accessibilityLabel("\(model.openLabel), \(model.name)")
                if let onPreview {
                    Button("Quick Look \(model.name)", systemImage: "eye") {
                        onPreview(model.url)
                    }
                    .labelStyle(.iconOnly)
                    .help("Quick Look \(model.name) beside this chat")
                }
                Button("Reveal \(model.name) in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.url])
                }
                .labelStyle(.iconOnly)
                .help("Reveal \(model.name) in Finder")
                Spacer(minLength: 0)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(!model.exists)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .contain)
        .task(id: url) {
            let live = RichFileCardModel.live(url: url)
            loaded = live
            appIcon = live.exists ? DefaultAppResolver.shared.getDefaultApp(for: url)?.icon : nil
            fileIcon = NSWorkspace.shared.icon(forFile: url.path)
        }
    }
}
