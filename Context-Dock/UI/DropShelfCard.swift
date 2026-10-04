// DropShelfCard.swift
// Context-Dock
//
// What the Drop Shelf shows when it is open: the held items and their footer. Opened from the
// shelf's icon at the end of the dock row (`DropShelfIcon`), in the same shell, with the same
// glass as the other cards. The window never resizes — the card appears and goes inside the
// shell's fixed transparent panel.

import AppKit
import SwiftUI

/// The open shelf in the Corner: the items in the shell's own glass, above the field like
/// the selection card and the commands list.
struct DropShelfCard: View {
    @ObservedObject var presentation: DropShelfPresentation
    @ObservedObject var store: DropShelfStore

    var body: some View {
        DropShelfCardContent(
            presentation: presentation, store: store, size: DropShelfMetrics.expandedSize
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.clear)
                .background(GlassBackground(cornerRadius: 22, isDark: true))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(
                            presentation.isDragOverIcon
                                ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.16),
                            lineWidth: presentation.isDragOverIcon ? 2 : 1)
                )
                .shadow(color: .black.opacity(0.34), radius: 20, y: 10)
        }
        // A drop on the open card lands on the shelf too — the card is the shelf.
        .dropShelfTarget(presentation)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop shelf")
    }
}

/// The items and the footer, with no chrome of its own: the Corner wraps it in glass, the
/// Dock draws it inside its sheet. One view, so the two cannot drift apart.
struct DropShelfCardContent: View {
    @ObservedObject var presentation: DropShelfPresentation
    @ObservedObject var store: DropShelfStore
    let size: CGSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rows
            Divider().opacity(0.2)
            footer
        }
        .frame(width: size.width, height: size.height)
    }

    private var rows: some View {
        Group {
            if store.items.isEmpty { emptyState } else { itemList }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// An open shelf with nothing on it says what it is for, instead of showing a blank card.
    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)
            Text("Nothing on the shelf")
                .font(.system(size: 12.5, weight: .semibold))
            Text("Drop files, text, or links on the tray icon.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(16)
        .accessibilityElement(children: .combine)
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(store.items) { item in
                    row(item)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
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
            .accessibilityLabel("Remove \(item.originalName) from shelf")
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
        // One `NSItemProvider` is all `.onDrag` can carry, so the selection past the first
        // item was being dropped. A real dragging session carries all of them.
        .overlay {
            MultiItemDragSource(
                urls: {
                    let dragged = presentation.isSelected(item)
                        ? presentation.actionableItems(in: store.items, fallback: item)
                        : [item]
                    DropShelfController.shared.beginDrag()
                    return dragged.map { store.url(for: $0) }
                },
                onClick: {
                    let flags = NSEvent.modifierFlags
                    presentation.select(
                        item, in: store.items,
                        extend: flags.contains(.shift), toggle: flags.contains(.command))
                }
            )
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
