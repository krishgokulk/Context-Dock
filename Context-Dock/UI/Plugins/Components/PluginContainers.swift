// Context-Dock
//
// The boxes everything else sits in. Spacing and radius come from PluginKit, so a plugin
// cannot style its way out of looking like the app.

import SwiftUI

struct PluginContainerView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding
    weak var sink: (any PluginActionSink)?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch node.component {
        case "capsule" where traits.isIcon:
            // In one strip slot a capsule cannot lay its children side by side — a thumbnail
            // beside a waveform is twice the slot. The first child is the icon and fills the
            // square; whatever follows sits on it as a badge along the bottom edge, the way
            // a Dock icon carries its progress bar.
            ZStack(alignment: .bottom) {
                if let first = node.children.first {
                    PluginRenderer(node: first, traits: traits, binding: binding, sink: sink)
                }
                if node.children.count > 1 {
                    HStack(spacing: 2) {
                        ForEach(Array(node.children.dropFirst().enumerated()), id: \.offset) {
                            _, child in
                            PluginRenderer(node: child, traits: traits, binding: binding, sink: sink)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 2)
                }
            }
            .frame(width: PluginStripIcon.content, height: PluginStripIcon.content)
            .clipShape(RoundedRectangle(cornerRadius: PluginStripIcon.radius, style: .continuous))
        case "hstack", "capsule":
            HStack(spacing: PluginKit.gap(traits)) { children }
        case "card", "footerCard":
            VStack(alignment: .leading, spacing: PluginKit.gap) { children }
                .padding(PluginKit.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: PluginKit.cornerRadius, style: .continuous)
                        .fill(node.component == "footerCard"
                            ? Theme.surface(scheme == .dark)
                            : Theme.surfaceElevated(scheme == .dark)))
                .overlay(
                    RoundedRectangle(cornerRadius: PluginKit.cornerRadius, style: .continuous)
                        .strokeBorder(Theme.border(scheme == .dark), lineWidth: 0.5))
        case "divider":
            Rectangle().fill(Theme.separator(scheme == .dark))
                .frame(height: 1)
                .padding(.vertical, 4)
        default:  // vstack
            VStack(alignment: .leading, spacing: PluginKit.gap(traits)) { children }
        }
    }

    @ViewBuilder
    private var children: some View {
        ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
            PluginRenderer(node: child, traits: traits, binding: binding, sink: sink)
        }
    }
}
