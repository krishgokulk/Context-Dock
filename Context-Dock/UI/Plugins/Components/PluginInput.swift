// Context-Dock
//
// Where a plugin takes something in: a field, a search field, a drop target, an AI prompt,
// and the escape hatch for Swift-implemented built-in panels.

import SwiftUI

struct PluginInputView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding
    weak var sink: (any PluginActionSink)?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        switch node.component {
        case "searchField":
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(binding.text(node.props["placeholder"]), text: $text)
                    .textFieldStyle(.plain).font(.system(size: 12))
                if !text.isEmpty {
                    Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .frame(height: PluginKit.leafHeight("searchField", traits: traits))
        case "dropzone":
            let label = PluginTextView.text(of: node, binding: binding)
            RoundedRectangle(cornerRadius: PluginKit.cornerRadius, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(.secondary)
                .overlay(
                    Text(label.isEmpty ? "Drop files here" : label)
                        .font(.system(size: 11)).foregroundStyle(.secondary))
                .frame(height: PluginKit.leafHeight("dropzone", traits: traits))
        case "ai":
            // One prompt, one answer, rendered as markdown. Phase 3 runs it; here it shows the
            // prompt it would ask, so the Creator preview is honest about what will happen.
            VStack(alignment: .leading, spacing: 4) {
                Label("Ask", systemImage: "sparkles")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text(binding.text(node.props["prompt"] ?? node.props["text"]))
                    .font(.system(size: 12)).lineLimit(3)
            }
            .frame(height: PluginKit.leafHeight("ai", traits: traits), alignment: .topLeading)
        case "native":
            // The escape hatch for Swift-implemented built-ins (wifi, bluetooth). Phase 8 wires
            // the names; until then it says so rather than drawing a blank.
            PluginDiagnosticsView(diagnostics: [
                PluginDiagnostic(
                    severity: .warning, path: "views",
                    message: "native panel \"\(binding.text(node.props["text"]))\" is not wired yet")
            ])
        default:  // textField
            // `value` is where it starts (a bound state key, say); `action` is what Return
            // sends the typed text to. A field with nowhere to send it is a note to self.
            TextField(binding.text(node.props["placeholder"]), text: $text)
                .textFieldStyle(.roundedBorder).font(.system(size: 12))
                .frame(height: PluginKit.leafHeight("textField", traits: traits))
                .onAppear {
                    if text.isEmpty { text = binding.text(node.props["value"]) }
                }
                .focused($focused)
                .onChange(of: focused) { _, isFocused in
                    PluginKeyboardClaim.shared.fieldFocusChanged(isFocused)
                }
                .onDisappear { PluginKeyboardClaim.shared.fieldFocusChanged(false) }
                .onSubmit {
                    let name = binding.text(node.props["action"])
                    guard !name.isEmpty else { return }
                    sink?.run(PluginActionRequest(name: name, value: .string(text)))
                }
        }
    }
}
