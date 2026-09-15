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

    init(component: String, props: [String: PluginValue] = [:], children: [PluginNode] = []) {
        self.component = component
        self.props = props
        self.children = children
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
        case .array(let a):
            props = [:]
            children = try a.map { try PluginNode(value: $0) }
        case .string, .number, .bool:
            props = ["text": body]
            children = []
        case .null:
            props = [:]
            children = []
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

    /// Every node in the tree, depth first, self included.
    var flattened: [PluginNode] { [self] + children.flatMap(\.flattened) }
}
