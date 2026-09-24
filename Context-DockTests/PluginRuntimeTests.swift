// Context-DockTests/PluginRuntimeTests.swift
import Foundation
import Testing

@testable import Context_Dock

@MainActor
struct PluginRuntimeTests {
    private func manifest(_ json: String) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    }

    private let ports = #"""
    { "id": "ports", "name": "Ports",
      "data": { "type": "bash", "script": "echo 'a | 1'", "format": "lines" },
      "views": { "panel": { "list": { "filter": "local", "items": "{{lines}}",
                                      "row": { "title": "{{item.title}}" } } } } }
    """#

    @Test func aPluginWithNoDataIsReadyImmediately() throws {
        let runtime = PluginRuntime()
        let m = try manifest(#"{ "id": "x", "name": "X", "views": { "panel": { "title": "hi" } } }"#)
        guard case .ready = runtime.state(for: m, host: .panel, inputs: PluginInputs()) else {
            Issue.record("a static plugin was not ready")
            return
        }
    }

    @Test func aPluginWithADataScriptStartsLoading() throws {
        let runtime = PluginRuntime()
        guard case .loading = runtime.state(for: try manifest(ports), host: .panel, inputs: PluginInputs())
        else {
            Issue.record("a plugin with a script did not start in loading")
            return
        }
    }

    @Test func runningTheScriptFillsTheBinding() async throws {
        let runtime = PluginRuntime()
        let m = try manifest(ports)
        await runtime.refresh(m, host: .panel, inputs: PluginInputs())
        guard case .ready(let binding) = runtime.state(for: m, host: .panel, inputs: PluginInputs())
        else {
            Issue.record("never became ready")
            return
        }
        #expect(binding.items(.string("{{lines}}")).count == 1)
    }

    @Test func typingDoesNotChangeTheKeyOfALocalFilterList() throws {
        // `filter: local` narrows rows already in hand; re-running the script per keystroke
        // is what made the old custom lists feel slow.
        let m = try manifest(ports)
        let bare = PluginDataKey(manifest: m, query: "", inputs: PluginInputs())
        let typed = PluginDataKey(manifest: m, query: "ssh", inputs: PluginInputs())
        #expect(bare == typed)
    }

    @Test func aQueryListKeysOnTheQuerySoTheScriptRunsAgain() throws {
        let m = try manifest(#"""
        { "id": "q", "name": "Q", "data": { "type": "bash", "script": "echo hi", "format": "lines" },
          "views": { "panel": { "list": { "filter": "query", "items": "{{lines}}" } } } }
        """#)
        #expect(PluginDataKey(manifest: m, query: "", inputs: PluginInputs())
            != PluginDataKey(manifest: m, query: "ssh", inputs: PluginInputs()))
    }

    @Test func aFailingScriptEndsAsADiagnosticNotAnEmptyPanel() async throws {
        let runtime = PluginRuntime()
        let m = try manifest(#"""
        { "id": "bad", "name": "Bad", "data": { "type": "bash", "script": "exit 7", "format": "lines" },
          "views": { "panel": { "list": { "items": "{{lines}}" } } } }
        """#)
        await runtime.refresh(m, host: .panel, inputs: PluginInputs())
        guard case .failed(let diagnostic) = runtime.state(for: m, host: .panel, inputs: PluginInputs())
        else {
            Issue.record("a failing script did not report a diagnostic")
            return
        }
        #expect(diagnostic.severity == .error)
    }

    @Test func anActionThatIsNotDeclaredIsNeverRun() async throws {
        let runtime = PluginRuntime()
        let m = try manifest(ports)
        let result = await runtime.run(
            PluginActionRequest(name: "teleport"), manifest: m, inputs: PluginInputs())
        switch result {
        case .success: Issue.record("an undeclared action ran")
        case .failure(let failure): #expect(failure.kind == .blocked)
        }
    }
    @Test func aRefreshOfZeroStartsNoTicker() throws {
        // A timer nobody can see is the battery complaint the policy exists to prevent, and
        // the policy cannot enforce itself — whoever starts tickers has to ask it.
        let runtime = PluginRuntime()
        let never = try manifest(#"""
        { "id": "n", "name": "N",
          "data": { "type": "bash", "script": "echo hi", "refresh": { "panel": 0 } } }
        """#)
        runtime.startTicking(for: never, host: .panel, budget: .full, inputs: PluginInputs())
        #expect(runtime.tickingCount == 0)
    }

    @Test func aHiddenHostStopsTickingEvenWhenTheManifestAsksForIt() throws {
        let runtime = PluginRuntime()
        let live = try manifest(#"""
        { "id": "l", "name": "L",
          "data": { "type": "bash", "script": "echo hi", "refresh": { "widget": 5 } } }
        """#)
        runtime.startTicking(for: live, host: .widget, budget: .full, inputs: PluginInputs())
        #expect(runtime.tickingCount == 1)
        runtime.startTicking(for: live, host: .widget, budget: .none, inputs: PluginInputs())
        #expect(runtime.tickingCount == 0)
    }
    @Test func anActionAboveReadAsksBeforeItRuns() async throws {
        let runtime = PluginRuntime()
        var asked: [String] = []
        runtime.approvalProvider = { request, _, _ in asked.append(request.name); return true }
        let m = try manifest(#"""
        { "id": "x", "name": "X",
          "actions": { "wipe": { "type": "bash", "script": "echo wiped", "risk": "high" } } }
        """#)
        _ = await runtime.run(PluginActionRequest(name: "wipe"), manifest: m, inputs: PluginInputs())
        #expect(asked == ["wipe"])
    }

    @Test func aReadActionRunsWithoutAsking() async throws {
        let runtime = PluginRuntime()
        var asked = false
        runtime.approvalProvider = { _, _, _ in asked = true; return true }
        let m = try manifest(#"""
        { "id": "x", "name": "X",
          "actions": { "look": { "type": "bash", "script": "echo ok", "risk": "read" } } }
        """#)
        _ = await runtime.run(PluginActionRequest(name: "look"), manifest: m, inputs: PluginInputs())
        #expect(asked == false)
    }

    @Test func aRefusedActionDoesNotRun() async throws {
        let runtime = PluginRuntime()
        runtime.approvalProvider = { _, _, _ in false }
        let m = try manifest(#"""
        { "id": "x", "name": "X",
          "actions": { "wipe": { "type": "bash", "script": "echo wiped", "risk": "high" } } }
        """#)
        switch await runtime.run(PluginActionRequest(name: "wipe"), manifest: m, inputs: PluginInputs()) {
        case .success: Issue.record("a refused action ran anyway")
        case .failure(let failure): #expect(failure.kind == .blocked)
        }
    }

    @Test func withNoProviderInstalledNothingAboveReadRuns() async throws {
        // The default refuses. A caller that forgets to install a provider gets a plugin that
        // does nothing, which is the failure worth having.
        let runtime = PluginRuntime()
        let m = try manifest(#"""
        { "id": "x", "name": "X",
          "actions": { "wipe": { "type": "bash", "script": "echo wiped", "risk": "high" } } }
        """#)
        switch await runtime.run(PluginActionRequest(name: "wipe"), manifest: m, inputs: PluginInputs()) {
        case .success: Issue.record("an unapproved action ran with no provider installed")
        case .failure(let failure): #expect(failure.kind == .blocked)
        }
    }
}
