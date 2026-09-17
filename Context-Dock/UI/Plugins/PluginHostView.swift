// Context-Dock
//
// Where a person meets a plugin. One host for every surface — the dock's result sheet, the
// corner panel, a detached window — so a plugin cannot behave differently depending on where
// it is shown. The surface passes traits; it does not fork the view.
//
// The model is separate from the drawing because navigation and trait choice are decisions
// worth testing without rendering anything.

import Combine
import SwiftUI

@MainActor
final class PluginHostModel: ObservableObject {
    let manifest: PluginManifest
    let presentation: PluginPresentation
    /// A compact host (the corner) asks for compact traits; the dock sheet does not.
    let compact: Bool

    /// Views pushed on top of the first one — `push:<view>` from an action, back by ⌫ or the
    /// header's chevron.
    @Published private(set) var stack: [PluginPresentation] = []
    /// A host that would rather show a pushed view somewhere else — the strip opens a
    /// widget's `push:panel` as a card above the tile, not inside a 48-point tile — claims
    /// it here by returning true. Nil, or false, and the view is pushed in place.
    var onPush: ((PluginPresentation, PluginActionRequest) -> Bool)?
    /// Told when an action the runtime ran has finished, and whether it succeeded, so a
    /// card that exists to take one choice can close once the choice is made.
    var onActionCompleted: ((PluginActionRequest, Bool) -> Void)?

    init(manifest: PluginManifest, presentation: PluginPresentation, compact: Bool = false) {
        self.manifest = manifest
        self.presentation = presentation
        self.compact = compact
    }

    var depth: Int { stack.count }

    var current: PluginPresentation { stack.last ?? presentation }

    /// The node to draw. A presentation the manifest never declared falls back to its panel:
    /// ▢ opens a window for a plugin that only has a panel, and drawing nothing there reads as
    /// a broken plugin rather than as one with no window of its own.
    var root: PluginNode? {
        Self.root(of: manifest, for: current) ?? Self.root(of: manifest, for: .panel)
    }

    var traits: HostTraits {
        switch current {
        case .window:
            return .window(manifest.views.window?.width ?? .regular,
                           screenHeight: NSScreen.main?.visibleFrame.height ?? 900)
        case .icon, .widget:
            return .strip(current, family: manifest.views.widget?.family ?? .medium)
        case .panel:
            return Self.traits(for: .panel, compact: compact)
        }
    }

    static func traits(for presentation: PluginPresentation, compact: Bool) -> HostTraits {
        presentation == .panel && compact ? .cornerPanel : .dockSheet
    }

    static func root(of manifest: PluginManifest, for presentation: PluginPresentation)
        -> PluginNode?
    {
        switch presentation {
        case .panel: return manifest.views.panel?.root
        case .widget: return manifest.views.widget.flatMap(\.root)
        case .window: return manifest.views.window.flatMap(\.root)
        case .icon:
            if let root = manifest.views.icon.flatMap(\.root) { return root }
            guard let capsule = manifest.views.icon?.capsule else { return nil }
            return PluginNode(component: "capsule", children: capsule)
        }
    }

    /// The view a request navigates to, if it is navigation: an action declared as
    /// `push:<view>`, or the literal name. Looked up by name — a button says `"action":
    /// "pick"` and the manifest says what pick is; the old check read the name alone, so
    /// every declared push action went to the runtime, which cannot run one.
    func pushTarget(of request: PluginActionRequest) -> PluginPresentation? {
        let raw = manifest.actions[request.name]?.pushTarget
            ?? (request.name.hasPrefix("push:") ? String(request.name.dropFirst("push:".count)) : nil)
        guard let raw, let target = PluginPresentation(rawValue: raw),
            Self.root(of: manifest, for: target) != nil
        else { return nil }
        return target
    }

    /// True when this request was navigation and the host consumed it. Everything else belongs
    /// to the runtime — a host that swallowed an ordinary action would make it silently do
    /// nothing, which is indistinguishable from a broken plugin.
    @discardableResult
    func handle(_ request: PluginActionRequest) -> Bool {
        guard let target = pushTarget(of: request) else { return false }
        if let onPush, onPush(target, request) { return true }
        stack.append(target)
        return true
    }

    func back() {
        guard !stack.isEmpty else { return }
        stack.removeLast()
    }
}

/// The sink a host installs: navigation is handled here, everything else runs.
@MainActor
final class PluginHostSink: PluginActionSink {
    private let model: PluginHostModel
    private let runtime: PluginRuntime
    private let inputs: PluginInputs
    var onResult: ((Result<String, PluginRunFailure>) -> Void)?

    init(model: PluginHostModel, runtime: PluginRuntime, inputs: PluginInputs) {
        self.model = model
        self.runtime = runtime
        self.inputs = inputs
    }

    func run(_ request: PluginActionRequest) {
        // A push that names a state key remembers what was tapped before it navigates —
        // `pickFrom` writes `picking = "from"` so the one panel knows which currency it is
        // choosing. Written through the runtime so the data is asked again with it.
        if model.pushTarget(of: request) != nil {
            if let action = model.manifest.actions[request.name], action.key != nil {
                Task { [weak self] in
                    guard let self else { return }
                    _ = await runtime.run(
                        PluginActionRequest(
                            name: request.name, value: request.value ?? action.value.map(PluginValue.string)),
                        manifest: model.manifest, inputs: inputs)
                    model.handle(request)
                }
                return
            }
            model.handle(request)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let result = await runtime.run(
                request, manifest: model.manifest, inputs: inputs)
            onResult?(result)
            if case .success = result {
                model.onActionCompleted?(request, true)
            } else {
                model.onActionCompleted?(request, false)
            }
        }
    }
}

struct PluginHostView: View {
    @ObservedObject var model: PluginHostModel
    @ObservedObject private var runtime: PluginRuntime
    var inputs: PluginInputs
    var query: String = ""

    @State private var sink: PluginHostSink?
    @State private var lastFailure: String?

    init(model: PluginHostModel, runtime: PluginRuntime = .shared,
         inputs: PluginInputs = PluginInputs(), query: String = "")
    {
        self.model = model
        self.runtime = runtime
        self.inputs = inputs
        self.query = query
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.depth > 0 {
                Button { model.back() } label: {
                    Label(model.manifest.name, systemImage: "chevron.left")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            content

            if let lastFailure {
                Label(lastFailure, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .onAppear {
            let sink = PluginHostSink(model: model, runtime: runtime, inputs: inputs)
            sink.onResult = { result in
                if case .failure(let failure) = result { lastFailure = failure.message }
                else { lastFailure = nil }
            }
            self.sink = sink
            refresh()
        }
        .onChange(of: model.current) { _, _ in refresh() }
    }

    @ViewBuilder
    private var content: some View {
        if let root = model.root {
            switch runtime.state(for: model.manifest, host: model.current, inputs: inputs) {
            case .loading:
                PluginLoadingView(message: "", traits: model.traits)
            case .failed(let diagnostic):
                PluginDiagnosticsView(diagnostics: [diagnostic])
            case .ready(let binding):
                PluginRenderer.root(
                    root, traits: model.traits, binding: binding, sink: sink)
            }
        } else {
            PluginDiagnosticsView(diagnostics: [
                PluginDiagnostic(
                    severity: .error, path: "views",
                    message: "\(model.manifest.name) has no view to show here")
            ])
        }
    }

    private func refresh() {
        guard model.manifest.data != nil else { return }
        Task { await runtime.refresh(model.manifest, host: model.current, inputs: inputs) }
    }
}
