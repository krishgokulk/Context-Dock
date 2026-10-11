// Context-Dock
//
// Small status-bearing text: a tag, a status badge, a row of chips, a segmented row.

import SwiftUI

enum PluginStatusTone {
    static let neutral = Color.secondary

    /// The six words spec §6 fixes, each with its own tone. Matching is case-insensitive
    /// because the words come out of a script rather than out of a picker. An unknown word is
    /// neutral — a plugin that invents a status still renders, it just does not get a colour.
    static func tone(for word: String) -> Color {
        switch word.lowercased() {
        case "pending": return .orange
        case "running": return .blue
        case "success": return .green
        case "failed": return .red
        case "expired": return .purple
        case "waiting": return .yellow
        default: return neutral
        }
    }
}

struct PluginChipView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding

    /// The words a chip row or a segment shows. Resolved to strings here rather than carried
    /// as values, because `PluginValue` is not Hashable and a list of chips needs stable ids.
    private func words(_ value: PluginValue?) -> [String] {
        binding.items(value).map { binding.text($0) }
    }

    var body: some View {
        switch node.component {
        case "statusBadge":
            let word = PluginTextView.text(of: node, binding: binding)
            chip(word, tone: PluginStatusTone.tone(for: word))
        case "chipRow":
            let items = words(node.props["items"] ?? node.props["text"])
            HStack(spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, word in
                    chip(word, tone: PluginStatusTone.neutral)
                }
            }
            .frame(height: PluginKit.leafHeight("chipRow", traits: traits))
        case "segment":
            let items = words(node.props["items"])
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, word in
                    Text(word).font(.system(size: 11))
                        .padding(.horizontal, 10).frame(height: 24)
                }
            }
        default:  // tag
            chip(
                PluginTextView.text(of: node, binding: binding),
                tone: PluginStatusTone.tone(for: binding.text(node.props["color"])))
        }
    }

    private func chip(_ text: String, tone: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Capsule().fill(tone.opacity(0.16)))
            .overlay(Capsule().strokeBorder(tone.opacity(0.35), lineWidth: 0.5))
            .foregroundStyle(tone == PluginStatusTone.neutral ? Color.secondary : tone)
    }
}
