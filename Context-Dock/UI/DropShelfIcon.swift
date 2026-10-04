// DropShelfIcon.swift
// Context-Dock
//
// The Drop Shelf's icon: the last item of every dock row, in the Dock and in the Corner, in
// every scope, with or without pins. A click opens the shelf in the same shell; a drag over
// it makes it the drop target. One view for every row, in three sizes, so the shells cannot
// each grow their own copy.

import AppKit
import SwiftUI

struct DropShelfIcon: View {
    /// The row it sits in: the Corner strip's big icon, the Corner field's round control, or
    /// the Dock's input-bar button.
    enum Style { case strip, control, dock }

    @ObservedObject var presentation: DropShelfPresentation
    @ObservedObject var store: DropShelfStore
    var style: Style
    /// The pill-row keys (`DockKeyRules.pillRow`) have the highlight on it.
    var isKeyboardFocused = false

    private var highlight: DropShelfDragRule.Highlight {
        DropShelfDragRule.highlight(
            phase: presentation.phase, dragOverIcon: presentation.isDragOverIcon)
    }

    private var isOpen: Bool { presentation.phase.isCardShown }

    private var symbol: String {
        highlight == .none ? "tray.full.fill" : "tray.and.arrow.down.fill"
    }

    private var tint: Color {
        highlight == .none && !isOpen ? .secondary : .accentColor
    }

    var body: some View {
        Button {
            presentation.toggle()
        } label: {
            glyph
        }
        .buttonStyle(.plain)
        .dropShelfTarget(presentation)
        .dockKeyboardFocus(isKeyboardFocused)
        .help("Drop shelf")
        .accessibilityLabel("Drop shelf")
        .accessibilityValue(Self.spokenCount(store.items.count))
        .accessibilityHint(isOpen ? "Closes the shelf" : "Opens the shelf. Drop files, text, or links here.")
        .accessibilityAddTraits(isOpen ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var glyph: some View {
        switch style {
        case .strip:
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(tint)
                .frame(
                    width: AppChatPromptMetrics.dockIconSize,
                    height: AppChatPromptMetrics.dockIconSize)
                .background(highlightFill(Capsule()))
                .overlay(alignment: .topTrailing) { badge }
                .contentShape(Rectangle())
        case .control:
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(highlight == .none && !isOpen ? Color.secondary : Color.accentColor)
                .frame(width: 26, height: 26)
                .background(
                    highlight == .none && !isOpen
                        ? Color.primary.opacity(0.08) : Color.accentColor.opacity(0.18),
                    in: Circle())
                .overlay(alignment: .topTrailing) { badge }
                .contentShape(Circle())
        case .dock:
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(highlight == .none && !isOpen ? Color.secondary : Color.accentColor)
                .frame(width: 22, height: 22)
                .overlay(alignment: .topTrailing) { badge }
                .contentShape(Rectangle())
        }
    }

    /// The count of what the shelf holds, when it holds something — the store already knows.
    @ViewBuilder
    private var badge: some View {
        if !store.items.isEmpty {
            Text("\(store.items.count)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 14, minHeight: 14)
                .background(Color.accentColor, in: Capsule())
                .offset(x: 4, y: -2)
                .accessibilityHidden(true)
        }
    }

    /// While a drag is on the icon it is drawn as the target.
    @ViewBuilder
    private func highlightFill<S: Shape>(_ shape: S) -> some View {
        switch highlight {
        case .none: Color.clear
        case .invited: shape.fill(Color.accentColor.opacity(0.12))
        case .target: shape.fill(Color.accentColor.opacity(0.28))
        }
    }

    static func spokenCount(_ count: Int) -> String {
        switch count {
        case 0: return "empty"
        case 1: return "1 item"
        default: return "\(count) items"
        }
    }
}
