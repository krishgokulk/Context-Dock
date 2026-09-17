// Context-Dock
//
// The contract between what a script printed and what a view tree says. "{{room}}" is the
// whole of it: a whole-string binding becomes the value itself (so a number stays a number),
// a binding inside a sentence is interpolated as text, and inside a repeated row "{{item.*}}"
// reaches the row while the outer data stays reachable. A key that is not there is `.null`,
// never a crash and never the literal "{{room}}" on screen. Spec §7.

import Foundation

struct PluginBinding: Equatable {
    var data: [String: PluginValue]
    var item: PluginValue?

    init(data: [String: PluginValue] = [:], item: PluginValue? = nil) {
        self.data = data
        self.item = item
    }

    /// The same data, with `item.*` now pointing at this row.
    func scoped(to item: PluginValue) -> PluginBinding {
        PluginBinding(data: data, item: item)
    }

    func value(atPath path: String) -> PluginValue {
        var segments = path.split(separator: ".").map(String.init)
        guard !segments.isEmpty else { return .null }
        var current: PluginValue
        if segments[0] == "item" {
            guard let item else { return .null }
            current = item
            segments.removeFirst()
        } else {
            guard let root = data[segments[0]] else { return .null }
            current = root
            segments.removeFirst()
        }
        for segment in segments {
            switch current {
            case .object(let o):
                guard let next = o[segment] else { return .null }
                current = next
            case .array(let a):
                guard let index = Int(segment), a.indices.contains(index) else { return .null }
                current = a[index]
            default:
                return .null
            }
        }
        return current
    }

    /// Whole-string bindings keep their type; everything else resolves in place.
    func resolve(_ value: PluginValue) -> PluginValue {
        switch value {
        case .string(let raw):
            if let key = value.bindingKey { return self.value(atPath: key) }
            guard raw.contains("{{") else { return value }
            return .string(interpolate(raw))
        case .array(let a):
            return .array(a.map(resolve))
        case .object(let o):
            return .object(o.mapValues(resolve))
        case .number, .bool, .null:
            return value
        }
    }

    func text(_ value: PluginValue?) -> String {
        guard let value else { return "" }
        switch resolve(value) {
        case .string(let s): return s
        case .number(let n):
            return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return ""
        case .array(let a): return a.map { text($0) }.joined(separator: ", ")
        case .object: return ""
        }
    }

    func number(_ value: PluginValue?) -> Double? {
        guard let value else { return nil }
        switch resolve(value) {
        case .number(let n): return n
        case .string(let s): return Double(s)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    /// What a manifest means by truth: a bool, a non-zero number, or a word a person would
    /// write in JSON by hand.
    func bool(_ value: PluginValue?) -> Bool {
        guard let value else { return false }
        switch resolve(value) {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return ["true", "yes", "on", "1"].contains(s.lowercased())
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        case .null: return false
        }
    }

    /// A repeated list. Anything that is not an array repeats zero times — a `list` whose
    /// items key is missing is empty, not broken.
    func items(_ value: PluginValue?) -> [PluginValue] {
        guard let value else { return [] }
        if case .array(let a) = resolve(value) { return a }
        return []
    }

    private func interpolate(_ raw: String) -> String {
        var out = ""
        var rest = Substring(raw)
        while let open = rest.range(of: "{{") {
            out += rest[rest.startIndex..<open.lowerBound]
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "}}") else {
                out += rest[open.lowerBound...]
                return out
            }
            let key = after[after.startIndex..<close.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            out += text(value(atPath: key))
            rest = after[close.upperBound...]
        }
        return out + rest
    }
}
