// Context-Dock/UI/Plugins/ExtensionHeaderBarState.swift
// Context-Dock
//
// Shared header bar contract mounted inside `AppChatPromptPill` whenever the user steps
// into any extension (`.doraxpack` v3, Global Extension, Global Command, or Plugin).
//
// Matches Raycast's single unified top bar:
// - Left: compact `[<]` back button + icon + extension title (+ optional count pill)
// - Middle: clean filter/search field (`Filter…` / `Search…`)
// - Right: optional refresh spinner + single-chevron filter/sort dropdown + refresh button
//   (no running-apps capsule and no redundant second top bar inside the board below).

import Combine
import SwiftUI

@MainActor
final class ExtensionHeaderBarState: ObservableObject {
    static let shared = ExtensionHeaderBarState()

    @Published var activeID: String = ""
    @Published var title: String = ""
    @Published var icon: String = ""
    @Published var tintHex: String? = nil
    @Published var count: Int? = nil
    @Published var filterOptions: [String] = []
    @Published var selectedFilter: String = "All"
    @Published var isRefreshing: Bool = false
    @Published var placeholder: String = "Filter…"

    var onBack: (() -> Void)? = nil
    var onSelectFilter: ((String) -> Void)? = nil
    var onRefresh: (() -> Void)? = nil

    private init() {}

    func update(
        id: String,
        title: String,
        icon: String,
        tintHex: String? = nil,
        count: Int? = nil,
        filterOptions: [String] = [],
        selectedFilter: String = "All",
        isRefreshing: Bool = false,
        placeholder: String = "Filter…",
        onBack: (() -> Void)? = nil,
        onSelectFilter: ((String) -> Void)? = nil,
        onRefresh: (() -> Void)? = nil
    ) {
        self.activeID = id
        self.title = title
        self.icon = icon
        self.tintHex = tintHex
        self.count = count
        self.filterOptions = filterOptions
        self.selectedFilter = selectedFilter
        self.isRefreshing = isRefreshing
        self.placeholder = placeholder
        self.onBack = onBack
        self.onSelectFilter = onSelectFilter
        self.onRefresh = onRefresh
    }

    func reset(ifMatching id: String) {
        guard activeID == id else { return }
        activeID = ""
        title = ""
        icon = ""
        tintHex = nil
        count = nil
        filterOptions = []
        selectedFilter = "All"
        isRefreshing = false
        placeholder = "Filter…"
        onBack = nil
        onSelectFilter = nil
        onRefresh = nil
    }
}

struct ExtensionHeaderLeadingBar: View {
    @ObservedObject var header = ExtensionHeaderBarState.shared
    @ObservedObject var model: AppChatPromptModel

    private var resolvedTitle: String {
        header.title.isEmpty ? model.appName : header.title
    }

    private var resolvedIcon: String {
        if !header.icon.isEmpty { return header.icon }
        if let v3 = model.scopedV3Command { return v3.command.icon }
        if let cmd = model.scopedCommand { return cmd.icon }
        if let ext = model.scopedExtension { return ext.icon }
        if let plg = model.scopedPlugin { return plg.icon }
        return "puzzlepiece.extension"
    }

    private var accentColor: Color {
        if let hex = header.tintHex ?? model.scopedV3Command?.effectiveAppearance?.tint,
           let c = DockAuraEngine.color(fromHex: hex)
        {
            return c
        }
        return .accentColor
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if let customBack = header.onBack {
                    customBack()
                } else {
                    _ = model.leaveScopeForGlobal()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.88))
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Back to Global Context (Esc)")
            .accessibilityLabel("Back to Global Context")

            HStack(spacing: 6) {
                Image(systemName: resolvedIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accentColor)
                Text(resolvedTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.92))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if let count = header.count {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.08), in: Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5))
        }
        .layoutPriority(1)
    }
}

struct ExtensionHeaderTrailingControls: View {
    @ObservedObject var header = ExtensionHeaderBarState.shared

    var body: some View {
        HStack(spacing: 6) {
            if header.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.62)
            }

            if !header.filterOptions.isEmpty, let onSelect = header.onSelectFilter {
                Menu {
                    ForEach(header.filterOptions, id: \.self) { opt in
                        Button {
                            onSelect(opt)
                        } label: {
                            if header.selectedFilter == opt {
                                Label("\(opt)  ✓", systemImage: "checkmark")
                            } else {
                                Text(opt)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(header.selectedFilter)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.9))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Filter items")
            }

            if let onRefresh = header.onRefresh {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
