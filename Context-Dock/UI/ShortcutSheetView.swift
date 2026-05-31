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
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                capsuleGlass(focused: searchFocused && focusedCommandID == nil)
                    .matchedGeometryEffect(
                        id: focusEffectID,
                        in: focusNamespace,
                        properties: .frame,
                        isSource: true
                    )
                    .opacity(focusedCommandID == nil ? 1 : 0)
            }
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
                    .onChange(of: focusedCommandID) { _, id in
                        guard let id else { return }
                        withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.86)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 420)
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

    @ViewBuilder
    private func capsuleGlass(focused: Bool) -> some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(focused ? 0.22 : 0.14),
                            Color.white.opacity(focused ? 0.06 : 0.03)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            Capsule(style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(focused ? 0.65 : 0.32),
                            Color.white.opacity(0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: focused ? 1.4 : 0.8
                )
            if focused {
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.65), lineWidth: 1.2)
                    .blur(radius: 2.4)
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

    private var highlighted: Bool { isFocused || isHovered }

    var body: some View {
        Button {
            onSelect(command)
        } label: {
            HStack(spacing: 8) {
                // Depth indicator — show parent menu for nested items
                if !command.parentPath.isEmpty {
                    Text(command.parentPath.replacingOccurrences(of: " > ", with: " › "))
                        .font(.system(size: 10))
                        .foregroundStyle(highlighted ? Color.white.opacity(0.7) : Color.secondary.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Text(command.title)
                    .font(.system(size: 13))
                    .foregroundStyle(command.item.isEnabled ? (highlighted ? .white : .primary) : .secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if !command.item.isEnabled {
                    Text("Unavailable")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(highlighted ? .white.opacity(0.75) : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(highlighted ? Color.white.opacity(0.14) : Color.primary.opacity(0.06))
                        )
                }

                if let sc = command.shortcutDisplay {
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
            .padding(.vertical, 7)
            .background {
                ZStack {
                    if isFocused {
                        Capsule(style: .continuous)
                            .fill(.ultraThinMaterial)
                            .matchedGeometryEffect(
                                id: focusEffectID,
                                in: namespace,
                                properties: .frame,
                                isSource: false
                            )
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.18),
                                        Color.white.opacity(0.055)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Capsule(style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.34),
                                        Color.white.opacity(0.08)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.8
                            )
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.38), lineWidth: 1)
                            .blur(radius: 2.2)
                    } else if isHovered {
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
