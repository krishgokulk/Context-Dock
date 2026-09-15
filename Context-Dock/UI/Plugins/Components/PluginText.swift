// Context-Dock
//
// Every way a plugin says something in words. A manifest may write the shorthand
// (`{ "title": "Up next" }`, which decodes into props["text"]) or the long form
// (`{ "title": { "text": "{{heading}}" } }`); both read the same here, so a manifest author
// never has to know which spelling the renderer prefers.

import SwiftUI

struct PluginStatModel: Equatable {
    let value: String
    let label: String
    let delta: String
}

struct PluginTextView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding

    static func text(of node: PluginNode, binding: PluginBinding) -> String {
        binding.text(node.props["text"] ?? node.props["title"] ?? node.props["value"])
    }

    static func stat(of node: PluginNode, binding: PluginBinding) -> PluginStatModel {
        PluginStatModel(
            value: binding.text(node.props["value"] ?? node.props["text"]),
            label: binding.text(node.props["label"]),
            delta: binding.text(node.props["delta"]))
    }

    var body: some View {
        switch node.component {
        case "title":
            Text(Self.text(of: node, binding: binding))
                .font(.system(size: 15, weight: .semibold)).lineLimit(1)
        case "subtitle":
            Text(Self.text(of: node, binding: binding))
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        case "body":
            Text(Self.text(of: node, binding: binding)).font(.system(size: 12))
        case "caption":
            Text(Self.text(of: node, binding: binding))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        case "markdown":
            Text(LocalizedStringKey(Self.text(of: node, binding: binding))).font(.system(size: 12))
        case "stat":
            let model = Self.stat(of: node, binding: binding)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(model.value).font(.system(size: 22, weight: .semibold))
                    if !model.delta.isEmpty {
                        Text(model.delta).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Text(model.label).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        default:  // header
            HStack(spacing: 8) {
                let icon = binding.text(node.props["icon"])
                if !icon.isEmpty { Image(systemName: icon) }
                Text(Self.text(of: node, binding: binding))
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                if let trailing = node.props["trailing"] {
                    Text(binding.text(trailing)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(height: PluginKit.leafHeight("header", traits: traits))
        }
    }
}
