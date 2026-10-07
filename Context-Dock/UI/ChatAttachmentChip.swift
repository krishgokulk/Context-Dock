// ChatAttachmentChip.swift
// Context-Dock
//
// One attached file, drawn the way the chat apps draw them: a thumbnail, a name that stays
// readable, and what the thing actually is.
//
// Both corner composers used to print the raw last path component in a capsule, so a
// screenshot arrived as "context-dock-shot-3C4352FB-9F85-498D-B3CB-43195DEB7E10.png" —
// forty characters of UUID pushing the useful part off the end, with nothing to say whether
// it was an image or a spreadsheet.

import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct ChatAttachmentChip: View {
    /// How the attachment is drawn.
    ///
    /// `.compact` is the one-line chip the selection row uses, where it sits beside a text
    /// chip of the same shape. `.tile` is how the chat apps show a file you are about to
    /// send, or just sent: an image is the picture itself, and anything else is a small card
    /// with its icon, name and kind — the remove button rides on the corner, not in the row.
    enum Style: Equatable {
        case compact
        case tile(side: CGFloat)

        static let composerTile = Style.tile(side: 60)
        static let messageTile = Style.tile(side: 84)
    }

    let url: URL
    var style: Style = .compact
    var onRemove: (() -> Void)?

    @State private var thumbnail: NSImage?
    @State private var isHovered = false

    /// Middle-truncated, because both ends carry meaning: the name the user recognises is
    /// at the front and the extension that says what it is is at the back. A tail-truncated
    /// screenshot name is all prefix and no answer.
    private var displayName: String {
        let name = url.lastPathComponent
        guard name.count > 26 else { return name }
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.count > 18 else { return name }
        let head = stem.prefix(11)
        let tail = stem.suffix(4)
        return ext.isEmpty ? "\(head)…\(tail)" : "\(head)…\(tail).\(ext)"
    }

    private var kindLabel: String {
        let ext = url.pathExtension.uppercased()
        if let size = fileSize { return ext.isEmpty ? size : "\(ext) · \(size)" }
        return ext.isEmpty ? "File" : ext
    }

    private var fileSize: String? {
        guard
            let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
            let bytes = values.fileSize
        else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var isImage: Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    private var thumbnailSide: CGFloat {
        switch style {
        case .compact: return 28
        case .tile(let side): return side
        }
    }

    var body: some View {
        Group {
            switch style {
            case .compact: compactBody
            case .tile(let side): tileBody(side: side)
            }
        }
        .onHover { isHovered = $0 }
        .help(url.lastPathComponent)
        .task(id: url) { await loadThumbnail() }
    }

    private var compactBody: some View {
        HStack(spacing: 8) {
            preview
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Text(kindLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .opacity(isHovered ? 1 : 0.45)
                }
                .buttonStyle(.plain)
                .help("Remove attachment")
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(
            Color.primary.opacity(isHovered ? 0.12 : 0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    /// An image is the picture, square-cropped; anything else is a card as tall as an
    /// image tile so a row of mixed attachments keeps one baseline.
    private func tileBody(side: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Group {
            if isImage {
                preview
                    .frame(width: side, height: side)
                    .background(Color.primary.opacity(0.06))
            } else {
                HStack(spacing: 8) {
                    preview
                        .frame(width: side * 0.5, height: side * 0.5)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Text(kindLabel)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: 120, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .frame(height: side)
                .background(Color.primary.opacity(isHovered ? 0.12 : 0.08))
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Color.black.opacity(0.72), in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .padding(4)
                // Shown on hover, as in the chat apps — a permanent ✕ over every picture
                // covers the corner of the thing the user is checking before they send.
                .opacity(isHovered ? 1 : 0)
                .help("Remove attachment")
                .accessibilityLabel("Remove \(url.lastPathComponent)")
            }
        }
        .contentShape(shape)
    }

    @ViewBuilder
    private var preview: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            // The system icon is instant and always right about the kind, so it holds the
            // space while the real thumbnail is produced rather than a spinner or a gap.
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(3)
        }
    }

    /// Quick Look gives the picture a document actually has — the first page of a PDF, the
    /// image itself — rather than the generic icon for its type.
    private func loadThumbnail() async {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let side = thumbnailSide * 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: scale,
            representationTypes: .thumbnail)
        guard
            let representation = try? await QLThumbnailGenerator.shared
                .generateBestRepresentation(for: request)
        else { return }
        thumbnail = representation.nsImage
    }
}
