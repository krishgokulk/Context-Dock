// ScopedAppPickerList.swift
// Context-Dock
//
// The one app picker for AI surfaces: the dock's chat-focus popover and the composer
// bar's "work with an app" popover.
//
// They had grown apart — the dock showed a compact list with a running dot and a
// checkmark, the composer showed a taller list with a search field and the words "Not
// running" — so picking an app felt like two different features depending on where you
// were. Same rows, same states, same interaction; only the source of the rows differs.

import AppKit
import SwiftUI

struct ScopedAppPickerRow: Identifiable, Equatable {
    let name: String
    let bundleId: String
    let icon: NSImage?
    let isRunning: Bool

    var id: String { bundleId.isEmpty ? name : bundleId.lowercased() }
}

struct ScopedAppPickerList: View {
    let rows: [ScopedAppPickerRow]
    /// Bundle ids (or names, for sources with no bundle id) already attached.
    let selectedIDs: Set<String>
    let onToggle: (ScopedAppPickerRow) -> Void

    /// Search appears only when the list is long enough to need it — a field above four
    /// running apps is furniture.
    private let searchThreshold = 8

    @State private var query = ""
    @State private var hoveredID: String?

    private var filtered: [ScopedAppPickerRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter { $0.name.lowercased().contains(q) }
    }

    private var listHeight: CGFloat {
        let count = min(max(filtered.count, 1), 7)
        return CGFloat(count) * 34 + 8
    }

    var body: some View {
        VStack(spacing: 0) {
            if rows.count >= searchThreshold {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    TextField("Search apps", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                Divider().opacity(0.4)
            }

            ScrollView(.vertical, showsIndicators: filtered.count > 7) {
                LazyVStack(spacing: 2) {
                    ForEach(filtered) { row in
                        rowView(row)
                    }
                    if filtered.isEmpty {
                        Text("No apps match “\(query)”")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                }
                .padding(4)
            }
            .frame(height: listHeight)
        }
        .frame(width: 232)
    }

    private func rowView(_ row: ScopedAppPickerRow) -> some View {
        // Two callers key attachment differently — the dock by bundle id, the composer
        // bars by app name — and the rows now carry both. Matching either keeps the
        // checkmark honest on both surfaces rather than making one of them re-key.
        let isSelected =
            selectedIDs.contains(row.id) || selectedIDs.contains(row.name.lowercased())
        let isHovered = hoveredID == row.id
        return Button {
            onToggle(row)
        } label: {
            HStack(spacing: 8) {
                Group {
                    if let icon = row.icon {
                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .opacity(row.isRunning ? 1 : 0.65)

                Text(row.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                // Green = running; grey = installed or adapter-configured, not launched.
                Circle()
                    .fill(row.isRunning ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 6, height: 6)
                    .help(row.isRunning ? "Running" : "Not running")

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovered ? Color.accentColor.opacity(0.22) : Color.clear)
                    .shadow(
                        color: isHovered ? Color.accentColor.opacity(0.38) : .clear,
                        radius: 7)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredID = hovering ? row.id : nil
            }
        }
    }
}

extension ScopedAppPickerRow {
    /// Every app the composer can attach: running apps first, then everything installed —
    /// "work with Notes" is reasonable before Notes is open.
    @MainActor
    static func allApps() -> [ScopedAppPickerRow] {
        // One merged, ranked source for every chat surface — see ChatAppDirectory. Rows
        // carry the real bundle id rather than the name doubling as one, so a picker can
        // open a scope without resolving the app again.
        ChatAppDirectory.all().map {
            ScopedAppPickerRow(
                name: $0.name, bundleId: $0.bundleId, icon: $0.icon, isRunning: $0.isRunning)
        }
    }
}
