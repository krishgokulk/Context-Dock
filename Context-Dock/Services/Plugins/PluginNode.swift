// Context-Dock
//
// One component in a plugin view tree. The manifest writes a node as a single-key object:
//   { "mediaCard": { "title": "{{room}}" } }     props
//   { "vstack": [ {...}, {...} ] }               children
//   { "title": "Up next" }                       shorthand: props["text"]
// The model does not know which component names exist — PluginComponentCatalog does —
// so a manifest from a newer app still decodes here and fails in PluginSchema with a
// diagnostic that names the component.

import Foundation

struct PluginNode: Codable, Equatable {
    let component: String
    let props: [String: PluginValue]
    let children: [PluginNode]
    /// View nodes held in props rather than in `children`: a list's `row`, a grid's `cell`,
    /// a listDetail's `detail`. They are templates — instantiated per item, never drawn once —
    /// so they are deliberately NOT children. Keyed by the prop name so a diagnostic can say
    /// `row` rather than an index. Derived from `props`, so `Equatable` needs no special case.
    let nodeProps: [String: PluginNode]

    init(component: String, props: [String: PluginValue] = [:], children: [PluginNode] = []) {
        self.component = component
        self.props = props
        self.children = children
        self.nodeProps = Self.nodeProps(from: props)
    }

    private static func nodeProps(from props: [String: PluginValue]) -> [String: PluginNode] {
        props.reduce(into: [:]) { out, pair in
            if let node = PluginComponentCatalog.nodeProp(key: pair.key, value: pair.value) {
                out[pair.key] = node
            }
        }
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard c.allKeys.count == 1, let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "A node is one object with exactly one key (the component); found \(c.allKeys.map(\.stringValue).sorted())"))
        }
        component = key.stringValue
        let body = try c.decode(PluginValue.self, forKey: key)
        switch body {
        case .object(let o):
            var props = o
            var kids: [PluginNode] = []
            if let childValues = o["children"]?.arrayValue {
                kids = try childValues.map { try PluginNode(value: $0) }
                props["children"] = nil
            }
            self.props = props
            self.children = kids
            self.nodeProps = Self.nodeProps(from: props)
        case .array(let a):
            props = [:]
            children = try a.map { try PluginNode(value: $0) }
            nodeProps = [:]
        case .string, .number, .bool:
            props = ["text": body]
            children = []
            nodeProps = [:]
        case .null:
            props = [:]
            children = []
            nodeProps = [:]
        }
    }

    /// Re-enter decoding for a child that arrived as an already-decoded value.
    init(value: PluginValue) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(PluginNode.self, from: data)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        if children.isEmpty {
            try c.encode(PluginValue.object(props), forKey: AnyKey(stringValue: component))
        } else if props.isEmpty {
            try c.encode(children, forKey: AnyKey(stringValue: component))
        } else {
            var o = props
            o["children"] = .array(try children.map { child in
                let data = try JSONEncoder().encode(child)
                return try JSONDecoder().decode(PluginValue.self, from: data)
            })
            try c.encode(PluginValue.object(o), forKey: AnyKey(stringValue: component))
        }
    }

    /// Every node in the tree, depth first, self included — children and node props alike,
    /// so a validator that walks this reaches a list's row template (#27).
    var flattened: [PluginNode] {
        [self] + children.flatMap(\.flattened)
            + nodeProps.sorted { $0.key < $1.key }.flatMap { $0.value.flattened }
    }
}
