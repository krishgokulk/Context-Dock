//  AppleScriptModelService.swift
//  Context-Dock
//
//  Dedicated automation backend: turns a natural-language instruction into runnable
//  AppleScript using a specialist model (e.g. Osaurus AppleScript-8B/16B served
//  OpenAI-compatible on 127.0.0.1:1337/v1). This is SEPARATE from the user's chat
//  provider — the chat model (ollama / LM Studio / cloud) stays whatever they picked;
//  this service is only consulted by the action/execution layer when a request is an
//  app-automation intent with no deterministic menu/adapter/shortcut route.
//
//  The model is called with strict OpenAI tool semantics: a single `run_applescript`
//  tool. The returned tool call's `script` argument is the AppleScript. A fenced
//  ```applescript block in plain content is accepted as a fallback.

import Foundation

@MainActor
final class AppleScriptModelService {
    static let shared = AppleScriptModelService()
    private init() {}

    struct GeneratedScript {
        let script: String
        /// Human summary the model optionally returns alongside the script.
        let explanation: String?
    }

    enum ServiceError: LocalizedError {
        case disabled
        case notConfigured
        case badEndpoint
        case http(Int, String)
        case emptyScript
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .disabled: return "AppleScript model is turned off."
            case .notConfigured: return "Set the AppleScript model endpoint and model ID first."
            case .badEndpoint: return "The AppleScript model endpoint URL is invalid."
            case let .http(code, msg):
                return "AppleScript model request failed (HTTP \(code)). \(msg)"
            case .emptyScript: return "The model returned no AppleScript."
            case let .transport(msg): return "Couldn't reach the AppleScript model: \(msg)"
            }
        }
    }

    var isEnabledAndConfigured: Bool {
        let s = AppSettings.shared
        return s.appleScriptModelEnabled
            && !s.appleScriptModelEndpoint.trimmingCharacters(in: .whitespaces).isEmpty
            && !s.appleScriptModelID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Generate AppleScript for an instruction. `appHint` names the target app when known
    /// so the model targets the right `tell application` block.
    func generateAppleScript(
        instruction: String,
        appHint: String? = nil
    ) async throws -> GeneratedScript {
        let settings = AppSettings.shared
        guard settings.appleScriptModelEnabled else { throw ServiceError.disabled }
        let endpoint = settings.appleScriptModelEndpoint.trimmingCharacters(in: .whitespaces)
        let modelID = settings.appleScriptModelID.trimmingCharacters(in: .whitespaces)
        guard !endpoint.isEmpty, !modelID.isEmpty else { throw ServiceError.notConfigured }
        guard let url = Self.completionURL(from: endpoint) else { throw ServiceError.badEndpoint }

        var systemPrompt =
            "You convert the user's request into a single working macOS AppleScript. "
            + "Call the run_applescript tool exactly once with the complete script. "
            + "Do not explain in prose; put everything in the tool call."
        if let appHint, !appHint.isEmpty {
            systemPrompt += " The target application is \"\(appHint)\"."
        }

        let tool: [String: Any] = [
            "type": "function",
            "function": [
                "name": "run_applescript",
                "description": "Execute an AppleScript on macOS via osascript.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "script": [
                            "type": "string",
                            "description": "The complete AppleScript source to run.",
                        ]
                    ],
                    "required": ["script"],
                ],
            ],
        ]

        let body: [String: Any] = [
            "model": modelID,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": instruction],
            ],
            "tools": [tool],
            "tool_choice": "auto",
            "temperature": 0.0,
            "stream": false,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = settings.getAPIKey(for: .openAICompatible)
        // Osaurus/LM Studio local servers ignore the key; only send if the user set one.
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ServiceError.transport(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8)?.prefix(200).description ?? ""
            throw ServiceError.http(http.statusCode, msg)
        }

        guard let script = Self.extractScript(from: data), !script.isEmpty else {
            throw ServiceError.emptyScript
        }
        return GeneratedScript(script: script, explanation: Self.extractContent(from: data))
    }

    /// Reachability + config probe for the settings "Test" button.
    func testConnection() async -> Result<String, ServiceError> {
        do {
            let generated = try await generateAppleScript(
                instruction: "Return the name of the frontmost application.")
            let preview = generated.script.split(separator: "\n").first.map(String.init) ?? "OK"
            return .success("Connected. Sample: \(preview)")
        } catch let error as ServiceError {
            return .failure(error)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    // MARK: - Parsing

    private static func completionURL(from endpoint: String) -> URL? {
        var base = endpoint
        if base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/chat/completions") { return URL(string: base) }
        return URL(string: base + "/chat/completions")
    }

    /// Pull the AppleScript out of a chat-completions response: prefer the run_applescript
    /// tool call's `script` argument; fall back to a fenced ```applescript block in content.
    private static func extractScript(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else { return nil }

        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for call in toolCalls {
                guard let fn = call["function"] as? [String: Any],
                    let argString = fn["arguments"] as? String,
                    let argData = argString.data(using: .utf8),
                    let args = try? JSONSerialization.jsonObject(with: argData) as? [String: Any]
                else { continue }
                // Accept common key spellings from different fine-tunes.
                for key in ["script", "applescript", "code", "source"] {
                    if let s = args[key] as? String,
                        !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return s.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        }

        if let content = message["content"] as? String {
            return fencedAppleScript(in: content)
        }
        return nil
    }

    private static func extractContent(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String,
            !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fencedAppleScript(in content: String) -> String? {
        // ```applescript … ``` or a bare ``` … ``` block, else the raw content.
        let lower = content.lowercased()
        if let fenceStart = lower.range(of: "```applescript")
            ?? lower.range(of: "```") {
            let afterFence = content[fenceStart.upperBound...]
            if let closeRange = afterFence.range(of: "```") {
                let inner = afterFence[afterFence.startIndex..<closeRange.lowerBound]
                let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
