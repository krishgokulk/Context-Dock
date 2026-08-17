// ScopedCommandExecutor.swift
// Context-Dock
//
// The one place a scoped chat turns a model's request into something that happens.
//
// There were two. The dock built its executor inline inside handleL2Query and understood the
// typed invocations the prompt teaches — {"menu_call":…}, {"adapter_call":…}, {"mcp_call":…}
// — routing each to the right subsystem before anything reached a shell. The chat window's
// executor knew only about shell commands, so the same model, answering the same question
// with the same protocol, drove the app from the dock and printed JSON in the window.
//
// One executor, built from the scope. Both surfaces get menus, adapter actions, MCP and the
// CLI boundary; both get the same approval gates, because the gates live on the routes
// rather than on the caller.

import AppKit
import Foundation

@MainActor
final class ScopedCommandExecutor {

    /// What this chat is allowed to drive, and where its output belongs.
    struct Configuration {
        /// The thread asking. Console rows and terminal hand-offs are filed against it.
        var scope: GeneralChatScope
        /// The app a request without an explicit target refers to.
        var bundleId: String
        var appName: String
        /// Set for a `cli://` scope: the single executable this chat may run. Anything else
        /// is refused here as well as in the prompt, because a stale package association
        /// must not be able to run a different binary from inside one tool's thread.
        var cliTool: String?
    }

    /// MCP tools the model actually reached, for the receipt chips. Collected from
    /// execution rather than from the words in the answer.
    private(set) var mcpToolsRan: [String] = []

    private let configuration: Configuration
    private let onStatus: ((String) -> Void)?

    init(configuration: Configuration, onStatus: ((String) -> Void)? = nil) {
        self.configuration = configuration
        self.onStatus = onStatus
    }

    /// The closure the tool loops call. Non-escaping in spirit: it lives exactly as long as
    /// the turn that built it.
    func callAsFunction() -> (String, String, Bool) async -> (Bool, String, Int32) {
        { [weak self] command, purpose, modelRequiresApproval in
            guard let self else { return (false, "This chat has ended.", -1) }
            return await self.run(
                command: command, purpose: purpose,
                modelRequiresApproval: modelRequiresApproval)
        }
    }

    private func run(
        command: String, purpose: String, modelRequiresApproval: Bool
    ) async -> (Bool, String, Int32) {
        if let invocation = AITypedInvocationResolver.invocation(from: command) {
            switch invocation.kind {
            case .menuAction:
                return await runMenu(invocation)
            case .adapterAction:
                return await runAdapterAction(invocation, purpose: purpose)
            case .mcp:
                return await runMCP(invocation, command: command)
            default:
                break
            }
        }
        return await runShell(
            command, purpose: purpose, modelRequiresApproval: modelRequiresApproval)
    }

    // MARK: - Menu

    /// Click a verified app menu item. The universal control surface: it works for an app
    /// with no adapter at all, which is why the chat can do the task instead of naming the
    /// keyboard shortcut for it.
    private func runMenu(_ invocation: AITypedInvocation) async -> (Bool, String, Int32) {
        let path = (invocation.arguments["path"] ?? "")
            .components(separatedBy: "\u{1F}")
            .filter { !$0.isEmpty }
        guard !path.isEmpty else { return (false, "No menu path given.", -1) }
        let bundle = nonEmpty(invocation.arguments["bundleId"]) ?? configuration.bundleId
        guard AppAccessPolicy.allows(.verifiedMenu, at: AppAccessPolicy.level(for: bundle)) else {
            return (false, "\(configuration.appName) has not granted menu control.", -1)
        }
        onStatus?("Running \(path.joined(separator: " ▸ "))…")
        let (ok, output) = await AppAdapterManager.shared.runMenuPath(
            path, targetBundleId: bundle, appName: configuration.appName)
        return (ok, output.isEmpty ? "Ran \(path.joined(separator: " ▸ "))" : output, ok ? 0 : -1)
    }

    // MARK: - Adapter action

    /// Run an installed adapter action — the native route the prompt tells the model to
    /// prefer. `execute` shows its own approval panel for anything flagged destructive.
    private func runAdapterAction(
        _ invocation: AITypedInvocation, purpose: String
    ) async -> (Bool, String, Int32) {
        let actionId = invocation.arguments["actionId"] ?? ""
        let bundle = nonEmpty(invocation.arguments["bundleId"]) ?? configuration.bundleId
        guard AppAccessPolicy.allows(.adapter, at: AppAccessPolicy.level(for: bundle)) else {
            return (false, "\(configuration.appName) has no App Adapter, so its actions are not available.", -1)
        }
        guard let adapter = AppAdapterManager.shared.adapter(for: bundle),
            let action = adapter.actions.first(where: { $0.id == actionId })
        else {
            return (false, "No adapter action '\(actionId)' is installed for this app.", -1)
        }
        onStatus?("Running \(action.name)…")
        let (ok, output) = await AppAdapterManager.shared.execute(
            action, context: scopedAXContext(for: bundle), targetBundleId: bundle,
            query: nonEmpty(invocation.arguments["query"]) ?? purpose)
        return (ok, output.isEmpty ? "Ran \(action.name)" : output, ok ? 0 : -1)
    }

    /// The AX reading an action is given. A non-browser scope has its URL stripped: the
    /// current page belongs to whatever browser is open, not to the app being driven, and
    /// handing it over leaks one app's context into another's action.
    private func scopedAXContext(for bundleId: String) -> AXContext {
        var context = AXContextReader.shared.current
        guard !ScopedAppPromptBuilder.isBrowserBundle(bundleId) else { return context }
        context.currentURL = nil
        return context
    }

    // MARK: - MCP

    /// Call a linked MCP tool. Reads only: a provider-authored write is not something the
    /// user approved by linking a server, so mutations go through a deterministic app
    /// capability with its own approval card instead.
    private func runMCP(
        _ invocation: AITypedInvocation, command: String
    ) async -> (Bool, String, Int32) {
        var arguments = invocation.arguments
        if (arguments["bundleId"] ?? "").isEmpty {
            arguments["bundleId"] = configuration.bundleId
        }
        let scoped = AITypedInvocation(
            kind: invocation.kind,
            capabilityID: invocation.capabilityID,
            arguments: arguments,
            requiresApproval: invocation.requiresApproval)
        do {
            try CapabilityAuthorizationGate.validateInvocation(
                scoped,
                scope: .contextDock(
                    bundleID: configuration.bundleId, appName: configuration.appName))
        } catch {
            return (false, error.localizedDescription, -1)
        }
        guard MCPToolSafety.isClearlyReadOnly(name: invocation.capabilityID) else {
            return (
                false,
                "MCP tool \(invocation.capabilityID) is write/unknown risk and requires an "
                    + "approved app capability route.",
                -1
            )
        }
        let server = arguments["server"] ?? ""
        let tool = invocation.capabilityID
        onStatus?("Using MCP tool \(tool)…")
        do {
            let output = try await MCPRuntime.shared.callProviderReadOnlyTool(
                bundleId: arguments["bundleId"] ?? configuration.bundleId,
                server: server, tool: tool,
                arguments: decodeArguments(scoped))
            mcpToolsRan.append("\(tool) via \(server.isEmpty ? "MCP" : server)")
            return (true, output, 0)
        } catch {
            return (false, "MCP tool \(tool) failed: \(error.localizedDescription)", -1)
        }
    }

    private func decodeArguments(_ invocation: AITypedInvocation) -> [String: Any] {
        guard let json = invocation.arguments["argumentsJSON"],
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    // MARK: - Shell

    private func runShell(
        _ command: String, purpose: String, modelRequiresApproval: Bool
    ) async -> (Bool, String, Int32) {
        let binary = command.split(separator: " ").first.map(String.init) ?? ""

        if let tool = configuration.cliTool, !targets(command, tool: tool) {
            return (
                false,
                "This chat is scoped to \(tool). Commands for other executables are not "
                    + "allowed in this scope.",
                -1
            )
        }

        // A tool that draws its own screen cannot be run with its output captured: with no
        // tty it hangs or emits escape codes, which is how a working terminal-browser became
        // a two-and-a-half minute timeout. Those go to the thread's own terminal, where they
        // have somewhere to draw.
        if ChatThreadTerminalManager.needsTerminal(command: binary) {
            ChatThreadTerminalManager.shared.run(command, scope: configuration.scope)
            ChatConsoleLog.shared.append(
                .command, title: command,
                output: "Sent to this thread's terminal — the tool draws its own screen.",
                success: true, scope: configuration.scope)
            GeneralChatWindowChromeState.shared.showSidePanel()
            // The hand-off is what succeeded; nothing was captured, so exit 0 reports that
            // and not the tool's own result.
            return (true, "Sent to the terminal panel; it renders there.", 0)
        }

        onStatus?(statusLine(for: command))
        return await TerminalCommandExecutor.shared.run(
            command, purpose: purpose, modelRequiresApproval: modelRequiresApproval,
            consoleScope: configuration.scope)
    }

    /// CLI scopes are an executable boundary, not a general shell.
    private func targets(_ command: String, tool: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.split(whereSeparator: \.isWhitespace).first else { return false }
        let executable = String(first).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !executable.isEmpty else { return false }
        return executable.caseInsensitiveCompare(tool) == .orderedSame
            || URL(fileURLWithPath: executable).lastPathComponent
                .caseInsensitiveCompare(tool) == .orderedSame
    }

    /// Narrates the step from the command about to run, so a session reads like an agent
    /// working rather than one generic "Running linked CLI…" for every step. Derived from
    /// the real command string, so it can never claim work that is not happening.
    private func statusLine(for command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortened = trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
        guard let tool = configuration.cliTool, !tool.isEmpty else {
            return "Running \(shortened)…"
        }
        let lower = trimmed.lowercased()
        if lower.contains("--help") || lower.hasSuffix(" -h") || lower.hasSuffix(" help") {
            return "Reading \(tool) --help…"
        }
        if lower.contains("--version") || lower.hasSuffix(" -v") {
            return "Checking the \(tool) version…"
        }
        if lower.hasPrefix("which ") || lower.hasPrefix("command -v ") {
            return "Locating \(tool)…"
        }
        guard lower.hasPrefix(tool.lowercased()) else { return "Running \(shortened)…" }
        let rest = trimmed.dropFirst(tool.count).trimmingCharacters(in: .whitespaces)
        let subcommand = rest.split(separator: " ").first.map(String.init) ?? ""
        return subcommand.isEmpty || subcommand.hasPrefix("-")
            ? "Running \(tool)…"
            : "Running \(tool) \(subcommand)…"
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
