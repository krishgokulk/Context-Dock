// Context-Dock
//
// The views that show one thing in depth: a list beside a detail (which the corner turns into
// a push, Task 9), a detail on its own, a grid of cells, and a form. The detail's markdown and
// metadata are read as a model so the corner and the dock cannot render different text.

import Observation
import SwiftUI

struct PluginMetadataItem: Equatable, Identifiable {
    let title: String
    let text: String
    var id: String { title + text }
}

struct PluginDetailModel: Equatable {
    let markdown: String
    let metadata: [PluginMetadataItem]

    /// Read a detail out of a node's props, against a binding already scoped to whichever
    /// item it belongs to. One reader, so a detail on its own and a detail beside a list can
    /// never show different text for the same data.
    static func make(from node: PluginNode, binding: PluginBinding) -> PluginDetailModel {
        let metadata = (node.props["metadata"]?.arrayValue ?? []).compactMap {
            value -> PluginMetadataItem? in
            guard let object = value.objectValue else { return nil }
            return PluginMetadataItem(
                title: binding.text(object["title"]), text: binding.text(object["text"]))
        }
        return PluginDetailModel(
            markdown: binding.text(node.props["markdown"]), metadata: metadata)
    }
}

struct PluginListDetailView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding
    weak var sink: (any PluginActionSink)?
    @State private var selection: Int = 0

    /// The detail for one row. `nil` when the selection is past the end, which happens every
    /// time a refresh returns fewer items than the last one did.
    static func detail(for node: PluginNode, binding: PluginBinding, selection: Int)
        -> PluginDetailModel?
    {
        let items = binding.items(node.props["items"])
        guard items.indices.contains(selection),
            let template = PluginSizing.childNode(node, key: "detail")
        else { return nil }
        return PluginDetailModel.make(from: template, binding: binding.scoped(to: items[selection]))
    }

    var body: some View {
        let models = PluginListView.rowModels(for: node, binding: binding)
        HStack(alignment: .top, spacing: PluginKit.gap) {
            VStack(spacing: 0) {
                ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                    PluginRowView(model: model, traits: traits, sink: sink)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(index == selection
                                    ? Color.accentColor.opacity(0.16) : Color.clear))
                        .onTapGesture { selection = index }
                }
            }
            // The list keeps a readable column and the detail takes the rest; a 0.4 split of
            // a narrow host leaves neither side able to show a title.
            .frame(width: max(200, traits.width * 0.4))
            if let detail = Self.detail(for: node, binding: binding, selection: selection) {
                PluginDetailBody(detail: detail, traits: traits)
            }
        }
    }
}

struct PluginDetailBody: View {
    let detail: PluginDetailModel
    let traits: HostTraits

    var body: some View {
        VStack(alignment: .leading, spacing: PluginKit.gap) {
            if !detail.markdown.isEmpty {
                Text(LocalizedStringKey(detail.markdown)).font(.system(size: 12))
            }
            ForEach(detail.metadata) { item in
                // Label and value together, not pushed to opposite edges. A greedy Spacer
                // reads as two unrelated words once the host is wide — 640pt of gap between
                // "Artist" and "Casio" is not a pair.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .leading)
                    Text(item.text).font(.system(size: 11))
                    Spacer(minLength: 0)
                }
                .frame(height: PluginKit.leafHeight("caption", traits: traits))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PluginDetailView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding

    var body: some View {
        PluginDetailBody(
            detail: PluginDetailModel.make(from: node, binding: binding), traits: traits)
    }
}

struct PluginGridView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding
    weak var sink: (any PluginActionSink)?

    static func columns(of node: PluginNode, traits: HostTraits, binding: PluginBinding) -> Int {
        PluginKit.gridColumns(Int(binding.number(node.props["columns"]) ?? 3), traits: traits)
    }

    var body: some View {
        let cells = binding.items(node.props["items"])
        let count = Self.columns(of: node, traits: traits, binding: binding)
        let template = PluginSizing.childNode(node, key: "cell")
            ?? PluginNode(component: "thumbnail")
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: PluginKit.gap), count: count),
            spacing: PluginKit.gap
        ) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                PluginRenderer(
                    node: template, traits: traits, binding: binding.scoped(to: cell), sink: sink)
            }
        }
    }
}

struct PluginFormField: Equatable, Identifiable {
    let key: String
    let label: String
    /// `text`, `toggle`, `slider`, `select`
    let kind: String
    var id: String { key }

    /// Which kit component draws this field — the one place the mapping lives, so the form's
    /// height and the form's views cannot disagree about what a `toggle` is.
    var component: String {
        switch kind {
        case "toggle": return "toggle"
        case "slider": return "slider"
        case "select": return "segment"
        default: return "textField"
        }
    }
}

@Observable
final class PluginFormState {
    let fields: [PluginFormField]
    private(set) var values: [String: PluginValue] = [:]

    init(fields: [PluginFormField]) { self.fields = fields }

    func set(_ key: String, _ value: PluginValue) { values[key] = value }

    var payload: PluginValue { .object(values) }
}

struct PluginFormView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding
    weak var sink: (any PluginActionSink)?
    @State private var state: PluginFormState

    init(node: PluginNode, traits: HostTraits, binding: PluginBinding,
         sink: (any PluginActionSink)? = nil) {
        self.node = node
        self.traits = traits
        self.binding = binding
        self.sink = sink
        _state = State(initialValue: PluginFormState(
            fields: PluginFormView.fields(of: node, binding: binding)))
    }

    static func fields(of node: PluginNode, binding: PluginBinding) -> [PluginFormField] {
        (node.props["fields"]?.arrayValue ?? []).compactMap { value in
            guard let object = value.objectValue else { return nil }
            let key = binding.text(object["key"])
            guard !key.isEmpty else { return nil }
            let kind = binding.text(object["kind"])
            return PluginFormField(
                key: key, label: binding.text(object["label"]),
                kind: kind.isEmpty ? "text" : kind)
        }
    }

    /// A form with no `submit` asks for nothing rather than firing an unnamed action.
    @MainActor
    static func submit(
        _ node: PluginNode, state: PluginFormState, binding: PluginBinding,
        sink: (any PluginActionSink)?
    ) {
        let name = binding.text(node.props["submit"])
        guard !name.isEmpty else { return }
        sink?.run(PluginActionRequest(name: name, value: state.payload))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginKit.gap) {
            ForEach(state.fields) { field in
                switch field.kind {
                case "toggle":
                    Toggle(field.label, isOn: Binding(
                        get: { state.values[field.key].map { $0 == .bool(true) } ?? false },
                        set: { state.set(field.key, .bool($0)) }))
                        .font(.system(size: 12))
                default:
                    TextField(field.label, text: Binding(
                        get: { state.values[field.key]?.stringValue ?? "" },
                        set: { state.set(field.key, .string($0)) }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }
            }
            Button("Save") {
                Self.submit(node, state: state, binding: binding, sink: sink)
            }
            .font(.system(size: 12, weight: .medium))
        }
    }
}
