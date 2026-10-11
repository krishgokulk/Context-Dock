// CornerPinPreviewCard.swift
// Context-Dock
//
// The hovered pin, shown. The app half of this hover is `CornerWindowRow`; this is the
// other half, in the same slot, at the same dwell, so the strip answers the pointer
// wherever it rests rather than only over the apps.

import AppKit
import SwiftUI

struct CornerPinPreviewCard: View {
    let pin: DockPin
    @ObservedObject var model: AppChatPromptModel
    @ObservedObject private var service = DockPinPreviewService.shared

    private typealias M = DockPinPreviewMetrics

    var body: some View {
        let preview = service.preview(for: pin)
        Group {
            switch preview {
            case .file(let detail): file(detail)
            case .folder(let peek): folder(peek)
            case .document(let detail): document(detail)
            case .missing(let name, let reason):
                message(symbol: "questionmark.circle", title: name, detail: reason)
            case nil:
                message(symbol: pin.kind.fallbackSymbol, title: pin.title, detail: "Reading…")
            }
        }
        .padding(M.inset)
        // The card is exactly its slot. It used to take the file card's width whatever it
        // showed, so a folder's 360 pt slot held a 260 pt card with 50 pt of glass either
        // side of it.
        .frame(
            width: size(preview).width,
            height: size(preview).height)
        // The card is part of the target: crossing from the icon onto it must not count as
        // leaving, or it would vanish under the pointer.
        .onHover { inside in model.windowRowHovered(inside) }
        .onAppear { refresh() }
        .onChange(of: pin.id) { _, _ in refresh() }
    }

    private func size(_ preview: DockPinPreview?) -> CGSize {
        M.size(
            for: preview ?? .missing(name: pin.title, reason: ""),
            expanded: model.pinPreviewExpanded)
    }

    private func refresh() {
        service.refresh(
            pin: pin,
            document: pin.documentID.flatMap { GlobalSearchService.shared.document(withID: $0) })
    }

    // MARK: Kinds

    private func file(_ detail: DockPinPreview.FileDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                if let image = service.thumbnail(for: detail.path) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: M.thumb.width, height: M.thumb.height)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    // The file's own icon while QuickLook is still drawing it: something
                    // that is already true rather than a spinner.
                    Image(nsImage: NSWorkspace.shared.icon(forFile: detail.path))
                        .resizable()
                        .frame(width: 48, height: 48)
                }
            }
            .frame(width: M.thumb.width, height: M.thumb.height)
            Spacer(minLength: 6)
            Text(detail.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(height: M.titleHeight, alignment: .leading)
            Text(Self.fileDetailLine(detail))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: M.detailHeight, alignment: .leading)
        }
        .frame(width: M.thumb.width, alignment: .leading)
    }

    /// The folder the app already knows how to show: list or grid, keyboard selection,
    /// drag out, walk into a subfolder. A dock preview that listed a folder its own way
    /// would be a second answer to a question this app has already answered.
    private func folder(_ detail: DockPinPreview.FolderDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: detail.path))
                    .resizable()
                    .frame(width: 15, height: 15)
                Text(detail.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                // The same two controls, drawn the same way, as the clipboard card's header.
                Button { model.togglePinPreviewExpanded() } label: {
                    headerGlyph(
                        model.pinPreviewExpanded
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.plain)
                .help(model.pinPreviewExpanded ? "Make the preview smaller" : "Expand the preview")
                Button { model.togglePinPreviewPinned(pin.id) } label: {
                    headerGlyph(isPinned ? "pin.fill" : "pin", tinted: isPinned)
                }
                .buttonStyle(.plain)
                .help(isPinned ? "Unpin preview" : "Pin preview — keep it open")
            }
            .frame(height: M.headerHeight)
            PreviewFolderBrowser(url: URL(fileURLWithPath: detail.path))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var isPinned: Bool { model.pinnedPreviewPinID == pin.id }

    private func headerGlyph(_ symbol: String, tinted: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tinted ? Color.accentColor : .secondary)
            .frame(width: 22, height: 22)
            .background(tinted ? Color.accentColor.opacity(0.18) : Color.clear, in: Circle())
            .contentShape(Circle())
    }

    private func document(_ detail: DockPinPreview.DocumentDetail) -> some View {
        message(symbol: detail.symbol, title: detail.title, detail: detail.subtitle ?? "")
    }

    private func message(symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "PDF document · 2.3 MB · Yesterday" — and it drops whichever of those the disk did
    /// not answer, rather than printing a zero or a 1970 date.
    static func fileDetailLine(_ detail: DockPinPreview.FileDetail) -> String {
        var parts: [String] = [detail.kindName]
        if let bytes = detail.byteCount {
            parts.append(
                ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        if let modified = detail.modified {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            parts.append(formatter.localizedString(for: modified, relativeTo: Date()))
        }
        return parts.joined(separator: " · ")
    }
}
