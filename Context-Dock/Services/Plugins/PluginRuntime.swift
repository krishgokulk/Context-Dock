// Context-Dock
//
// What a host asks for data and actions. It owns the cache, the tickers, and the one call into
// the runner; everything it decides with is a pure function from the files beside it.
//
// The cache key is what makes `filter: local` free: typing changes the query the VIEW filters
// by, not the key, so a local-filter list never re-runs its script on a keystroke. A
// `filter: query` list takes the query into its key, because there the script is the filter.

import AppKit
import Combine
import Foundation

struct PluginDataKey: Hashable {
    let pluginID: String
    let query: String
    let inputsHash: Int

    init(manifest: PluginManifest, query: String, inputs: PluginInputs) {
        self.pluginID = manifest.id
        self.query = PluginDataKey.scriptFilters(manifest) ? query : ""
        // The host is deliberately not in the key: the same data drives every host, and
        // keying on it would run the same script once per surface showing the plugin.
        var hasher = Hasher()
        let env = PluginEnvironment.build(inputs: inputs, host: .panel, widthClass: .regular)
        for key in env.keys.sorted() {
            hasher.combine(key)
            hasher.combine(env[key])
        }
        self.inputsHash = hasher.finalize()
    }

    /// True when some list in this manifest declares `filter: query` — then the script is the
    /// filter and each query is a different result.
    private static func scriptFilters(_ manifest: PluginManifest) -> Bool {
        manifest.allNodes.contains { node in
            (node.component == "list" || node.component == "grid")
                && node.props["filter"]?.stringValue == "query"
        }
    }
}

enum PluginDataState {
    case loading
    case ready(PluginBinding)
    case failed(PluginDiagnostic)
}

@MainActor
final class PluginRuntime: ObservableObject {
    static let shared = PluginRuntime()

    /// Asked before anything above `risk: read` runs. The default REFUSES: a caller that
    /// forgets to install a provider gets a plugin that does nothing, which is the failure
    /// worth having. Task 7 routes the real one to AICapabilityApprovalCenter.
    var approvalProvider: (PluginActionRequest, PluginAction, PluginManifest) async -> Bool = {
        _, _, _ in false
    }

    @Published private(set) var states: [PluginDataKey: PluginDataState] = [:]

    private let runner = PluginScriptRunner()
    private var tickers: [String: Task<Void, Never>] = [:]
    /// What each plugin remembers. Folded into the inputs on every call, so a data script
    /// sees `CD_STATE_*`, a view binds `{{from}}`, and a changed value is a new data key.
    let stateStore: PluginStateStore

    init(stateStore: PluginStateStore = .shared) {
        self.stateStore = stateStore
    }

    /// The caller's inputs with the plugin's remembered values underneath.
    private func withState(_ inputs: PluginInputs, for manifest: PluginManifest) -> PluginInputs {
        var scoped = inputs
        scoped.state = stateStore.state(for: manifest)
        return scoped
    }

    // MARK: Data

    func state(for manifest: PluginManifest, host: PluginPresentation, inputs: PluginInputs)
        -> PluginDataState
    {
        let inputs = withState(inputs, for: manifest)
        // A plugin with no data source is never loading: its sample IS its data.
        guard manifest.data != nil else {
            return .ready(PluginBinding(data: Self.bindable(inputs.state, under: manifest.sample)))
        }
        return states[PluginDataKey(manifest: manifest, query: "", inputs: inputs)] ?? .loading
    }

    /// What a view binds against: the script's data, with the remembered state underneath.
    /// State is the floor — `{{from}}` reads before the script has answered, and a script
    /// that echoes a key it was given wins on that key.
    nonisolated static func bindable(
        _ state: [String: PluginValue], under data: [String: PluginValue]
    ) -> [String: PluginValue] {
        state.merging(data) { _, fromData in fromData }
    }

    func refresh(_ manifest: PluginManifest, host: PluginPresentation, inputs: PluginInputs) async {
        guard let source = manifest.data else { return }
        let inputs = withState(inputs, for: manifest)
        let key = PluginDataKey(manifest: manifest, query: "", inputs: inputs)
        let env = PluginEnvironment.build(
            inputs: inputs, host: host,
            widthClass: host == .panel ? .regular : .compact)

        let result: Result<PluginRunResult, PluginRunFailure>
        if source.type == .http {
            result = await runner.run(
                http: source.script, manifest: manifest, timeout: TimeInterval(source.timeout))
        } else {
            result = await runner.run(
                type: source.type, script: source.script, env: env,
                timeout: TimeInterval(source.timeout), workingDirectory: nil)
        }

        switch result {
        case .failure(let failure):
            states[key] = .failed(PluginDiagnostic(
                severity: .error, path: "data", message: failure.message))
        case .success(let run):
            switch PluginOutput.decode(run.stdout, format: source.format) {
            case .failure(let diagnostic):
                states[key] = .failed(diagnostic)
            case .success(let value):
                states[key] = .ready(PluginBinding(
                    data: Self.bindable(inputs.state, under: value.objectValue ?? [:])))
            }
        }
    }

    // MARK: Refresh tickers

    /// A host that disappears must stop its own ticker. A timer nobody can see is exactly the
    /// battery complaint PluginRefreshPolicy.admits exists to prevent, and the policy cannot
    /// enforce itself.
    func startTicking(for manifest: PluginManifest, host: PluginPresentation,
                      budget: PluginLiveBudget, inputs: PluginInputs)
    {
        stopTicking(pluginID: manifest.id)
        guard let interval = PluginRefreshPolicy.interval(for: manifest, host: host, budget: budget),
            PluginRefreshPolicy.admits(runningLiveCount: tickers.count)
        else { return }
        tickers[manifest.id] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.refresh(manifest, host: host, inputs: inputs)
            }
        }
    }

    func stopTicking(pluginID: String) {
        tickers[pluginID]?.cancel()
        tickers[pluginID] = nil
    }

    var tickingCount: Int { tickers.count }

    // MARK: Actions

    /// `skipApproval` is for the one caller that has already been approved: the capability
    /// executor built by PluginCapability, which is reached THROUGH the approval centre. Asking
    /// again there would show the same card twice for one decision.
    func run(_ request: PluginActionRequest, manifest: PluginManifest, inputs: PluginInputs,
             skipApproval: Bool = false) async
        -> Result<String, PluginRunFailure>
    {
        // An action nobody declared is not run, whatever asked for it. The renderer can emit a
        // request for any string; this is where that stops being interesting.
        guard let action = manifest.actions[request.name] else {
            return .failure(PluginRunFailure(
                message: "\(manifest.name) does not declare an action called \"\(request.name)\"",
                kind: .blocked))
        }
        if !skipApproval, PluginPermissions.needsApproval(action) {
            guard await approvalProvider(request, action, manifest) else {
                return .failure(PluginRunFailure(
                    message: "\(action.title ?? request.name) was not approved", kind: .blocked))
            }
        }

        var scoped = withState(inputs, for: manifest)
        scoped.value = request.value
        let env = PluginEnvironment.build(inputs: scoped, host: .panel, widthClass: .regular)

        // A push that names a key remembers what was tapped on the way — the host does the
        // navigating; this is the memory. Without a key it is navigation only, and nothing
        // here has anything to do.
        if let target = action.pushTarget {
            guard let key = action.key, !key.isEmpty else { return .success(target) }
            let value = request.value ?? action.value.map(PluginValue.string) ?? .null
            stateStore.set(key, to: value, for: manifest)
            await refresh(manifest, host: .panel, inputs: inputs)
            return .success(target)
        }

        // The built-ins act through AppKit rather than a process.
        switch action.type {
        case "set":
            // The tapped value into the named key, then the data again with it: a picker
            // that changes the currency is not done until the row shows the new figure.
            // The key may itself be a binding — `"key": "{{picking}}"` writes to whichever
            // key the plugin remembered last, which is how one grid serves both currencies.
            guard let declaredKey = action.key, !declaredKey.isEmpty else {
                return .failure(PluginRunFailure(
                    message: "\(request.name) is a set action with no key", kind: .blocked))
            }
            let key = PluginBinding(data: scoped.state).text(.string(declaredKey))
            guard !key.isEmpty else {
                return .failure(PluginRunFailure(
                    message: "\(request.name)'s key \(declaredKey) resolved to nothing", kind: .blocked))
            }
            let value = request.value ?? action.value.map(PluginValue.string) ?? .null
            stateStore.set(key, to: value, for: manifest)
            await refresh(manifest, host: .panel, inputs: inputs)
            return .success(key)
        case "copy":
            let text = action.value ?? request.value?.stringValue ?? ""
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return .success(text)
        case "open":
            if let app = action.app {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app)
                    ?? appURL(named: app)
                else {
                    return .failure(PluginRunFailure(message: "\(app) is not installed", kind: .launch))
                }
                _ = try? await NSWorkspace.shared.openApplication(
                    at: url, configuration: .init())
                return .success(app)
            }
            let target = action.value ?? request.value?.stringValue ?? ""
            guard let url = URL(string: target) else {
                return .failure(PluginRunFailure(message: "not a URL: \(target)", kind: .launch))
            }
            NSWorkspace.shared.open(url)
            return .success(target)
        case "reveal":
            let path = action.value ?? request.value?.stringValue ?? ""
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return .success(path)
        default:
            break
        }

        guard let type = PluginScriptType(rawValue: action.type), let script = action.script else {
            return .failure(PluginRunFailure(
                message: "\"\(action.type)\" is not something this app can run", kind: .blocked))
        }
        let result = await runner.run(
            type: type, script: script, env: env, timeout: 30, workingDirectory: nil)
        // A script that answers with `{ "state": { … } }` is changing what the plugin
        // remembers — a swap, a chosen item — and the data is asked again with it.
        if case .success(let run) = result,
            let patch = Self.statePatch(in: run.stdout), !patch.isEmpty
        {
            stateStore.merge(patch, for: manifest)
            await refresh(manifest, host: .panel, inputs: inputs)
        }
        return result.map(\.stdout)
    }

    /// Pure: the `state` object in a script's output, if the output is JSON and carries one.
    nonisolated static func statePatch(in stdout: String) -> [String: PluginValue]? {
        guard let data = stdout.data(using: .utf8),
            let value = try? JSONDecoder().decode(PluginValue.self, from: data),
            let object = value.objectValue,
            let patch = object["state"]?.objectValue
        else { return nil }
        return patch
    }

    private func appURL(named name: String) -> URL? {
        let path = "/Applications/\(name).app"
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }
}
