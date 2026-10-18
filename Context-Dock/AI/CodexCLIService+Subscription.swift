import Foundation
import os

extension CodexCLIService {
    enum SubscriptionFailure: LocalizedError {
        case signInRequired
        case apiKeyLogin
        case catalogUnavailable

        var errorDescription: String? {
            switch self {
            case .signInRequired:
                return "Sign in with ChatGPT: run `codex login` in Terminal, then check again."
            case .apiKeyLogin:
                return "Codex is signed in with an API key. ChatGPT Subscription requires ChatGPT sign-in. "
                    + "Use `codex login` in Terminal to switch, or choose OpenAI API in DoraX."
            case .catalogUnavailable:
                return "Codex could not load subscription models. Update Codex, run `codex login`, then check again."
            }
        }
    }

    struct SubscriptionModel: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let isDefault: Bool
    }

    /// No API credentials, host proxy, or host session routing can select a billed API path.
    nonisolated static func subscriptionEnvironment(
        from base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        CLIChildEnvironment.make(from: base).filter { key, _ in
            if key.hasPrefix("OPENAI_") || key.hasPrefix("AZURE_OPENAI_") { return false }
            if key.hasPrefix("CODEX_") && key != "CODEX_HOME" { return false }
            return true
        }
    }

    /// Private app context can never reach Codex's own network, shell, connectors or plugins.
    /// DoraX's scoped loop executes typed actions through its existing approval/outbound gate.
    nonisolated static var subscriptionConfiguration: [String] {
        var args = ["-c", "model_provider=\"openai\"", "-c", "web_search=\"disabled\"",
                    "-c", "project_doc_max_bytes=0", "-c", "mcp_servers={}",
                    "-c", "tools.update_plan.enabled=false"]
        for feature in [
            "shell_tool", "unified_exec", "view_image", "browser_use", "browser_use_external",
            "computer_use", "apps", "plugins", "hooks", "multi_agent", "multi_agent_v2",
            "skill_search", "memories", "image_generation", "code_mode_host", "code_mode",
            "in_app_browser", "in_app_local_automation", "goals", "remote_plugin",
            "workspace_dependencies", "tool_suggest", "sleep_tool"
        ] { args += ["--disable", feature] }
        return args
    }

    nonisolated static func subscriptionArguments(model: String?) -> [String] {
        var args = ["exec", "--ignore-user-config", "--ignore-rules", "--ephemeral",
                    "--skip-git-repo-check", "--sandbox", "read-only", "--json",
                    "-c", "forced_login_method=\"chatgpt\"", "-c", "approval_policy=\"never\""]
        args += subscriptionConfiguration
        if let model, !model.isEmpty { args += ["--model", model] }
        args.append("-") // Prompt/history never appear in process arguments or logs.
        return args
    }

    nonisolated static func validateSubscriptionLogin(output: String, status: Int32) throws {
        guard status == 0 else { throw SubscriptionFailure.signInRequired }
        let status = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard status == "logged in using chatgpt" else {
            if status.contains("api key") { throw SubscriptionFailure.apiKeyLogin }
            throw SubscriptionFailure.signInRequired
        }
    }

    /// The catalog is read through the CLI's public RPC; DoraX never reads auth.json/tokens.
    static func subscriptionModels() async throws -> [SubscriptionModel] {
        guard let binary = binaryPath() else { throw Failure.notInstalled }
        let directory = try neutralDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var models: [SubscriptionModel] = []
        var cursor: String?
        var seen: Set<String> = []
        repeat {
            var parameters: [String: Any] = ["limit": 100, "includeHidden": false]
            if let cursor { parameters["cursor"] = cursor }
            let messages: [[String: Any]] = [
                ["id": 1, "method": "initialize", "params": [
                    "clientInfo": ["name": "dorax", "version": "1.0"]]],
                ["method": "initialized", "params": [:]],
                ["id": 2, "method": "account/read", "params": ["refreshToken": false]],
                ["id": 3, "method": "model/list", "params": parameters]
            ]
            let input = try messages.map {
                String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
            }.joined(separator: "\n") + "\n"
            let replies = OSAllocatedUnfairLock(initialState: Set<Int>())
            let result = try await CLIProcess.run(
                binary: binary, arguments: ["app-server", "--stdio"] + subscriptionConfiguration,
                directory: directory, environment: subscriptionEnvironment(), input: input,
                closeInput: false, timeout: 20,
                onLine: { line in
                    guard let object = rpcObject(line), let id = object["id"] as? Int else {
                        return false
                    }
                    if id == 1 && object["error"] != nil { return true }
                    return replies.withLock { ids in
                        ids.insert(id)
                        return ids.contains(2) && ids.contains(3)
                    }
                })
            let page = try subscriptionCatalog(from: result.stdout)
            models += page.models.filter { model in !models.contains { $0.id == model.id } }
            cursor = page.nextCursor
            if let cursor, !seen.insert(cursor).inserted { throw SubscriptionFailure.catalogUnavailable }
        } while cursor != nil
        guard !models.isEmpty else { throw SubscriptionFailure.catalogUnavailable }
        return models
    }

    nonisolated static func subscriptionCatalog(from transcript: String) throws
        -> (models: [SubscriptionModel], nextCursor: String?) {
        let replies = transcript.split(separator: "\n").compactMap { rpcObject(String($0)) }
        guard let accountReply = replies.first(where: { ($0["id"] as? Int) == 2 }),
              accountReply["error"] == nil else { throw SubscriptionFailure.catalogUnavailable }
        guard let account = (accountReply["result"] as? [String: Any])?["account"] as? [String: Any]
        else { throw SubscriptionFailure.signInRequired }
        guard account["type"] as? String == "chatgpt" else { throw SubscriptionFailure.apiKeyLogin }
        guard let reply = replies.first(where: { ($0["id"] as? Int) == 3 }),
              reply["error"] == nil, let result = reply["result"] as? [String: Any],
              let data = result["data"] as? [[String: Any]]
        else { throw SubscriptionFailure.catalogUnavailable }
        let models = data.compactMap { row -> SubscriptionModel? in
            guard row["hidden"] as? Bool != true, let id = row["model"] as? String,
                  !id.isEmpty else { return nil }
            return SubscriptionModel(id: id, name: row["displayName"] as? String ?? id,
                                     isDefault: row["isDefault"] as? Bool ?? false)
        }
        return (models, result["nextCursor"] as? String)
    }

    private nonisolated static func rpcObject(_ line: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }

    private static func neutralDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dorax-chatgpt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return url
    }

    /// Reuses the worker's parser/transport. No hidden CLI session or implicit API fallback.
    static func sendSubscription(
        message: String, systemPrompt: String, history: [ChatMessage] = [],
        model: String? = nil, timeout: TimeInterval = 120,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        guard let binary = binaryPath() else { throw Failure.notInstalled }
        return try await TurnRecorder.run(provider: AIProvider.chatGPTSubscription.rawValue) {
            let directory = try neutralDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let login = try await CLIProcess.run(
                binary: binary, arguments: ["login", "status"], directory: directory,
                environment: subscriptionEnvironment(), timeout: 10)
            try validateSubscriptionLogin(output: login.stdout + login.stderr, status: login.status)
            onProgress?("ChatGPT is answering…")
            let prompt = systemPrompt + "\n\n" + ClaudeCodeCLIService.promptWithHistory(
                message: message, history: ChatHistoryBudget.fit(history, provider: .chatGPTSubscription))
            let result = try await CLIProcess.run(
                binary: binary, arguments: subscriptionArguments(model: model), directory: directory,
                environment: subscriptionEnvironment(), input: prompt, timeout: timeout)
            return try subscriptionAnswer(transcript: result.stdout, status: result.status)
        }
    }

    nonisolated static func subscriptionAnswer(transcript: String, status: Int32) throws -> String {
        let events = transcript.split(separator: "\n").map { parse(streamLine: String($0)) }
        guard status == 0, events.last(where: { $0 == .completed || isFailure($0) }) == .completed,
              let answer = report(fromTranscript: transcript) else {
            let detail = events.compactMap { event -> String? in
                if case .failure(let message) = event { return message }
                return nil
            }.last
            throw Failure.failed(detail ?? "ChatGPT did not finish. Update Codex, check sign-in, and retry.")
        }
        return answer
    }

    private nonisolated static func isFailure(_ event: StreamLine) -> Bool {
        if case .failure = event { return true }
        return false
    }
}
