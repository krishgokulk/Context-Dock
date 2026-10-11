// Context-Dock
//
// A JSON value as it appears in a plugin manifest. Strings of the form "{{key}}" are
// bindings into the plugin's data; everything else is literal. The renderer (P2) resolves
// bindings; this type only knows how to recognise one.

import Foundation

enum PluginValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([PluginValue])
    case object([String: PluginValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([PluginValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: PluginValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// "{{ item.title }}" → "item.title". Anything that is not exactly one binding is nil.
    var bindingKey: String? {
        guard case .string(let raw) = self else { return nil }
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("{{"), s.hasSuffix("}}"), s.count > 4 else { return nil }
        let inner = s.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty, !inner.contains("{{") else { return nil }
        return inner
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var arrayValue: [PluginValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: PluginValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
}
