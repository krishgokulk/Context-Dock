import Foundation

extension AIProviderService {
    // MARK: - Tool Definitions

    private enum ToolDefinitions {

        // run_command — blocking, returns output
        // spawn_worker — non-blocking, starts in background, returns worker_id immediately

        static let openAI: [[String: Any]] = [
            [
                "type": "function",
                "function": [
                    "name": "run_command",
                    "description": "Execute a terminal command on the user's Mac and return its output. Use for quick commands that complete fast (ls, git status, find, etc.). For long-running tools like music players or downloads, use spawn_worker instead.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "command":           ["type": "string",  "description": "The exact shell command to run"],
                            "purpose":           ["type": "string",  "description": "One-line explanation of what this command does"],
                            "requires_approval": ["type": "boolean", "description": "True when the command modifies files, installs software, or has irreversible effects"]
                        ],
                        "required": ["command", "purpose"]
                    ]
                ]
            ],
            [
                "type": "function",
                "function": [
                    "name": "spawn_worker",
                    "description": "Start a long-running command in the background without waiting for it to finish. Use for music players (ymc, ncspot), downloaders, timers, and any process that should keep running while you do other things. Returns a worker_id you can reference later.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "command": ["type": "string", "description": "The shell command to start in background"],
                            "purpose": ["type": "string", "description": "What this background process is doing"]
                        ],
                        "required": ["command", "purpose"]
                    ]
                ]
            ],
            [
                "type": "function",
                "function": [
                    "name": "send_keys",
                    "description": "Inject keystrokes directly into the active TUI app running in the live terminal panel. Use this AFTER spawn_worker has launched a TUI app to navigate its menus, press buttons, or send input. Supports: plain text, \\r (Enter), \\u{1B} (Esc), \\u{03} (Ctrl-C), \\u{1B}[A/B/C/D (arrow keys).",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "keys":    ["type": "string", "description": "The keystroke sequence to inject. Use \\r for Enter, \\u{1B}[A for up-arrow, etc."],
                            "purpose": ["type": "string", "description": "What action this keystroke performs in the TUI"]
                        ],
                        "required": ["keys", "purpose"]
                    ]
                ]
            ],
            [
                "type": "function",
                "function": [
                    "name": "get_messages_conversations",
                    "description": "Read recent Messages conversations. Use in Messages scope for questions like unread/recent messages, latest chats, or conversation summaries.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "contact_filter": ["type": "string", "description": "Optional contact name, phone, email, or empty string."],
                            "limit": ["type": "integer", "description": "Maximum conversations to return, 1-30."]
                        ],
                        "required": []
                    ]
                ]
            ],
            [
                "type": "function",
                "function": [
                    "name": "search_messages",
                    "description": "Open Messages and search for a contact, keyword, or phrase using the Messages search UI.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "query": ["type": "string", "description": "Contact name, phone, email, keyword, or phrase to search."]
                        ],
                        "required": ["query"]
                    ]
                ]
            ],
            [
                "type": "function",
                "function": [
                    "name": "compose_message",
                    "description": "Open a Messages compose window for a recipient with optional draft body. Does not send automatically; user reviews and sends.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "recipient": ["type": "string", "description": "Recipient phone, email, or contact name."],
                            "body": ["type": "string", "description": "Optional draft message body."]
                        ],
                        "required": ["recipient"]
                    ]
                ]
            ]
        ]

        static let anthropic: [[String: Any]] = [
            [
                "name": "run_command",
                "description": "Execute a terminal command and return its output. For quick commands. For music players or long downloads, use spawn_worker.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "command":           ["type": "string",  "description": "The shell command to run"],
                        "purpose":           ["type": "string",  "description": "Why this command is being run"],
                        "requires_approval": ["type": "boolean", "description": "True for destructive or write operations"]
                    ],
                    "required": ["command", "purpose"]
                ]
            ],
            [
                "name": "spawn_worker",
                "description": "Start a long-running command in the background. Returns immediately with a worker_id. Use for music players, downloads, timers.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "command": ["type": "string", "description": "The command to run in background"],
                        "purpose": ["type": "string", "description": "What this process is doing"]
                    ],
                    "required": ["command", "purpose"]
                ]
            ],
            [
                "name": "send_keys",
                "description": "Inject keystrokes into the active TUI app in the live terminal panel. Use after spawn_worker to navigate menus, select options, or send input. Supports \\r (Enter), \\u{1B} (Esc), \\u{03} (Ctrl-C), arrow keys.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "keys":    ["type": "string", "description": "Keystroke sequence to inject into the TUI"],
                        "purpose": ["type": "string", "description": "What this keystroke does"]
                    ],
                    "required": ["keys", "purpose"]
                ]
            ]
        ]

        static let gemini: [String: Any] = [
            "function_declarations": [
                [
                    "name": "run_command",
                    "description": "Execute a terminal command and return its output.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "command": ["type": "string", "description": "The shell command to run"],
                            "purpose": ["type": "string", "description": "Why this command is being run"],
                            "requires_approval": ["type": "boolean"]
                        ],
                        "required": ["command", "purpose"]
                    ]
                ],
                [
                    "name": "spawn_worker",
                    "description": "Start a long-running background command. Returns a worker_id immediately.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "command": ["type": "string", "description": "Command to run in background"],
                            "purpose": ["type": "string", "description": "What the process does"]
                        ],
                        "required": ["command", "purpose"]
                    ]
                ],
                [
                    "name": "send_keys",
                    "description": "Inject keystrokes into the active TUI app in the live terminal. Use after spawn_worker.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "keys":    ["type": "string", "description": "Keystroke sequence to inject"],
                            "purpose": ["type": "string", "description": "What this keystroke does"]
                        ],
                        "required": ["keys", "purpose"]
                    ]
                ]
            ]
        ]
    }

    /// Dispatch a custom L2 extension tool call. Returns (success, output).
    private func dispatchCustomTool(name: String, arguments: [String: Any]) async -> (Bool, String) {
        let (success, output) = await L2ExtensionManager.shared.execute(toolName: name, arguments: arguments)
        return (success, output)
    }

    // MARK: - OpenAI / Ollama Tool Loop

    func sendOpenAIWithTools(
        message: String,
        contextPrompt: String,
        apiKey: String?,
        history: [ChatMessage],
        commandExecutor: @escaping (String, String) async -> (Bool, String),
        customTools: [[String: Any]] = [],
        maxIterations: Int,
        endpoint: String,
        model: String,
        timeout: TimeInterval = 60,
        extraHeaders: [String: String] = [:],
        transport: any OpenAIToolTransport,
        simulateAllTools: Bool
    ) async throws -> (finalResponse: String, executedCommands: [ExecutedCommand]) {

        var executedCommands: [ExecutedCommand] = []

        var messages: [[String: Any]] = [["role": "system", "content": contextPrompt]]
        for msg in history.suffix(10).filter({ $0.role != .system }) {
            messages.append(["role": msg.role.rawValue, "content": msg.content])
        }
        messages.append(["role": "user", "content": message])

        let allTools = ToolDefinitions.openAI + customTools

        for _ in 0..<maxIterations {
            var body: [String: Any] = [
                "model": model,
                "messages": messages,
                "tools": allTools,
                "tool_choice": "auto",
                // No temperature: newer Claude models served through OpenAI-compatible
                // proxies reject sampling parameters with HTTP 400.
                "max_tokens": 1000
            ]
            if apiKey == nil { body["stream"] = false; body.removeValue(forKey: "max_tokens") }
            let decoded = try await transport.send(
                endpoint: endpoint,
                apiKey: apiKey,
                body: body,
                timeout: timeout,
                extraHeaders: extraHeaders
            )
            guard let choice = decoded.choices.first else { throw AIServiceError.emptyResponse("No response") }

            if let toolCalls = choice.message.tool_calls, !toolCalls.isEmpty {
                var assistantMsg: [String: Any] = ["role": "assistant"]
                if let content = choice.message.content { assistantMsg["content"] = content }
                assistantMsg["tool_calls"] = toolCalls.map { tc -> [String: Any] in
                    ["id": tc.id, "type": tc.type, "function": ["name": tc.function.name, "arguments": tc.function.arguments]]
                }
                messages.append(assistantMsg)

                for tc in toolCalls {
                    guard let argsData = tc.function.arguments.data(using: .utf8),
                          let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                    else { continue }

                    var (success, output): (Bool, String) = (false, "")
                    if simulateAllTools {
                        success = true
                        output = "Simulated \(tc.function.name) tool call"
                        executedCommands.append(ExecutedCommand(command: tc.function.name, output: output, success: true))
                    } else if tc.function.name == "run_command",
                       let command = args["command"] as? String,
                       let purpose = args["purpose"] as? String {
                        (success, output) = await commandExecutor(command, purpose)
                        executedCommands.append(ExecutedCommand(command: "\(tc.function.name)(\(command))", output: output, success: success))
                    } else if tc.function.name == "spawn_worker",
                              let command = args["command"] as? String,
                              let purpose = args["purpose"] as? String {
                        let workerID = await TerminalCommandExecutor.shared.spawnWorker(command: command, purpose: purpose)
                        output = "{\"worker_id\": \"\(workerID)\", \"status\": \"running\", \"message\": \"'\(command)' started in background.\"}"
                        success = true
                        executedCommands.append(ExecutedCommand(command: "spawn_worker(\(command))", output: output, success: true))
                    } else if tc.function.name == "send_keys",
                              let keys = args["keys"] as? String {
                        let purpose = args["purpose"] as? String ?? ""
                        output = await TerminalCommandExecutor.shared.sendKeys(keys)
                        success = true
                        executedCommands.append(ExecutedCommand(command: "send_keys(\(keys))", output: output, success: true))
                        // Small delay after key injection so TUI can react before next tool call
                        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                        _ = purpose
                    } else if tc.function.name == "get_messages_conversations" {
                        let contactFilter = args["contact_filter"] as? String ?? ""
                        let limit = args["limit"] as? Int ?? 15
                        output = MessagesAutomation.conversationSnapshot(
                            contactFilter: contactFilter,
                            limit: limit
                        )
                        success = true
                        executedCommands.append(ExecutedCommand(command: "get_messages_conversations", output: output, success: true))
                    } else if tc.function.name == "search_messages",
                              let query = args["query"] as? String {
                        output = await MessagesAutomation.openSearch(query: query)
                        success = !output.hasPrefix("❌")
                        executedCommands.append(ExecutedCommand(command: "search_messages(\(query))", output: output, success: success))
                    } else if tc.function.name == "compose_message",
                              let recipient = args["recipient"] as? String {
                        let body = args["body"] as? String ?? ""
                        output = await MessagesAutomation.composeMessage(to: recipient, body: body)
                        success = !output.hasPrefix("❌")
                        executedCommands.append(ExecutedCommand(command: "compose_message(\(recipient))", output: output, success: success))
                    } else {
                        // Custom L2 extension tool call
                        (success, output) = await dispatchCustomTool(name: tc.function.name, arguments: args)
                        executedCommands.append(ExecutedCommand(command: "\(tc.function.name)(\(args))", output: output, success: success))
                    }
                    messages.append(["role": "tool", "tool_call_id": tc.id,
                                     "content": output.isEmpty ? "(no output)" : output])
                }
            } else {
                return (choice.message.content ?? "(no response)", executedCommands)
            }
        }
        return ("Commands completed.", executedCommands)
    }

    // MARK: - Anthropic Tool Loop

    func sendAnthropicWithTools(
        message: String,
        contextPrompt: String,
        apiKey: String,
        history: [ChatMessage],
        commandExecutor: @escaping (String, String) async -> (Bool, String),
        customTools: [[String: Any]] = [],
        maxIterations: Int,
        model: String,
        simulateAllTools: Bool
    ) async throws -> (finalResponse: String, executedCommands: [ExecutedCommand]) {

        var executedCommands: [ExecutedCommand] = []

        var messages: [[String: Any]] = []
        for msg in history.suffix(10).filter({ $0.role != .system }) {
            messages.append(["role": msg.role.rawValue, "content": msg.content])
        }
        messages.append(["role": "user", "content": message])

        for _ in 0..<maxIterations {
            let body: [String: Any] = [
                "model": model,
                "system": contextPrompt,
                "messages": messages,
                "tools": ToolDefinitions.anthropic + customTools,
                "max_tokens": 1024
            ]
            let decoded = try await AnthropicToolProviderAdapter().send(apiKey: apiKey, body: body)
            let textBlocks   = decoded.content.filter { $0.type == "text" }
            let toolUseBlocks = decoded.content.filter { $0.type == "tool_use" }

            if toolUseBlocks.isEmpty {
                let text = textBlocks.compactMap { $0.text }.joined(separator: "\n")
                return (text.isEmpty ? "(no response)" : text, executedCommands)
            }

            // Echo full assistant content block array back
            let assistantBlocks: [[String: Any]] = decoded.content.map { block in
                var d: [String: Any] = ["type": block.type]
                if let t = block.text  { d["text"] = t }
                if let id = block.id   { d["id"] = id }
                if let n = block.name  { d["name"] = n }
                if let input = block.input { d["input"] = input.mapValues { $0.value } }
                return d
            }
            messages.append(["role": "assistant", "content": assistantBlocks])

            var resultBlocks: [[String: Any]] = []
            for block in toolUseBlocks {
                guard let toolId = block.id,
                      let toolName = block.name,
                      let inputDict = block.input
                else { continue }

                let args = inputDict.mapValues { $0.value }
                var (success, output): (Bool, String) = (false, "")

                if simulateAllTools {
                    success = true
                    output = "Simulated \(toolName) tool call"
                    executedCommands.append(ExecutedCommand(command: toolName, output: output, success: true))
                } else if toolName == "run_command",
                   let command = args["command"] as? String,
                   let purpose = args["purpose"] as? String {
                    (success, output) = await commandExecutor(command, purpose)
                    executedCommands.append(ExecutedCommand(command: command, output: output, success: success))
                } else if toolName == "spawn_worker",
                          let command = args["command"] as? String,
                          let purpose = args["purpose"] as? String {
                    let workerID = await TerminalCommandExecutor.shared.spawnWorker(command: command, purpose: purpose)
                    output = "{\"worker_id\": \"\(workerID)\", \"status\": \"running\"}"
                    success = true
                    executedCommands.append(ExecutedCommand(command: "spawn_worker(\(command))", output: output, success: true))
                } else if toolName == "send_keys",
                          let keys = args["keys"] as? String {
                    output = await TerminalCommandExecutor.shared.sendKeys(keys)
                    success = true
                    executedCommands.append(ExecutedCommand(command: "send_keys(\(keys))", output: output, success: true))
                    try? await Task.sleep(nanoseconds: 300_000_000)
                } else {
                    (success, output) = await dispatchCustomTool(name: toolName, arguments: args)
                    executedCommands.append(ExecutedCommand(command: "\(toolName)(\(args))", output: output, success: success))
                }

                resultBlocks.append([
                    "type": "tool_result",
                    "tool_use_id": toolId,
                    "content": output.isEmpty ? "(no output)" : output
                ])
            }
            messages.append(["role": "user", "content": resultBlocks])
        }
        return ("Commands completed.", executedCommands)
    }

    // MARK: - Gemini Tool Loop

    func sendGeminiWithTools(
        message: String,
        contextPrompt: String,
        apiKey: String,
        history: [ChatMessage],
        commandExecutor: @escaping (String, String) async -> (Bool, String),
        customTools: [[String: Any]] = [],
        maxIterations: Int,
        simulateAllTools: Bool
    ) async throws -> (finalResponse: String, executedCommands: [ExecutedCommand]) {

        var executedCommands: [ExecutedCommand] = []

        var contents: [[String: Any]] = [
            ["role": "user",  "parts": [["text": contextPrompt]]],
            ["role": "model", "parts": [["text": "Understood. I'll help with the context provided."]]]
        ]
        for msg in history.suffix(10).filter({ $0.role != .system }) {
            let role = msg.role == .assistant ? "model" : "user"
            contents.append(["role": role, "parts": [["text": msg.content]]])
        }
        contents.append(["role": "user", "parts": [["text": message]]])

        for _ in 0..<maxIterations {
            let body: [String: Any] = [
                "contents": contents,
                "tools": [ToolDefinitions.gemini] + customTools.map { ["function_declarations": [$0]] },
                "generationConfig": ["temperature": 0.7, "maxOutputTokens": 1000]
            ]
            let decoded = try await GeminiToolProviderAdapter().send(apiKey: apiKey, body: body)
            guard let candidate = decoded.candidates.first else { throw AIServiceError.emptyResponse("No response") }

            let textParts     = candidate.content.parts.filter { $0.text != nil }
            let functionParts = candidate.content.parts.filter { $0.functionCall != nil }

            if functionParts.isEmpty {
                let text = textParts.compactMap { $0.text }.joined(separator: "\n")
                return (text.isEmpty ? "(no response)" : text, executedCommands)
            }

            // Echo model turn
            let modelParts: [[String: Any]] = candidate.content.parts.map { part in
                if let fc = part.functionCall {
                    return ["functionCall": ["name": fc.name, "args": fc.args.mapValues { $0.value }]]
                }
                return ["text": part.text ?? ""]
            }
            contents.append(["role": "model", "parts": modelParts])

            var functionResultParts: [[String: Any]] = []
            for part in functionParts {
                guard let fc = part.functionCall else { continue }
                let args = fc.args.mapValues { $0.value }

                var (success, output): (Bool, String) = (false, "")
                if simulateAllTools {
                    success = true
                    output = "Simulated \(fc.name) tool call"
                    executedCommands.append(ExecutedCommand(command: fc.name, output: output, success: true))
                } else if fc.name == "run_command",
                   let command = args["command"] as? String,
                   let purpose = args["purpose"] as? String {
                    (success, output) = await commandExecutor(command, purpose)
                    executedCommands.append(ExecutedCommand(command: command, output: output, success: success))
                } else if fc.name == "spawn_worker",
                          let command = args["command"] as? String,
                          let purpose = args["purpose"] as? String {
                    let workerID = await TerminalCommandExecutor.shared.spawnWorker(command: command, purpose: purpose)
                    output = "{\"worker_id\": \"\(workerID)\", \"status\": \"running\"}"
                    success = true
                    executedCommands.append(ExecutedCommand(command: "spawn_worker(\(command))", output: output, success: true))
                } else if fc.name == "send_keys",
                          let keys = args["keys"] as? String {
                    output = await TerminalCommandExecutor.shared.sendKeys(keys)
                    success = true
                    executedCommands.append(ExecutedCommand(command: "send_keys(\(keys))", output: output, success: true))
                    try? await Task.sleep(nanoseconds: 300_000_000)
                } else {
                    (success, output) = await dispatchCustomTool(name: fc.name, arguments: args)
                    executedCommands.append(ExecutedCommand(command: "\(fc.name)(\(args))", output: output, success: success))
                }

                functionResultParts.append([
                    "functionResponse": [
                        "name": fc.name,
                        "response": ["content": output.isEmpty ? "(no output)" : output]
                    ]
                ])
            }
            contents.append(["role": "function", "parts": functionResultParts])
        }
        return ("Commands completed.", executedCommands)
    }
}
