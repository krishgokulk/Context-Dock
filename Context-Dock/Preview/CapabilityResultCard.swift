// CapabilityResultCard.swift
// Context-Dock
//
// A capability's findings, drawn.
//
// The answer to "find duplicate files here" was correct and unusable: twelve sets of
// paths in prose, and a question at the end asking whether to delete any. Everything
// needed to act was on screen as text the user would have to retype. A result the app
// produced itself should be a result the app can operate.

import AppKit
import SwiftUI

struct CapabilityResultCard: View {
    let table: CapabilityResultTable

    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if expanded {
                VStack(spacing: 2) {
                    ForEach(table.rows) { row in
                        rowView(row)
                    }
                }
            }

            if let summary = table.summary {
                Text(summary)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var header: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                Text(table.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(table.rows.count)")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func rowView(_ row: CapabilityResultRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let first = row.paths.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: first.path))
                        .resizable()
                        .frame(width: 13, height: 13)
                }
                Text(row.title)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if let detail = row.detail {
                    Text(detail)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            // A size next to seven other sizes is a number to compare; as a bar it is a
            // glance.
            if let fraction = row.fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.07))
                        Capsule()
                            .fill(Color.accentColor.opacity(0.55))
                            .frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)))
                    }
                }
                .frame(height: 3)
            }

            if let subtitle = row.subtitle {
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { preview(row) }
        .contextMenu { menu(for: row) }
        .help(row.paths.first?.path ?? "")
    }

    @ViewBuilder
    private func menu(for row: CapabilityResultRow) -> some View {
        // Every row stands for real files, so every row can be looked at and acted on.
        // Nothing here deletes: a tidy-up is the capability's job, through its own
        // approval, not a menu item hiding behind a search result.
        Button("Preview") { preview(row) }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(row.paths)
        }
        Button("Open") { row.paths.forEach { NSWorkspace.shared.open($0) } }
        Button("Copy Path\(row.paths.count > 1 ? "s" : "")") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                row.paths.map(\.path).joined(separator: "\n"), forType: .string)
        }
    }

    private func preview(_ row: CapabilityResultRow) {
        guard let first = row.paths.first else { return }
        PreviewController.shared.present(
            url: first, siblings: row.paths, toggleIfSame: false)
    }
}
