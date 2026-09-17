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
        case "hstack", "capsule":
            HStack(spacing: PluginKit.gap) { children }
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
            VStack(alignment: .leading, spacing: PluginKit.gap) { children }
        }
    }

    @ViewBuilder
    private var children: some View {
        ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
            PluginRenderer(node: child, traits: traits, binding: binding, sink: sink)
        }
    }
}
