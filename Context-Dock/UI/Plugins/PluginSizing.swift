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
        case "vstack", "actionPanel", "capsule":
            return stacked(node.children, traits: traits, binding: binding)

        // The three that keep their content in props rather than in children. Measuring them
        // as stacks of children makes every one of them nothing high, and the panel holding
        // one collapses — which looks exactly like a plugin that returned no data.
        case "form":
            let fields = (node.props["fields"]?.arrayValue ?? []).compactMap { value -> String? in
                guard let object = value.objectValue else { return nil }
                let kind = object["kind"]?.stringValue ?? "text"
                return PluginFormField(key: "", label: "", kind: kind).component
            }
            let submit = node.props["submit"] == nil
                ? 0 : PluginKit.leafHeight("button", traits: traits)
            let rows = fields.reduce(CGFloat.zero) {
                $0 + PluginKit.leafHeight($1, traits: traits)
            }
            let pieces = fields.count + (submit > 0 ? 1 : 0)
            return rows + submit + PluginKit.gap * CGFloat(max(0, pieces - 1))

        case "detail":
            return detailHeight(of: node, traits: traits)

        case "listDetail":
            // Side by side: as tall as whichever side wins, and which side that is changes
            // with the data rather than with the manifest.
            let items = binding.items(node.props["items"])
            let rowHeight = childNode(node, key: "row")
                .map { height(of: $0, traits: traits, binding: binding) }
                ?? PluginKit.rowHeight(traits)
            let list = rowHeight * CGFloat(items.count)
            let detail = childNode(node, key: "detail")
                .map { detailHeight(of: $0, traits: traits) } ?? 0
            return max(list, detail)

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

    /// A detail is its markdown and one line per metadata entry. Metadata is a data array in
    /// props, not children, so it is counted here rather than walked as a tree.
    private static func detailHeight(of node: PluginNode, traits: HostTraits) -> CGFloat {
        let markdown = node.props["markdown"] == nil
            ? 0 : PluginKit.leafHeight("markdown", traits: traits)
        let lines = node.props["metadata"]?.arrayValue?.count ?? 0
        let metadata = PluginKit.leafHeight("caption", traits: traits) * CGFloat(lines)
        let pieces = (markdown > 0 ? 1 : 0) + lines
        return markdown + metadata + PluginKit.gap * CGFloat(max(0, pieces - 1))
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
