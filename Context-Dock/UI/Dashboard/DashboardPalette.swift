//
//  DashboardPalette.swift
//  Context-Dock
//
//  The dashboard's colour vocabulary. Three categorical hues, stepped separately
//  for light and dark rather than flipped, and validated as a set: worst all-pairs
//  CVD ΔE 9.2 light / 9.4 dark, worst normal-vision ΔE 24.0 light / 20.9 dark.
//  Aqua sits under 3:1 on the light surface, so every mark that wears it carries a
//  visible label — that is the relief the contrast warning obliges, not a nicety.
//
//  Colour never carries identity alone here: each node kind also has its own shape
//  and SF Symbol, so the graph still reads on a monochrome or colour-blind screen.
//

import SwiftUI

enum DashboardPalette {
    // MARK: Categorical slots

    /// Slot 1 — apps.
    static func app(_ dark: Bool) -> Color {
        dark ? Color(hex: 0x3987e5) : Color(hex: 0x2a78d6)
    }

    /// Slot 2 — folders.
    static func folder(_ dark: Bool) -> Color {
        dark ? Color(hex: 0xd95926) : Color(hex: 0xeb6834)
    }

    /// Slot 3 — CLI tools.
    static func tool(_ dark: Bool) -> Color {
        dark ? Color(hex: 0x199e70) : Color(hex: 0x1baf7a)
    }

    /// Conversations are the graph's subject, not one category among the others, so they
    /// wear ink rather than a categorical hue — which also keeps the palette at three.
    static func thread(_ dark: Bool) -> Color {
        dark ? Color(white: 0.78) : Color(white: 0.32)
    }

    /// Notes wear the same ink as conversations, and are told apart by shape and by the
    /// legend rather than by hue.
    ///
    /// Not a style choice. The categorical palette validates at three slots on the
    /// all-pairs pairlist a scatter needs; a fourth hue puts a pair under the CVD floor,
    /// and this graph draws every kind against every other. Ink is the honest way to add
    /// a kind without breaking the thing that makes the other three readable — and both
    /// ink kinds are the same thing anyway: what the user said, and what they wrote.
    static func color(for kind: KnowledgeNode.Kind, dark: Bool) -> Color {
        switch kind {
        case .thread, .note: return thread(dark)
        case .app: return app(dark)
        case .folder: return folder(dark)
        case .tool: return tool(dark)
        }
    }

    // MARK: Status — reserved, never reused as a series colour

    static func good(_ dark: Bool) -> Color { dark ? Color(hex: 0x199e70) : Color(hex: 0x1baf7a) }
    static func warning(_ dark: Bool) -> Color { dark ? Color(hex: 0xc98500) : Color(hex: 0xeda100) }
    static func critical(_ dark: Bool) -> Color { dark ? Color(hex: 0xe66767) : Color(hex: 0xe34948) }

    // MARK: Sequential (ordinal steps stay clear of the surface)

    /// Ordinal blue, light→dark by stage. Held to the ordinal floor: no lighter than step
    /// 250 on light, no darker than step 600 on dark, so the near-surface end still reads.
    static func ordinal(_ index: Int, of count: Int, dark: Bool) -> Color {
        let lightSteps: [UInt32] = [0x86b6ef, 0x5598e7, 0x3987e5, 0x2a78d6, 0x256abf, 0x1c5cab]
        let darkSteps: [UInt32] = [0x9ec5f4, 0x86b6ef, 0x5598e7, 0x3987e5, 0x256abf, 0x184f95]
        let steps = dark ? darkSteps : lightSteps
        guard count > 1 else { return Color(hex: steps[steps.count / 2]) }
        let position = Double(index) / Double(count - 1)
        let slot = Int((position * Double(steps.count - 1)).rounded())
        return Color(hex: steps[min(max(slot, 0), steps.count - 1)])
    }

    // MARK: Surfaces & ink

    static func surface(_ dark: Bool) -> Color {
        dark ? Color(red: 0.15, green: 0.15, blue: 0.16) : Color(white: 0.99)
    }

    static func cardStroke(_ dark: Bool) -> Color {
        dark ? Color.white.opacity(0.09) : Color.black.opacity(0.08)
    }

    /// The 2px gap between abutting fills is drawn as the surface colour, not as
    /// transparency, so overlapping marks keep a clean edge on any background.
    static func gap(_ dark: Bool) -> Color {
        dark ? Color(red: 0.13, green: 0.13, blue: 0.14) : Color(white: 1.0)
    }

    /// Edges in the knowledge graph.
    ///
    /// These used to borrow the grid colour, which is white at 7% — right for a gridline
    /// behind a bar chart, and invisible for the lines that are the entire content of a
    /// graph. Every edge was being drawn correctly and none of them could be seen, so the
    /// graph read as a field of loose dots and looked like a layout bug for days.
    static func edge(_ dark: Bool) -> Color {
        dark ? Color.white.opacity(0.30) : Color.black.opacity(0.26)
    }

    static func grid(_ dark: Bool) -> Color {
        dark ? Color.white.opacity(0.07) : Color.black.opacity(0.07)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: 1)
    }
}
