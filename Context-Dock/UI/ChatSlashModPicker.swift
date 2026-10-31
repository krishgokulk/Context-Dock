// ChatSlashModPicker.swift
// Context-Dock
//
// Slash autocomplete and mode picker for `/mods` commands in App Pet chat (#341).
// Stacks mode rows above the composer in the corner, matching ChatSlashAppList.

import SwiftUI

@MainActor
enum ChatSlashModPicker {

    static func isModQuery(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed == "/mod" || trimmed == "/mods" || trimmed.hasPrefix("/mods ") || trimmed.hasPrefix("/mod ")
    }

    static func matches(for text: String, participant: ConversationParticipant?) -> [AppPetModeManifest] {
        guard let participant else { return [] }
        guard isModQuery(text) else { return [] }

        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let supported = AppPetManifestRegistry.shared.supportedModes(for: participant.petID)

        let filter: String = {
            if trimmed.hasPrefix("/mods ") {
                return String(trimmed.dropFirst("/mods ".count)).trimmingCharacters(in: .whitespaces).lowercased()
            }
            if trimmed.hasPrefix("/mod ") {
                return String(trimmed.dropFirst("/mod ".count)).trimmingCharacters(in: .whitespaces).lowercased()
            }
            return ""
        }()

        if filter.isEmpty {
            return supported
        }

        return supported.filter {
            $0.name.lowercased().contains(filter) || $0.id.contains(filter) || $0.summary.lowercased().contains(filter)
        }
    }

    static func movedSelection(from current: Int, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return min(max(current + delta, 0), count - 1)
    }

    @discardableResult
    static func pickLeadingMatch(
        text: inout String,
        participant: ConversationParticipant?,
        onPick: (AppPetModeManifest) -> Void
    ) -> Bool {
        guard let match = matches(for: text, participant: participant).first else { return false }
        onPick(match)
        text = ""
        return true
    }
}

/// A vertical list of modes matching `/mods` stacked above the composer.
struct ChatSlashModList: View {
    let matches: [AppPetModeManifest]
    var selection: Int = 0
    var activeModeID: String? = nil
    let onPick: (AppPetModeManifest) -> Void

    static let maxVisibleRows = 4
    static let rowHeight: CGFloat = 36
    static let verticalInset: CGFloat = 6

    static func height(for matchCount: Int) -> CGFloat {
        guard matchCount > 0 else { return 0 }
        return CGFloat(min(matchCount, maxVisibleRows)) * rowHeight + verticalInset * 2
    }

    @State private var hovered: String?

    private var selectedIndex: Int {
        guard !matches.isEmpty else { return 0 }
        return min(max(selection, 0), matches.count - 1)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, mode in
                        Button { onPick(mode) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: mode.icon ?? "sparkles")
                                    .font(.system(size: 13, weight: .medium))
                                    .frame(width: 20, height: 20)
                                    .foregroundStyle(index == selectedIndex ? Color.accentColor : .primary)

                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(mode.name)
                                            .font(.system(size: 13, weight: .semibold))
                                            .lineLimit(1)

                                        if mode.id == activeModeID {
                                            Text("Active")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(Color.accentColor)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                                        }
                                    }

                                    Text(mode.summary)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 4)

                                if index == selectedIndex {
                                    Text("↩")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 14)
                            .frame(height: Self.rowHeight)
                            .background(
                                rowTint(index: index, mode: mode),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(index)
                        .onHover { hovered = $0 ? mode.id : (hovered == mode.id ? nil : hovered) }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, Self.verticalInset)
            }
            .frame(height: Self.height(for: matches.count))
            .onChange(of: selectedIndex) { _, index in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(index) }
            }
        }
    }

    private func rowTint(index: Int, mode: AppPetModeManifest) -> Color {
        if index == selectedIndex { return Color.accentColor.opacity(0.22) }
        if hovered == mode.id { return Color.primary.opacity(0.1) }
        return .clear
    }
}

/// Horizontal strip of mode pills for the composer.
struct ChatSlashModChipStrip: View {
    let matches: [AppPetModeManifest]
    var activeModeID: String? = nil
    let onPick: (AppPetModeManifest) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(matches) { mode in
                    Button { onPick(mode) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: mode.icon ?? "sparkles")
                                .font(.system(size: 11, weight: .medium))

                            Text(mode.name)
                                .font(.system(size: 12, weight: .medium))

                            if mode.id == activeModeID {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 5, height: 5)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .background(
                            mode.id == activeModeID ? Color.accentColor.opacity(0.15) : Color.clear,
                            in: Capsule()
                        )
                        .overlay {
                            Capsule().strokeBorder(
                                mode.id == activeModeID ? Color.accentColor.opacity(0.6) : Color.white.opacity(0.15),
                                lineWidth: 1
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .help(mode.summary)
                }
            }
            .padding(.horizontal, 2)
        }
    }
}
