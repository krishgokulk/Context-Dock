// Context-Dock
//
// How tall a plugin is, as arithmetic. The corner's shell asks this before anything is drawn,
// so it must be a pure function of manifest + binding + traits — never a measurement, or the
// shell's drawing and its hit-testing drift apart (memory `corner-pill-size-must-be-pure`).

import CoreGraphics
import Foundation

enum PluginSizing {
    /// The height of one node, its children included.
    static func height(of node: PluginNode, traits: HostTraits, binding: PluginBinding) -> CGFloat {
        switch node.component {
        case "vstack", "form", "actionPanel", "detail", "listDetail", "capsule":
            return stacked(node.children, traits: traits, binding: binding)

        case "hstack":
            let heights = node.children.map { height(of: $0, traits: traits, binding: binding) }
            return heights.max() ?? 0

        case "card", "footerCard":
            let inner = stacked(node.children, traits: traits, binding: binding)
            return inner + PluginKit.cardPadding * 2

        case "section":
            let inner = stacked(node.children, traits: traits, binding: binding)
            guard node.props["header"] != nil else { return inner }
            return PluginKit.sectionHeaderHeight + PluginKit.gap + inner

        case "list":
            let rows = binding.items(node.props["items"])
            guard !rows.isEmpty else {
                return PluginKit.leafHeight("emptyState", traits: traits)
            }
            let each = childNode(node, key: "row")
                .map { height(of: $0, traits: traits, binding: binding) }
                ?? PluginKit.rowHeight(traits)
            return each * CGFloat(rows.count)

        case "grid":
            let cells = binding.items(node.props["items"])
            guard !cells.isEmpty else {
                return PluginKit.leafHeight("emptyState", traits: traits)
            }
            let declared = Int(binding.number(node.props["columns"]) ?? 3)
            let columns = PluginKit.gridColumns(declared, traits: traits)
            let rows = Int(ceil(Double(cells.count) / Double(columns)))
            let cell = childNode(node, key: "cell")
                .map { height(of: $0, traits: traits, binding: binding) }
                ?? PluginKit.leafHeight("cell", traits: traits)
            return cell * CGFloat(rows) + PluginKit.gap * CGFloat(max(0, rows - 1))

        default:
            if !node.children.isEmpty {
                return stacked(node.children, traits: traits, binding: binding)
            }
            return PluginKit.leafHeight(node.component, traits: traits)
        }
    }

    /// The whole view, never taller than the host allows — a list of two hundred rows scrolls
    /// inside the host rather than growing a panel off the screen.
    static func treeHeight(_ root: PluginNode, traits: HostTraits, binding: PluginBinding)
        -> CGFloat
    {
        min(height(of: root, traits: traits, binding: binding), traits.maxHeight)
    }

    /// A prop that is itself a node — a list's `row`, a grid's `cell`, a listDetail's `detail`.
    ///
    /// A map lookup, not a decode: #27 made these nodes on the parent at decode time, so the
    /// renderer reads the same object the schema validated. The earlier plan re-decoded the
    /// raw `PluginValue` here, which was both a second spelling of the conversion and an
    /// encode+decode per nested node on every redraw.
    static func childNode(_ node: PluginNode, key: String) -> PluginNode? {
        node.nodeProps[key]
    }

    private static func stacked(
        _ children: [PluginNode], traits: HostTraits, binding: PluginBinding
    ) -> CGFloat {
        guard !children.isEmpty else { return 0 }
        let total = children.reduce(CGFloat.zero) {
            $0 + height(of: $1, traits: traits, binding: binding)
        }
        return total + PluginKit.gap * CGFloat(children.count - 1)
    }
}
