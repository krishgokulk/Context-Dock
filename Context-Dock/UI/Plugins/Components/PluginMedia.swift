// Context-Dock
//
// Artwork and the now-playing card. Media is read as a model first, so the corner and the
// dock cannot disagree about which track is playing.

import SwiftUI

struct PluginMediaModel: Equatable {
    let title: String
    let artist: String
    let track: String
    let art: String
    let transport: String
    let volume: String
}

struct PluginMediaView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding
    weak var sink: (any PluginActionSink)?

    static func model(of node: PluginNode, binding: PluginBinding) -> PluginMediaModel {
        PluginMediaModel(
            title: binding.text(node.props["title"] ?? node.props["text"]),
            artist: binding.text(node.props["artist"]),
            track: binding.text(node.props["track"]),
            art: binding.text(node.props["art"] ?? node.props["image"]),
            transport: binding.text(node.props["transport"]),
            volume: binding.text(node.props["volume"]))
    }

    var body: some View {
        switch node.component {
        case "thumbnail", "cell":
            // A `cell` is a grid's template. It draws whatever it holds, and falls back to
            // artwork when it holds nothing — the shorthand `"cell": { "thumbnail": {} }`.
            PluginCellView(node: node, traits: traits, binding: binding, sink: sink)
        case "avatar":
            PluginArtwork(source: binding.text(node.props["text"] ?? node.props["src"]))
                .clipShape(Circle())
                .frame(width: 36, height: 36)
        default:  // mediaCard
            let model = Self.model(of: node, binding: binding)
            HStack(spacing: 10) {
                PluginArtwork(source: model.art).frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if !model.track.isEmpty {
                        Text(model.track).font(.system(size: 12)).lineLimit(1)
                    }
                    if !model.artist.isEmpty {
                        Text(model.artist).font(.system(size: 11))
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if !model.transport.isEmpty {
                    Button {
                        sink?.run(PluginActionRequest(name: model.transport))
                    } label: { Image(systemName: "playpause.fill") }
                        .buttonStyle(.plain)
                }
            }
            .frame(height: PluginKit.leafHeight("mediaCard", traits: traits))
        }
    }
}

/// A thumbnail, or a grid cell that may hold one. `cell` reaches here with its content in
/// `nodeProps` (#27), so it draws that rather than guessing.
struct PluginCellView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding
    weak var sink: (any PluginActionSink)?

    /// What a cell holds. Three spellings reach here and all three are ordinary:
    /// children, an object-valued prop (`"thumbnail": { "src": … }`, a nodeProp per #27), and
    /// the bare-string shorthand (`"thumbnail": "{{item.art}}"`) that PluginNode itself accepts
    /// for any component's text. Missing the third drew every grid cell as a placeholder.
    static func content(of node: PluginNode) -> [PluginNode] {
        let shorthand = node.props
            .filter { PluginComponentCatalog.isKnown($0.key) && $0.value.stringValue != nil }
            .sorted { $0.key < $1.key }
            .map { PluginNode(component: $0.key, props: ["text": $0.value]) }
        return node.children
            + node.nodeProps.sorted { $0.key < $1.key }.map(\.value)
            + shorthand
    }

    var body: some View {
        let inner = Self.content(of: node)
        if inner.isEmpty {
            PluginArtwork(source: binding.text(node.props["text"] ?? node.props["src"]))
                .frame(
                    width: PluginKit.leafHeight("thumbnail", traits: traits),
                    height: PluginKit.leafHeight("thumbnail", traits: traits))
        } else {
            VStack(spacing: 4) {
                ForEach(Array(inner.enumerated()), id: \.offset) { _, child in
                    PluginRenderer(node: child, traits: traits, binding: binding, sink: sink)
                }
            }
            .frame(height: PluginKit.leafHeight(node.component, traits: traits))
        }
    }
}

/// Artwork from a file path or an SF Symbol name. No network in Phase 2 — an `http` art URL
/// renders as the placeholder until Phase 3 fetches it under the declared permission.
struct PluginArtwork: View {
    let source: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if source.hasPrefix("/"), let image = NSImage(contentsOfFile: source) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if !source.isEmpty,
                NSImage(systemSymbolName: source, accessibilityDescription: nil) != nil {
                Image(systemName: source).font(.system(size: 20)).foregroundStyle(.secondary)
            } else {
                Image(systemName: "photo").font(.system(size: 16)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface(scheme == .dark))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
