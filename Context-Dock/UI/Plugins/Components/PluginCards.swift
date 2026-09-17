// Context-Dock
//
// The card rows from the owner's UI board: a calendar event, an activity line, a file, a
// checklist item, a before/after comparison. Each reads its own props and is exactly the
// height the kit says it is.

import SwiftUI

struct PluginEventModel: Equatable {
    let title: String
    let timeRange: String
    let durationChip: String
}

struct PluginCardRowView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding
    weak var sink: (any PluginActionSink)?

    static func event(of node: PluginNode, binding: PluginBinding) -> PluginEventModel {
        PluginEventModel(
            title: PluginTextView.text(of: node, binding: binding),
            timeRange: binding.text(node.props["timeRange"]),
            durationChip: binding.text(node.props["durationChip"]))
    }

    var body: some View {
        switch node.component {
        case "eventRow":
            let model = Self.event(of: node, binding: binding)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title).font(.system(size: 13, weight: .medium))
                    Text(model.timeRange).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if !model.durationChip.isEmpty {
                    PluginChipView(
                        node: PluginNode(
                            component: "tag", props: ["text": .string(model.durationChip)]),
                        traits: traits, binding: binding)
                }
            }
            .frame(height: PluginKit.leafHeight("eventRow", traits: traits))
        case "activityRow":
            HStack(spacing: 8) {
                Circle()
                    .fill(PluginStatusTone.tone(for: binding.text(node.props["status"])))
                    .frame(width: 7, height: 7)
                Text(PluginTextView.text(of: node, binding: binding)).font(.system(size: 12))
                Spacer(minLength: 4)
                Text(binding.text(node.props["relativeTime"]))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(height: PluginKit.leafHeight("activityRow", traits: traits))
        case "fileRow":
            HStack(spacing: 8) {
                Image(systemName: "doc").foregroundStyle(.secondary)
                Text(PluginTextView.text(of: node, binding: binding)).font(.system(size: 12))
                Spacer(minLength: 4)
                Text(binding.text(node.props["size"]))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let request = PluginControlView.request(of: node, binding: binding) {
                    Button {
                        PluginControlView.send(request, sink: sink)
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                }
            }
            .frame(height: PluginKit.leafHeight("fileRow", traits: traits))
        case "compareRow":
            HStack {
                Text(binding.text(node.props["left"])).font(.system(size: 12))
                Spacer()
                Text(binding.text(node.props["right"]))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(height: PluginKit.leafHeight("compareRow", traits: traits))
        default:  // checkRow
            let checked = binding.bool(node.props["checked"])
            HStack(spacing: 8) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(checked ? Color.green : Color.secondary)
                Text(PluginTextView.text(of: node, binding: binding)).font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .frame(height: PluginKit.leafHeight("checkRow", traits: traits))
            .contentShape(Rectangle())
            .onTapGesture {
                if let request = PluginControlView.request(of: node, binding: binding) {
                    PluginControlView.send(request, sink: sink)
                }
            }
        }
    }
}
