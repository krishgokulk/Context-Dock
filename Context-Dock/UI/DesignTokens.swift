// DesignTokens.swift
// Context-Dock
//
// Single source of truth for premium (Liquid Glass) surface, selection, border,
// and text colors. Every value resolves per color scheme so light and dark both
// stay legible — no more hardcoded `Color.white.opacity(…)` that only works dark.
//
// Mirrors the Liquid Glass colour-variable spec: Surface / Elevated / Selection /
// Border / Separator / Text.

import SwiftUI

enum Theme {

    // MARK: - Selection (list rows + dock capsule)

    /// Fill behind a selected/focused result row.
    static func selectionFill(_ dark: Bool) -> Color {
        dark ? Color.white.opacity(0.10)
             : Color.white.opacity(0.30)
    }

    /// Hairline around a selected row — gives the row an edge in light mode
    /// where a translucent fill alone disappears on bright glass.
    static func selectionStroke(_ dark: Bool) -> Color {
        dark ? Color.white.opacity(0.16)
             : Color.white.opacity(0.62)
    }

    /// Top glass highlight gradient for the dock selection capsule.
    static func selectionGlassTop(_ dark: Bool) -> Color {
        dark ? Color.white.opacity(0.18)
             : Color.white.opacity(0.46)
    }

    static func selectionGlassBottom(_ dark: Bool) -> Color {
        dark ? Color.white.opacity(0.055)
             : Color.white.opacity(0.14)
    }

    static func selectionGlassRim(_ dark: Bool) -> Color {
        dark ? Color.white.opacity(0.34)
             : Color.white.opacity(0.72)
    }

    // MARK: - Surfaces (cards, sheets, panels)

    /// Standard inset surface (settings cards, list backgrounds).
    static func surface(_ dark: Bool) -> Color {
        dark ? Color.white.opacity(0.05)
             : Color.black.opacity(0.04)
    }

    /// Slightly raised surface (selected item containers, popovers).
    static func surfaceElevated(_ dark: Bool) -> Color {
        dark ? Color.white.opacity(0.08)
             : Color.black.opacity(0.06)
    }

    // MARK: - Borders / separators

    static func border(_ dark: Bool) -> Color {
        dark ? Color.white.opacity(0.14)
             : Color.black.opacity(0.10)
    }

    static func separator(_ dark: Bool) -> Color {
        dark ? Color.white.opacity(0.08)
             : Color.black.opacity(0.07)
    }

    // MARK: - Convenience (ColorScheme overloads)

    static func selectionFill(_ s: ColorScheme) -> Color { selectionFill(s == .dark) }
    static func selectionStroke(_ s: ColorScheme) -> Color { selectionStroke(s == .dark) }
    static func surface(_ s: ColorScheme) -> Color { surface(s == .dark) }
    static func surfaceElevated(_ s: ColorScheme) -> Color { surfaceElevated(s == .dark) }
    static func border(_ s: ColorScheme) -> Color { border(s == .dark) }
    static func separator(_ s: ColorScheme) -> Color { separator(s == .dark) }
}
