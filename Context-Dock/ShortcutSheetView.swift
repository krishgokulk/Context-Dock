// ShortcutSheetView.swift
// ILauncher
//
// Popover shown when Cmd is held ≥0.8s — lists all frontmost app's menu shortcuts
// grouped by top-level menu section (File, Edit, View…), tappable to execute.
// Supports up/down arrow key navigation via focusedIdx binding.
//

import SwiftUI

struct ShortcutSheetView: View {
    let items: [AXMenuItem]       // flat leaf items from liveMenuItems
    let appName: String
    let onSelect: (AXMenuItem) -> Void
    @Binding var focusedIdx: Int?

    // Flattened enabled items (the navigable list)
    private var flatItems: [AXMenuItem] {
        items.filter(\.isEnabled)
    }

    // Group items by their top-level menu name (path[0])
    private var sections: [(title: String, items: [(globalIdx: Int, item: AXMenuItem)])] {
        var order: [String] = []
        var dict: [String: [(globalIdx: Int, item: AXMenuItem)]] = [:]
        for (idx, item) in flatItems.enumerated() {
            let key = item.path.first ?? "Other"
            if dict[key] == nil { order.append(key) }
            dict[key, default: []].append((globalIdx: idx, item: item))
        }
        return order.map { (title: $0, items: dict[$0]!) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(appName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("Shortcuts")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 8)

            if sections.isEmpty {
                Text("No shortcuts found")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                            ForEach(sections, id: \.title) { section in
                                Section {
                                    ForEach(section.items, id: \.item.id) { entry in
                                        ShortcutRowView(
                                            item: entry.item,
                                            isFocused: focusedIdx == entry.globalIdx,
                                            onSelect: onSelect
                                        )
                                        .id("srow-\(entry.globalIdx)")
                                    }
                                } header: {
                                    Text(section.title)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .textCase(.uppercase)
                                        .tracking(0.5)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 5)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(.thinMaterial)
                                }
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: focusedIdx) { _, idx in
                        guard let idx else { return }
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo("srow-\(idx)", anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 340)
    }
}

// MARK: - Row

private struct ShortcutRowView: View {
    let item: AXMenuItem
    let isFocused: Bool
    let onSelect: (AXMenuItem) -> Void
    @State private var isHovered = false

    private var highlighted: Bool { isFocused || isHovered }

    var body: some View {
        Button {
            onSelect(item)
        } label: {
            HStack(spacing: 8) {
                // Depth indicator — show parent menu for nested items
                if item.path.count > 2 {
                    Text(item.path.dropLast().dropFirst().joined(separator: " › "))
                        .font(.system(size: 10))
                        .foregroundStyle(highlighted ? Color.white.opacity(0.7) : Color.secondary.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Text(item.title)
                    .font(.system(size: 13))
                    .foregroundStyle(highlighted ? .white : .primary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let sc = item.shortcutDisplay {
                    Text(sc)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(highlighted ? .white.opacity(0.85) : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(highlighted
                                      ? Color.white.opacity(0.2)
                                      : Color.primary.opacity(0.08))
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(highlighted ? Color.accentColor : Color.clear)
                    .padding(.horizontal, 4)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
