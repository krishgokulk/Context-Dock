// ShortcutSheetView.swift
// ILauncher
//
// Popover shown when Cmd is held ≥0.8s — lists all frontmost app's menu shortcuts
// grouped by top-level menu section (File, Edit, View…), tappable to execute.
// Supports up/down arrow key navigation via stable command IDs.
//

import SwiftUI

struct ShortcutSheetView: View {
    let commands: [ShortcutMenuCommand]
    let appName: String
    let onSelect: (ShortcutMenuCommand) -> Void
    @Binding var focusedCommandID: String?
    @Binding var searchQuery: String
    @FocusState private var searchFocused: Bool
    @Namespace private var focusNamespace
    private let focusEffectID = "shortcut-sheet-focus"
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    private var visibleCommands: [ShortcutMenuCommand] {
        ShortcutMenuCommand.filtered(commands, query: searchQuery)
    }

    // Group items by their top-level menu name (path[0])
    private var sections: [(title: String, items: [ShortcutMenuCommand])] {
        var order: [String] = []
        var dict: [String: [ShortcutMenuCommand]] = [:]
        for command in visibleCommands {
            let key = command.section
            if dict[key] == nil { order.append(key) }
            dict[key, default: []].append(command)
        }
        return order.map { (title: $0, items: dict[$0]!) }
    }

    var body: some View {
        UnifiedDockSurface(size: .sheet, width: 420, isDark: isDark) {
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

            UnifiedDockInputBar(isFocused: searchFocused && focusedCommandID == nil, isDark: isDark) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(searchFocused ? .primary : .secondary)
                    TextField("Search menu commands", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .focused($searchFocused)
                        .onChange(of: searchQuery) { _, _ in
                            let visibleIDs = Set(visibleCommands.map(\.id))
                            if let focusedCommandID, !visibleIDs.contains(focusedCommandID) {
                                self.focusedCommandID = nil
                            }
                        }
                }
            } trailing: {
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                        focusedCommandID = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
            }
            .matchedGeometryEffect(
                id: focusEffectID,
                in: focusNamespace,
                properties: .frame,
                isSource: true
            )
            .opacity(focusedCommandID == nil ? 1 : 0.98)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 8)

            if visibleCommands.isEmpty {
                Text(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "No shortcuts found"
                     : "No menu commands match")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(sections, id: \.title) { section in
                                Section {
                                    ForEach(section.items) { command in
                                        ShortcutRowView(
                                            command: command,
                                            isFocused: focusedCommandID == command.id,
                                            namespace: focusNamespace,
                                            focusEffectID: focusEffectID,
                                            onSelect: onSelect
                                        )
                                        .id(command.id)
                                    }
                                } header: {
                                    UnifiedDockSectionHeader(title: section.title)
                                }
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: focusedCommandID) { _, id in
                        guard let id else { return }
                        withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.86)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
            }
        }
        .onAppear {
            focusedCommandID = nil
            DispatchQueue.main.async {
                searchFocused = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                searchFocused = true
            }
        }
        .onChange(of: focusedCommandID) { _, id in
            if id == nil {
                DispatchQueue.main.async {
                    searchFocused = true
                }
            }
        }
    }
}

// MARK: - Row

private struct ShortcutRowView: View {
    let command: ShortcutMenuCommand
    let isFocused: Bool
    let namespace: Namespace.ID
    let focusEffectID: String
    let onSelect: (ShortcutMenuCommand) -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    private var highlighted: Bool { isFocused || isHovered }

    /// Title color: white only when sitting on a strong selection background
    /// (solid accent in light, white-glass in dark). Stays legible on hover.
    private var primaryTextColor: Color {
        guard command.item.isEnabled else { return .secondary }
        if isFocused { return .white }
        if isHovered { return isDark ? .white : .primary }
        return .primary
    }

    /// Secondary text (parent path, shortcut keys, badges).
    private var accessoryColor: Color {
        if isFocused { return .white.opacity(0.82) }
        if isHovered { return isDark ? .white.opacity(0.8) : .secondary }
        return .secondary.opacity(0.7)
    }

    private var accessoryBadgeFill: Color {
        isFocused ? Color.white.opacity(0.18) : Color.primary.opacity(0.08)
    }

    var body: some View {
        Button {
            onSelect(command)
        } label: {
            HStack(spacing: 8) {
                // Depth indicator — show parent menu for nested items
                if !command.parentPath.isEmpty {
                    Text(command.parentPath.replacingOccurrences(of: " > ", with: " › "))
                        .font(.system(size: 10))
                        .foregroundStyle(accessoryColor)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Text(command.title)
                    .font(.system(size: 13))
                    .foregroundStyle(primaryTextColor)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if !command.item.isEnabled {
                    Text("Unavailable")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(accessoryColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(accessoryBadgeFill)
                        )
                }

                if let sc = command.shortcutDisplay {
                    Text(sc)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(accessoryColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(accessoryBadgeFill)
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background {
                if isFocused {
                UnifiedDockRowBackground(
                    isFocused: isFocused,
                    isHovered: isHovered,
                    isEnabled: command.item.isEnabled,
                    isDark: isDark,
                    selectionNamespace: namespace,
                    selectionEffectID: focusEffectID,
                    usesMatchedGeometry: true
                )
            } else {
                UnifiedDockRowBackground(
                        isFocused: isFocused,
                        isHovered: isHovered,
                        isEnabled: command.item.isEnabled,
                        isDark: isDark
                    )
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
