// Context-Dock
//
// Every way a plugin says something in words. A manifest may write the shorthand
// (`{ "title": "Up next" }`, which decodes into props["text"]) or the long form
// (`{ "title": { "text": "{{heading}}" } }`); both read the same here, so a manifest author
// never has to know which spelling the renderer prefers.

import SwiftUI

struct PluginStatModel: Equatable {
    let value: String
    let label: String
    let delta: String
}

struct PluginTextView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding
    /// Only the editable leaves send anything.
    weak var sink: (any PluginActionSink)?
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    init(node: PluginNode, traits: HostTraits, binding: PluginBinding,
         sink: (any PluginActionSink)? = nil)
    {
        self.node = node
        self.traits = traits
        self.binding = binding
        self.sink = sink
    }

    static func text(of node: PluginNode, binding: PluginBinding) -> String {
        binding.text(node.props["text"] ?? node.props["title"] ?? node.props["value"])
    }

    /// `"edit": "setAmount"` on a text leaf makes it tap-to-edit: a click turns the text into
    /// a field holding `value` (or the text), Return sends the typed text to that action, Esc
    /// puts the text back. The figure in a tile can be changed where it is read, without a
    /// second field somewhere else asking for the same number.
    private var editAction: String { binding.text(node.props["edit"]) }
    private var isEditable: Bool { !editAction.isEmpty }

    static func stat(of node: PluginNode, binding: PluginBinding) -> PluginStatModel {
        PluginStatModel(
            value: binding.text(node.props["value"] ?? node.props["text"]),
            label: binding.text(node.props["label"]),
            delta: binding.text(node.props["delta"]))
    }

    var body: some View {
        if isEditable, editing {
            editor
        } else {
            plain
                .contentShape(Rectangle())
                .onTapGesture {
                    guard isEditable else { return }
                    draft = binding.text(node.props["value"] ?? node.props["text"])
                    editing = true
                    // Claimed before the field exists: the panel has to be made key first
                    // or the focus request lands on a window that cannot take it.
                    PluginKeyboardClaim.shared.fieldFocusChanged(true)
                    DispatchQueue.main.async { fieldFocused = true }
                }
                .help(isEditable ? "Click to change" : "")
        }
    }

    private var editor: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: editorFontSize, weight: .semibold))
            .monospacedDigit()
            .focused($fieldFocused)
            .frame(height: PluginKit.leafHeight(node.component, traits: traits))
            .onSubmit {
                editing = false
                sink?.run(PluginActionRequest(name: editAction, value: .string(draft)))
            }
            .onExitCommand { editing = false }
            .onChange(of: fieldFocused) { _, focused in
                PluginKeyboardClaim.shared.fieldFocusChanged(focused)
                // Clicking away is Esc, not Return: what was typed is not sent half-done.
                if !focused { editing = false }
            }
            .onDisappear { PluginKeyboardClaim.shared.fieldFocusChanged(false) }
    }

    private var editorFontSize: CGFloat {
        switch node.component {
        case "title": return traits.isBar ? 17 : 15
        case "caption": return 10
        default: return 12
        }
    }

    @ViewBuilder
    private var plain: some View {
        switch node.component {
        case "title":
            // The bar tile's big figure — "433,36" — reads at 17 with tabular digits so a
            // rate that ticks does not make the chips beside it jitter.
            Text(Self.text(of: node, binding: binding))
                .font(.system(size: traits.isBar ? 17 : 15, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(traits.isBar ? 0.7 : 1)
        case "subtitle":
            Text(Self.text(of: node, binding: binding))
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        case "body":
            Text(Self.text(of: node, binding: binding)).font(.system(size: 12))
        case "caption":
            Text(Self.text(of: node, binding: binding))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .underline(isEditable, pattern: .dot, color: .secondary.opacity(0.5))
        case "markdown":
            Text(LocalizedStringKey(Self.text(of: node, binding: binding))).font(.system(size: 12))
        case "stat":
            let model = Self.stat(of: node, binding: binding)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(model.value).font(.system(size: 22, weight: .semibold))
                    if !model.delta.isEmpty {
                        Text(model.delta).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Text(model.label).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        default:  // header
            HStack(spacing: 8) {
                let icon = binding.text(node.props["icon"])
                if !icon.isEmpty { Image(systemName: icon) }
                Text(Self.text(of: node, binding: binding))
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                if let trailing = node.props["trailing"] {
                    Text(binding.text(trailing)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(height: PluginKit.leafHeight("header", traits: traits))
        }
    }
}
