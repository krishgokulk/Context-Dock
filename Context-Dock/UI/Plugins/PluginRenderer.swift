// Context-Dock
//
// One `switch` from a node to a view. Every host renders through this; none may fork a
// component. A name the kit does not know renders as a diagnostic row naming it — a manifest
// from a newer app degrades to a visible complaint, never a blank panel or a crash.

import SwiftUI

struct PluginRenderer: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding
    weak var sink: (any PluginActionSink)?

    init(node: PluginNode, traits: HostTraits, binding: PluginBinding,
         sink: (any PluginActionSink)? = nil) {
        self.node = node
        self.traits = traits
        self.binding = binding
        self.sink = sink
    }

    enum RenderState: Equatable { case loading, empty, content }

    /// Which of the three states a node is in. `nil` binding means the data script has not
    /// answered yet — that is `loading`, and an empty list is `empty`, and the two must not be
    /// confused or a slow plugin looks broken. Only the data-driven components have an empty
    /// state; a card of static text is content the moment it decodes.
    static func state(for node: PluginNode, binding: PluginBinding?) -> RenderState {
        guard let binding else { return .loading }
        guard node.component == "list" || node.component == "grid" else { return .content }
        return binding.items(node.props["items"]).isEmpty ? .empty : .content
    }

    /// Which components this renderer actually draws. It is NOT the catalog: the catalog is
    /// what a manifest may name, this is what Phase 2 has built so far, and
    /// `theRendererImplementsEveryNameInTheCatalog` is the test that closes the gap. Each of
    /// Tasks 4–8 adds its group here in the same commit as its views.
    static let implemented: Set<String> = [
        "emptyState", "loading",
        // Task 4 — panel views
        "list", "row", "section", "actionPanel",
        // Task 5 — detail, grid, form
        "listDetail", "detail", "grid", "form",
    ]

    static func supports(_ component: String) -> Bool { implemented.contains(component) }

    /// What is wrong with this tree, for the user to see. Keyed on the *catalog*, not on
    /// `implemented`: a component nobody has written a view for yet is this phase's business,
    /// while a component the catalog has never heard of is a manifest the app cannot honour.
    /// Walks `flattened`, so an unknown name inside a list's row template is found too (#27).
    static func diagnostics(for node: PluginNode) -> [PluginDiagnostic] {
        node.flattened
            .filter { !PluginComponentCatalog.isKnown($0.component) }
            .map {
                PluginDiagnostic(
                    severity: .error, path: "views",
                    message: "unknown component \"\($0.component)\"")
            }
    }

    var body: some View {
        if PluginComponentCatalog.isKnown(node.component) {
            component
        } else {
            PluginDiagnosticsView(diagnostics: Self.diagnostics(for: node))
        }
    }

    @ViewBuilder
    private var component: some View {
        switch node.component {
        case "list":
            PluginListView(node: node, traits: traits, binding: binding, sink: sink)
        case "row":
            PluginRowView(
                model: PluginRowModel.make(from: node, binding: binding, index: 0),
                traits: traits, sink: sink)
        case "section":
            PluginSectionView(node: node, traits: traits, binding: binding, sink: sink)
        case "actionPanel":
            PluginActionPanelView(node: node, traits: traits, binding: binding, sink: sink)
        case "listDetail":
            PluginListDetailView(node: node, traits: traits, binding: binding, sink: sink)
        case "detail":
            PluginDetailView(node: node, traits: traits, binding: binding)
        case "grid":
            PluginGridView(node: node, traits: traits, binding: binding, sink: sink)
        case "form":
            PluginFormView(node: node, traits: traits, binding: binding, sink: sink)
        case "emptyState":
            PluginEmptyStateView(
                title: binding.text(node.props["title"] ?? node.props["text"]),
                message: binding.text(node.props["message"]), traits: traits)
        case "loading":
            PluginLoadingView(
                message: binding.text(node.props["message"]), traits: traits)
        default:
            // Filled in by Tasks 4–8; until then a node the kit knows but has no view for
            // holds its space rather than drawing a wrong guess.
            Color.clear.frame(height: PluginKit.leafHeight(node.component, traits: traits))
        }
    }
}
