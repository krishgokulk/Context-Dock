// DropShelfPill.swift
// Context-Dock
//
// The Drop Shelf's pill and card. Same shell, metrics, and morph as the clipboard pill,
// because the corner should read as one place with two things in it rather than two
// widgets that happen to be near each other. The window never resizes — the morph is a
// SwiftUI frame change inside a fixed transparent panel.

import AppKit
import SwiftUI

struct DropShelfPill: View {
    @ObservedObject var presentation: DropShelfPresentation
    @ObservedObject var store: DropShelfStore

    private var expanded: Bool { presentation.phase == .expanded }
    private var cardSize: CGSize { DropShelfMetrics.cardSize(for: presentation.phase) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            collapsedContent.opacity(expanded ? 0 : 1)
            expandedContent.opacity(expanded ? 1 : 0)
        }
        .frame(width: cardSize.width, height: cardSize.height, alignment: .bottomLeading)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.clear)
                .background(GlassBackground(cornerRadius: 22, isDark: true))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(
                            presentation.phase == .inviting
                                ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.16),
                            lineWidth: presentation.phase == .inviting ? 2 : 1)
                )
                .shadow(color: .black.opacity(0.34), radius: 20, y: 10)
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: presentation.phase)
    }

    // MARK: - Collapsed

    private var collapsedContent: some View {
        HStack(spacing: 10) {
            Image(systemName: presentation.phase == .inviting ? "tray.and.arrow.down.fill" : "tray.full.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(presentation.phase == .inviting ? Color.accentColor : .secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(presentation.phase == .inviting ? "Drop to Shelf" : "Shelf")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if !store.items.isEmpty {
                Text("\(store.items.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.09), in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .frame(
            width: DropShelfMetrics.collapsedSize.width,
            height: DropShelfMetrics.collapsedSize.height)
    }

    private var subtitle: String {
        if presentation.phase == .inviting { return "Files, text, or links" }
        return store.items.count == 1 ? "1 item held" : "\(store.items.count) items held"
    }

    // MARK: - Expanded

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            rows
            Divider().opacity(0.2)
            footer
        }
        .frame(
            width: DropShelfMetrics.expandedSize.width,
            height: DropShelfMetrics.expandedSize.height)
    }

    private var rows: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(store.items) { item in
                    row(item)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ item: DropShelfItem) -> some View {
        HStack(spacing: 10) {
            icon(for: item)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.originalName)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(subtitle(for: item))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                DropShelfController.shared.remove(item)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from shelf")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            presentation.isSelected(item)
                ? Color.accentColor.opacity(0.24) : Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            if presentation.isSelected(item) {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            presentation.select(
                item, in: store.items,
                extend: flags.contains(.shift), toggle: flags.contains(.command))
        }
        // Dragging out is a read: the items stay on the shelf. A selected row drags the
        // whole selection — dragging four files out one at a time is the slow way to do
        // the only thing this surface is for.
        .onDrag {
            let dragged = presentation.isSelected(item)
                ? presentation.actionableItems(in: store.items, fallback: item)
                : [item]
            DropShelfController.shared.beginDrag()
            let providers = dragged.compactMap {
                NSItemProvider(contentsOf: store.url(for: $0))
            }
            return providers.first ?? NSItemProvider()
        } preview: {
            dragPreview(for: presentation.isSelected(item)
                ? presentation.actionableItems(in: store.items, fallback: item)
                : [item])
        }
        .contextMenu {
            Button("Reveal in Finder") { DropShelfController.shared.reveal(item) }
            Button(presentation.isSelected(item) ? "Deselect" : "Select") {
                presentation.select(item, in: store.items, extend: false, toggle: true)
            }
            Button("Select All") { presentation.selectAll(store.items) }
            Divider()
            Button("Remove from Shelf", role: .destructive) {
                for doomed in presentation.actionableItems(in: store.items, fallback: item) {
                    DropShelfController.shared.remove(doomed)
                }
                presentation.clearSelection()
            }
        }
    }

    /// A stack with a count, so a four-file drag does not look like a one-file drag.
    private func dragPreview(for items: [DropShelfItem]) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { offset, item in
                icon(for: item)
                    .offset(x: CGFloat(offset) * 6, y: CGFloat(offset) * 6)
            }
        }
        .padding(6)
        .overlay(alignment: .bottomTrailing) {
            if items.count > 1 {
                Text("\(items.count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
            }
        }
    }

    private func subtitle(for item: DropShelfItem) -> String {
        let when = item.droppedAt.formatted(.relative(presentation: .named))
        return item.sourceAppName.isEmpty
            ? when : "From \(item.sourceAppName) · \(when)"
    }

    @ViewBuilder
    private func icon(for item: DropShelfItem) -> some View {
        let url = store.url(for: item)
        if item.kind == .images, let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable().scaledToFill()
                .frame(width: 34, height: 26).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 26, height: 26)
                .frame(width: 34)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(
                presentation.selectedIDs.isEmpty
                    ? "Drag out to use · click ✕ to remove"
                    : "\(presentation.selectedIDs.count) selected"
            )
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            Spacer(minLength: 4)

            // Emptying the shelf had no control at all: the only way out was removing
            // items one at a time.
            if !store.items.isEmpty {
                Button {
                    // What the label says: the selection when there is one, the shelf when
                    // there is not.
                    let doomed = presentation.selectedIDs.isEmpty
                        ? store.items
                        : presentation.actionableItems(in: store.items, fallback: nil)
                    for item in doomed { DropShelfController.shared.remove(item) }
                    presentation.clearSelection()
                } label: {
                    Text(presentation.selectedIDs.isEmpty ? "Clear" : "Remove")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Button {
                NSWorkspace.shared.open(store.root)
            } label: {
                Text("Open Folder")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }
}
