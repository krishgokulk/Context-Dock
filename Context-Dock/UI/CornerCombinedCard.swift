// CornerCombinedCard.swift
// Context-Dock
//
// Centred (⌥⌥), the field, the apps beside it and the result sheet are one card, the way
// Spotlight is one panel, rather than three pieces of glass (owner 2026-10-12: "result sheet
// combined, not separate"). The pieces read `sharesOneCard` and leave their own glass off;
// the card draws one behind all of them.

import SwiftUI

private struct SharesOneCardKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var sharesOneCard: Bool {
        get { self[SharesOneCardKey.self] }
        set { self[SharesOneCardKey.self] = newValue }
    }
}

struct CornerCombinedCard: ViewModifier {
    let active: Bool
    static let radius: CGFloat = 28
    static let inset: CGFloat = 6

    func body(content: Content) -> some View {
        if active {
            content
                .environment(\.sharesOneCard, true)
                .padding(Self.inset)
                .background {
                    RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                        .fill(Color.clear)
                        .background(GlassBackground(cornerRadius: Self.radius, isDark: true))
                        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                        .shadow(color: .black.opacity(0.34), radius: 24, y: 12)
                }
        } else {
            content
        }
    }
}

/// A board's own glass — or nothing but a hairline when it already sits in the centred card,
/// where a second glass under the first is what made the clipboard and a command's panel
/// read far darker than the result sheet (owner 2026-10-12).
struct BoardGlass: ViewModifier {
    var radius: CGFloat = 22
    @Environment(\.sharesOneCard) private var sharesOneCard

    func body(content: Content) -> some View {
        content.background {
            if sharesOneCard {
                Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.clear)
                    .background(GlassBackground(cornerRadius: radius, isDark: true))
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                    .shadow(color: .black.opacity(0.34), radius: 20, y: 10)
            }
        }
    }
}
