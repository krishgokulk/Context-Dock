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

    init() {}

    // MARK: Data

    func state(for manifest: PluginManifest, host: PluginPresentation, inputs: PluginInputs)
        -> PluginDataState
    {
        // A plugin with no data source is never loading: its sample IS its data.
        guard manifest.data != nil else {
            return .ready(PluginBinding(data: manifest.sample))
        }
        return states[PluginDataKey(manifest: manifest, query: "", inputs: inputs)] ?? .loading
    }

    func refresh(_ manifest: PluginManifest, host: PluginPresentation, inputs: PluginInputs) async {
        guard let source = manifest.data else { return }
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
                states[key] = .ready(PluginBinding(data: value.objectValue ?? [:]))
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

    func run(_ request: PluginActionRequest, manifest: PluginManifest, inputs: PluginInputs) async
        -> Result<String, PluginRunFailure>
    {
        // An action nobody declared is not run, whatever asked for it. The renderer can emit a
        // request for any string; this is where that stops being interesting.
        guard let action = manifest.actions[request.name] else {
            return .failure(PluginRunFailure(
                message: "\(manifest.name) does not declare an action called \"\(request.name)\"",
                kind: .blocked))
        }
        if PluginPermissions.needsApproval(action) {
            guard await approvalProvider(request, action, manifest) else {
                return .failure(PluginRunFailure(
                    message: "\(action.title ?? request.name) was not approved", kind: .blocked))
            }
        }

        var scoped = inputs
        scoped.value = request.value
        let env = PluginEnvironment.build(inputs: scoped, host: .panel, widthClass: .regular)

        // The built-ins act through AppKit rather than a process.
        switch action.type {
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
        return result.map(\.stdout)
    }

    private func appURL(named name: String) -> URL? {
        let path = "/Applications/\(name).app"
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }
}
