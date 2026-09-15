// Context-Dock
//
// The Raycast-class half of the kit: a list of rows, sections over them, and the ⌘K action
// panel. Rows are built as models first and drawn second, because Phase 5 indexes the same
// models into search and must not re-derive them from the view.

import SwiftUI

struct PluginRowAction: Equatable, Identifiable {
    let title: String
    let request: PluginActionRequest
    var id: String { title + request.name }
}

struct PluginRowModel: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String?
    let accessories: [String]
    let actions: [PluginRowAction]

    /// One row from one item. `node` is the manifest's `row` template; `binding` is already
    /// scoped to the item.
    static func make(from node: PluginNode, binding: PluginBinding, index: Int) -> PluginRowModel {
        let actions = (node.props["actions"]?.arrayValue ?? [])
            .compactMap { value -> PluginRowAction? in
                guard let object = value.objectValue else { return nil }
                let name = binding.text(object["action"])
                guard !name.isEmpty else { return nil }
                let resolved = object["value"].map { binding.resolve($0) }
                return PluginRowAction(
                    title: binding.text(object["title"]),
                    request: PluginActionRequest(name: name, value: resolved))
            }
        let explicitID = binding.text(node.props["id"])
        let iconName = binding.text(node.props["icon"])
        return PluginRowModel(
            id: explicitID.isEmpty ? "row-\(index)" : explicitID,
            title: binding.text(node.props["title"] ?? node.props["text"]),
            subtitle: binding.text(node.props["subtitle"]),
            icon: iconName.isEmpty ? nil : iconName,
            accessories: binding.items(node.props["accessories"]).map { binding.text($0) },
            actions: actions)
    }
}

struct PluginListView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding
    weak var sink: (any PluginActionSink)?
    var query: String = ""

    /// The row template a list repeats. Read once per call from `nodeProps` and handed to the
    /// loop. A list with no template still names its items — a migrated `provider:custom` list
    /// leans on this, and without it a list with data draws a column of blanks.
    static func rowTemplate(of node: PluginNode) -> PluginNode {
        PluginSizing.childNode(node, key: "row")
            ?? PluginNode(component: "row", props: ["title": .string("{{item.title}}")])
    }

    /// `filter: local` narrows in place while typing; `filter: query` leaves the rows alone
    /// because the data script is the one that gets the query (spec §7).
    static func rowModels(for node: PluginNode, binding: PluginBinding, query: String = "")
        -> [PluginRowModel]
    {
        let template = rowTemplate(of: node)
        let models = binding.items(node.props["items"]).enumerated().map { index, item in
            PluginRowModel.make(from: template, binding: binding.scoped(to: item), index: index)
        }
        let isLocal = binding.text(node.props["filter"]) == "local"
        guard isLocal, !query.isEmpty else { return models }
        let needle = query.lowercased()
        return models.filter {
            $0.title.lowercased().contains(needle) || $0.subtitle.lowercased().contains(needle)
        }
    }

    @MainActor
    static func perform(_ action: PluginRowAction, sink: (any PluginActionSink)?) {
        sink?.run(action.request)
    }

    var body: some View {
        let models = Self.rowModels(for: node, binding: binding, query: query)
        if models.isEmpty {
            PluginEmptyStateView(title: "No results", message: "", traits: traits)
        } else {
            VStack(spacing: 0) {
                ForEach(models) { model in
                    PluginRowView(model: model, traits: traits, sink: sink)
                }
            }
        }
    }
}

struct PluginRowView: View {
    let model: PluginRowModel
    let traits: HostTraits
    weak var sink: (any PluginActionSink)?

    var body: some View {
        HStack(spacing: 8) {
            if let icon = model.icon {
                Image(systemName: icon).frame(width: 18)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if !model.subtitle.isEmpty {
                    Text(model.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            ForEach(model.accessories, id: \.self) { accessory in
                Text(accessory).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: PluginKit.rowHeight(traits))
        .contentShape(Rectangle())
        .onTapGesture {
            if let first = model.actions.first { PluginListView.perform(first, sink: sink) }
        }
    }
}

struct PluginSectionView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding
    weak var sink: (any PluginActionSink)?

    var body: some View {
        VStack(alignment: .leading, spacing: PluginKit.gap) {
            if let header = node.props["header"] {
                Text(binding.text(header).uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(height: PluginKit.sectionHeaderHeight, alignment: .leading)
            }
            ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
                PluginRenderer(node: child, traits: traits, binding: binding, sink: sink)
            }
        }
    }
}

/// ⌘K. In the corner this is the only home secondary actions have (spec §5).
struct PluginActionPanelView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding
    weak var sink: (any PluginActionSink)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
                let title = binding.text(child.props["title"])
                let name = binding.text(child.props["action"])
                Button(title.isEmpty ? name : title) {
                    sink?.run(PluginActionRequest(
                        name: name, value: child.props["value"].map { binding.resolve($0) }))
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .frame(height: 28)
            }
        }
    }
}
