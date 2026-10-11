// Context-Dock
//
// The components that move: a progress bar, a timer, a waveform, live text, a pulse dot.
// All of them stop when the host says it has no budget, so a hidden or shrunk surface is
// quiet rather than burning battery for nobody (spec §5).

import SwiftUI

struct PluginLiveView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding

    static func isAnimating(_ traits: HostTraits) -> Bool { traits.liveBudget != .none }

    /// A fraction between 0 and 1. With no `total` the value is already a fraction, which is
    /// the common spelling; a zero total is 0 rather than a division.
    static func fraction(of node: PluginNode, binding: PluginBinding) -> Double {
        let value = binding.number(node.props["value"]) ?? 0
        let total = binding.number(node.props["total"]) ?? 1
        guard total > 0 else { return 0 }
        return min(max(value / total, 0), 1)
    }

    var body: some View {
        switch node.component {
        case "progress":
            ProgressView(value: Self.fraction(of: node, binding: binding))
                .progressViewStyle(.linear)
                .frame(height: PluginKit.leafHeight("progress", traits: traits))
        case "timer":
            Text(binding.text(node.props["text"] ?? node.props["value"]))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .monospacedDigit()
                .frame(height: PluginKit.leafHeight("timer", traits: traits))
        case "waveform":
            PluginWaveform(active: binding.bool(node.props["text"] ?? node.props["value"])
                && Self.isAnimating(traits))
                .frame(height: PluginKit.leafHeight("waveform", traits: traits))
        case "pulse":
            Circle()
                .fill(PluginStatusTone.tone(for: binding.text(node.props["status"])))
                .frame(width: 8, height: 8)
                .opacity(Self.isAnimating(traits) ? 1 : 0.5)
        default:  // liveText
            Text(PluginTextView.text(of: node, binding: binding))
                .font(.system(size: 12)).monospacedDigit()
                .frame(height: PluginKit.leafHeight("liveText", traits: traits))
        }
    }
}

/// Five bars. Static when the host has no budget, so the strip's shrunk state is quiet.
struct PluginWaveform: View {
    let active: Bool
    @State private var phase: Double = 0

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(Color.accentColor.opacity(0.85))
                    .frame(width: 2.5, height: height(index))
            }
        }
        .animation(active ? .easeInOut(duration: 0.45).repeatForever() : .default, value: phase)
        .onAppear { if active { phase = 1 } }
    }

    private func height(_ index: Int) -> CGFloat {
        let base: [CGFloat] = [8, 16, 11, 19, 9]
        return active ? base[index] : 6
    }
}
