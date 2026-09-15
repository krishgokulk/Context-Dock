// Context-Dock
//
// One manifest, every host, side by side, from its own `sample` data. This is how Phase 2 is
// looked at by a person before any runtime exists, and it is the same view the Creator's
// preview tabs use in Phase 7 — so a plugin is never previewed by a second renderer.

import SwiftUI

@MainActor
struct PluginPreviewHarness: View {
    let manifest: PluginManifest
    @State private var sink = RecordingActionSink()

    static func binding(for manifest: PluginManifest) -> PluginBinding {
        PluginBinding(data: manifest.sample)
    }

    /// Two sources, because neither sees everything: the schema, which validates the manifest
    /// as a whole, and the renderer, which is the only one that knows which component names it
    /// can actually draw.
    static func diagnostics(for manifest: PluginManifest) -> [PluginDiagnostic] {
        PluginSchema.validate(manifest)
            + manifest.allNodes.filter { !PluginComponentCatalog.isKnown($0.component) }.map {
                PluginDiagnostic(
                    severity: .error, path: "views",
                    message: "unknown component \"\($0.component)\"")
            }
    }

    /// The traits this manifest can actually be shown in: both panel hosts when it declares a
    /// panel, the strip when it declares an icon or a widget, the window when it declares one.
    static func traitsAvailable(for manifest: PluginManifest) -> [HostTraits] {
        var out: [HostTraits] = []
        for presentation in manifest.declaredPresentations {
            switch presentation {
            case .panel: out.append(contentsOf: [.dockSheet, .cornerPanel])
            case .icon: out.append(.strip(.icon))
            case .widget:
                out.append(.strip(.widget, family: manifest.views.widget?.family ?? .medium))
            case .window:
                out.append(.window(manifest.views.window?.width ?? .regular, screenHeight: 900))
            }
        }
        return out
    }

    /// `widget.root` and `window.root` are optional in the model, so each read is a double
    /// optional — `flatMap`, not `?`. A nil root is a schema error, which means a validated
    /// manifest never gets here with one; the Creator previews *unvalidated* manifests, so this
    /// path must still answer nil rather than crash, and the caller draws a diagnostic.
    static func root(of manifest: PluginManifest, for traits: HostTraits) -> PluginNode? {
        switch traits.presentation {
        case .panel: return manifest.views.panel?.root
        case .widget: return manifest.views.widget.flatMap(\.root)
        case .window: return manifest.views.window.flatMap(\.root)
        case .icon:
            if let root = manifest.views.icon.flatMap(\.root) { return root }
            guard let capsule = manifest.views.icon?.capsule else { return nil }
            return PluginNode(component: "capsule", children: capsule)
        }
    }

    var body: some View {
        let diagnostics = Self.diagnostics(for: manifest)
        VStack(alignment: .leading, spacing: 12) {
            if !diagnostics.isEmpty {
                PluginDiagnosticsView(diagnostics: diagnostics)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(Array(Self.traitsAvailable(for: manifest).enumerated()), id: \.offset) {
                        _, traits in
                        host(traits)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func host(_ traits: HostTraits) -> some View {
        let binding = Self.binding(for: manifest)
        VStack(alignment: .leading, spacing: 4) {
            Text("\(traits.presentation.rawValue) · \(traits.widthClass.rawValue)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            if let root = Self.root(of: manifest, for: traits) {
                let shown = PluginCompactRules.apply(to: root, traits: traits)
                PluginRenderer(node: shown, traits: traits, binding: binding, sink: sink)
                    .frame(
                        width: traits.width,
                        height: PluginSizing.treeHeight(shown, traits: traits, binding: binding),
                        alignment: .top)
                    .clipped()
            } else {
                PluginDiagnosticsView(diagnostics: [
                    PluginDiagnostic(
                        severity: .error, path: "views.\(traits.presentation.rawValue)",
                        message: "declared with no root to draw")
                ])
                .frame(width: traits.width)
            }
        }
    }
}
