// Context-Dock
//
// What the corner does differently, as one pure transform over the tree rather than as `if
// compact` scattered through fifteen component views. The renderer applies it once at the root;
// every component below sees a tree that already means what the corner can show. Spec §5.

import Foundation

enum PluginCompactRules {
    static func apply(to root: PluginNode, traits: HostTraits) -> PluginNode {
        guard traits.widthClass == .compact else { return root }
        return transform(root, traits: traits)
    }

    private static func transform(_ node: PluginNode, traits: HostTraits) -> PluginNode {
        var props = node.props
        var component = node.component

        switch node.component {
        case "listDetail":
            // The split cannot fit: the list stays, and the detail becomes a push.
            component = "list"
            if props["detail"] != nil, let row = PluginSizing.childNode(node, key: "row") {
                var rowProps = row.props
                var actions = rowProps["actions"]?.arrayValue ?? []
                actions.append(.object([
                    "title": .string("Details"), "action": .string("push:detail"),
                ]))
                rowProps["actions"] = .array(actions)
                props["row"] = .object(rowProps)
            }

        case "grid":
            let declared = Int(props["columns"]?.numberValue ?? 3)
            props["columns"] = .number(Double(PluginKit.gridColumns(declared, traits: traits)))

        case "row", "fileRow", "checkRow":
            // Metadata stacks: accessories join the subtitle instead of competing for width.
            if let accessories = props["accessories"]?.arrayValue, !accessories.isEmpty {
                let extras = accessories.compactMap { $0.stringValue }
                let subtitle = props["subtitle"]?.stringValue ?? ""
                let joined = ([subtitle] + extras).filter { !$0.isEmpty }.joined(separator: " · ")
                props["subtitle"] = .string(joined)
                props["accessories"] = nil
            }

        default:
            break
        }

        // The templates — a list's `row`, a grid's `cell`, a listDetail's `detail` — live in
        // props, not in children. A transform that walks only children never reaches a single
        // row a person sees, because every row a person sees is one of these.
        for (key, child) in node.nodeProps {
            // `row` is already rewritten above when a detail was folded into it.
            if component == "list", key == "row", props["row"] != node.props["row"] { continue }
            props[key] = write(transform(child, traits: traits), under: key)
        }

        return PluginNode(
            component: component, props: props,
            children: node.children.map { transform($0, traits: traits) })
    }

    /// Put a node back under the prop it came from, in the spelling it arrived in. A key that
    /// names a component holds that component's props directly (`"row": { "title": … }`);
    /// any other key holds a whole node (`"leading": { "thumbnail": { … } }`), and flattening
    /// that one would turn a thumbnail into a component called `leading`.
    private static func write(_ node: PluginNode, under key: String) -> PluginValue {
        if PluginComponentCatalog.isKnown(key), node.component == key {
            return .object(node.props)
        }
        return .object([node.component: .object(node.props)])
    }
}
