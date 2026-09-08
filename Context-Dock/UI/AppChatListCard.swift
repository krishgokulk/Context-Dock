// AppChatListCard.swift
// Context-Dock
//
// What the frontmost app can do, as its own card above the input.
//
// It began inside the prompt pill, sharing one rounded container with the field. Separated
// because the two are different things: the field is where you write, and this is what the
// app offers — the same reason the clip being looked at gets its own card above the
// clipboard rather than growing it. The corner already reads as a stack of cards; this is
// one of them.
//
// Still one shell and one window: the Unified Dock Surface rule is about containers the app
// floats, not about a stack of surfaces inside the one it has.

import SwiftUI

enum AppChatListMetrics {
    static let width = AppChatPromptMetrics.width
    static let rowHeight: CGFloat = 34
    static let headerHeight: CGFloat = 30
    /// Room above and below the rows.
    static let verticalPadding: CGFloat = 10

    /// A pure function of how many rows there are — the corner draws this frame and
    /// hit-tests the same number, so a measured height would leave the two disagreeing.
    static func size(rows: Int) -> CGSize {
        CGSize(
            width: width,
            height: headerHeight + CGFloat(rows) * rowHeight + verticalPadding * 2)
    }
}

/// The commands matching what is typed, or — before anything is typed — what the app can do.
struct AppChatListCard: View {
    @ObservedObject var model: AppChatPromptModel

    private var size: CGSize {
        AppChatListMetrics.size(rows: model.listRowCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(headerText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary.opacity(0.7))
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(height: AppChatListMetrics.headerHeight, alignment: .leading)

            if model.isBrowsingMenus {
                ForEach(Array(model.menuMatches.enumerated()), id: \.element.id) { index, item in
                    commandRow(item, isFocused: index == model.focusedMenuIndex)
                }
            } else {
                ForEach(model.suggestions.prefix(AppChatPromptModel.menuRowLimit)) { suggestion in
                    suggestionRow(suggestion)
                }
            }
        }
        .padding(.vertical, AppChatListMetrics.verticalPadding)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.clear)
                .background(GlassBackground(cornerRadius: 22, isDark: true))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.34), radius: 20, y: 10)
        }
        .onHover { _ in model.touch() }
    }

    private var headerText: String {
        if model.isBrowsingMenus {
            return model.appName.isEmpty ? "Commands" : "\(model.appName) commands"
        }
        return model.capabilitySummary
    }

    /// A command the app really has: its name, the menu it lives under, and its shortcut —
    /// the three things that say this is the app's own command and not a paraphrase of one.
    private func commandRow(_ item: AXMenuItem, isFocused: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "command")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            if let context = item.path.dropLast().last, !context.isEmpty {
                Text(context)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let shortcut = item.shortcutDisplay {
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: AppChatListMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(isFocused ? 0.10 : 0))
                .padding(.horizontal, 8))
        .contentShape(Rectangle())
        .onTapGesture { model.runMenuItem(item) }
    }

    private func suggestionRow(_ suggestion: AppChatSuggestion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: suggestion.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(suggestion.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 16)
        .frame(height: AppChatListMetrics.rowHeight)
    }
}
