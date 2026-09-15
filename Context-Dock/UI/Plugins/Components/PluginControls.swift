// Context-Dock
//
// The things a plugin can be touched by: buttons, a toggle, a slider, and the two-or-more
// state button. Every one of them turns into exactly one PluginActionRequest, built in one
// place, so Phase 3 has a single hook for optimistic state.

import SwiftUI

struct PluginControlState: Equatable, Identifiable {
    let title: String
    let request: PluginActionRequest
    var id: String { title + request.name }
}

struct PluginControlView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding
    weak var sink: (any PluginActionSink)?
    /// What the person has done to this control since it was drawn. `nil` means they have not
    /// touched it, so the bound data still speaks for it.
    @State private var touchedBool: Bool?
    @State private var touchedNumber: Double?

    /// The single place a control becomes an action. Phase 3 hangs optimistic state here.
    static func request(of node: PluginNode, binding: PluginBinding) -> PluginActionRequest? {
        let name = binding.text(node.props["action"] ?? node.props["onTap"])
        guard !name.isEmpty else { return nil }
        return PluginActionRequest(
            name: name, value: node.props["value"].map { binding.resolve($0) })
    }

    /// Where a toggle starts. A control drawn against data must show that data — a light that
    /// is already on cannot draw as off until somebody touches it.
    static func initialBool(of node: PluginNode, binding: PluginBinding) -> Bool {
        binding.bool(node.props["value"] ?? node.props["checked"] ?? node.props["state"])
    }

    static func initialNumber(of node: PluginNode, binding: PluginBinding) -> Double {
        binding.number(node.props["value"]) ?? 0
    }

    static func states(of node: PluginNode, binding: PluginBinding) -> [PluginControlState] {
        (node.props["states"]?.arrayValue ?? []).compactMap { value in
            guard let object = value.objectValue else { return nil }
            let name = binding.text(object["action"])
            guard !name.isEmpty else { return nil }
            return PluginControlState(
                title: binding.text(object["title"]),
                request: PluginActionRequest(
                    name: name, value: object["value"].map { binding.resolve($0) }))
        }
    }

    /// Which state a state button is showing. A bool picks the second state, a number picks by
    /// index — the only way a three-state control can say which one it is in — and anything
    /// past the end falls back to the first rather than drawing an empty button.
    static func currentIndex(of node: PluginNode, binding: PluginBinding) -> Int {
        let count = states(of: node, binding: binding).count
        guard count > 0 else { return 0 }
        let state = node.props["state"].map { binding.resolve($0) } ?? .null
        let index: Int
        switch state {
        case .number(let n): index = Int(n)
        case .bool(let on): index = on ? 1 : 0
        default: index = 0
        }
        return (0..<count).contains(index) ? index : 0
    }

    @MainActor
    static func send(_ request: PluginActionRequest, sink: (any PluginActionSink)?) {
        sink?.run(request)
    }

    var body: some View {
        switch node.component {
        case "toggle":
            Toggle(PluginTextView.text(of: node, binding: binding), isOn: Binding(
                get: { touchedBool ?? Self.initialBool(of: node, binding: binding) },
                set: { newValue in
                    touchedBool = newValue
                    if let name = Self.request(of: node, binding: binding)?.name {
                        Self.send(PluginActionRequest(name: name, value: .bool(newValue)), sink: sink)
                    }
                }))
                .font(.system(size: 12))
        case "slider":
            Slider(value: Binding(
                get: { touchedNumber ?? Self.initialNumber(of: node, binding: binding) },
                set: { newValue in
                    touchedNumber = newValue
                    if let name = Self.request(of: node, binding: binding)?.name {
                        Self.send(
                            PluginActionRequest(name: name, value: .number(newValue)), sink: sink)
                    }
                }), in: 0...100)
                .controlSize(.small)
        case "stateButton":
            let states = Self.states(of: node, binding: binding)
            let index = Self.currentIndex(of: node, binding: binding)
            let state = states.indices.contains(index) ? states[index] : states.first
            Button(state?.title ?? "") {
                if let state { Self.send(state.request, sink: sink) }
            }
            .font(.system(size: 12, weight: .medium))
        case "iconButton":
            Button {
                if let request = Self.request(of: node, binding: binding) {
                    Self.send(request, sink: sink)
                }
            } label: {
                Image(systemName: binding.text(node.props["icon"]))
            }
            .buttonStyle(.plain)
        case "buttonRow":
            HStack(spacing: PluginKit.gap) {
                ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
                    PluginControlView(node: child, traits: traits, binding: binding, sink: sink)
                }
            }
        default:  // button
            Button(PluginTextView.text(of: node, binding: binding)) {
                if let request = Self.request(of: node, binding: binding) {
                    Self.send(request, sink: sink)
                }
            }
            .font(.system(size: 12, weight: .medium))
        }
    }
}
