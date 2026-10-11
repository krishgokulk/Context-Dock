// ActionFeedbackGlyph.swift
// Context-Dock
//
// One result, as one glyph: the acted-on app's icon with a small phase badge when the
// result names an app, otherwise the result's own symbol in its colour. Drawn at strip
// size in the dock and at control size beside the field, so the same thing is seen in
// both places rather than two different things.

import AppKit
import SwiftUI

struct ActionFeedbackGlyph: View {
    let feedback: DockInlineFeedback
    /// The slot this fills — 48 in the strip, 26 beside the field.
    var size: CGFloat = 26

    @ObservedObject private var store = CornerActionFeedback.shared

    private var appIcon: NSImage? { store.appIcon(for: feedback) }
    private var tint: Color {
        ActionFeedbackTint.color(for: feedback, appColor: appIcon?.dominantSwiftUIColor)
    }
    private var symbolSize: CGFloat { size * 0.42 }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size * 0.7, height: size * 0.7)
                // The phase, badged on the app rather than replacing it: "Code, quit" reads
                // as one fact.
                Image(systemName: badgeSymbol)
                    .font(.system(size: size * 0.26, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size * 0.36, height: size * 0.36)
                    .background(tint, in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
                    .offset(x: size * 0.06, y: size * 0.06)
            } else {
                Image(systemName: feedback.icon)
                    .font(.system(size: symbolSize, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: size * 0.7, height: size * 0.7)
            }
            if feedback.phase == .progress {
                ProgressView()
                    .controlSize(.mini)
                    .offset(x: size * 0.06, y: size * 0.06)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .help(feedback.title)
        .accessibilityLabel(feedback.title)
    }

    private var badgeSymbol: String {
        if ActionFeedbackTint.isDestructive(feedback) { return "xmark" }
        switch feedback.phase {
        case .progress: return "ellipsis"
        case .success: return "checkmark"
        case .failure: return "exclamationmark"
        }
    }
}
