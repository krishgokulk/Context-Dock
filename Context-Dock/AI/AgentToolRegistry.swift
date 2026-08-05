// AgentToolRegistry.swift
// One place that knows what tools exist, what they look like to a provider, and how to run
// one by name.
//
// Before this, the same dispatch chain was written three times — once per provider loop —
// as `if name == "run_command" … else if name == "spawn_worker" … else if …`. Three copies
// of the same knowledge means a tool added to one loop is missing from the others, and it
// is why the OpenAI loop knows three Messages tools that the Anthropic and Gemini loops do
// not. The chains also fixed the tool list at compile time, so a capability could be
// registered, executable, and impossible for a model to call.
//
// The registry is keyed by name because that is how a model refers to a tool. Registering is
// the only step required to make a tool callable from every provider.

import Foundation

/// What a tool receives. Carries the per-request collaborators a handler may need, so
/// handlers stay free of ambient state and can be tested by constructing one of these.
struct AgentToolContext {
    /// Runs a shell command through the classifier / argv gate / approval path.
    /// The Bool is the model's own `requires_approval` answer.
    let commandExecutor: (String, String, Bool) async -> (Bool, String)

    /// What the user had selected or focused when they asked. Capabilities read it to
    /// resolve implicit targets ("this file", "the current folder").
    var userContext: UserContext = .none

    init(
        commandExecutor: @escaping (String, String, Bool) async -> (Bool, String),
        userContext: UserContext = .none
    ) {
        self.commandExecutor = commandExecutor
        self.userContext = userContext
    }
}

/// What a tool returns.
///
/// `exitCode`, `stdout` and `stderr` are carried separately from `output` even though most
/// callers only read `output` today. A loop that can see an exit code can retry on failure;
/// one that receives a formatted blob can only guess. Populating them now means the
/// verification step is a change to the loop, not to every tool.
struct AgentToolResult {
    let success: Bool
    let output: String
    /// How this call should read in the executed-commands transcript.
    let displayCommand: String
    var exitCode: Int32?
    var stdout: String?
    var stderr: String?

    init(
        success: Bool,
        output: String,
        displayCommand: String,
        exitCode: Int32? = nil,
        stdout: String? = nil,
        stderr: String? = nil
    ) {
        self.success = success
        self.output = output
        self.displayCommand = displayCommand
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// A callable tool: its schema for the provider, and how to run it.
struct AgentTool {
    let name: String
    let description: String
    /// JSON-schema `properties` for this tool's arguments.
    let properties: [String: Any]
    let required: [String]
    let handler: (_ arguments: [String: Any], _ context: AgentToolContext) async -> AgentToolResult
}

@MainActor
final class AgentToolRegistry {
    static let shared = AgentToolRegistry()

    private var tools: [String: AgentTool] = [:]
    private var didRegisterBuiltIns = false

    private init() {}

    // MARK: - Registration

    func register(_ tool: AgentTool) {
        tools[tool.name] = tool
    }

    func tool(named name: String) -> AgentTool? {
        registerBuiltInsIfNeeded()
        return tools[name]
    }

    var allTools: [AgentTool] {
        registerBuiltInsIfNeeded()
        return tools.values.sorted { $0.name < $1.name }
    }

    // MARK: - Dispatch

    /// Runs a tool by name. Returns nil when no tool is registered under that name, so the
    /// caller can fall back — today that means an L2 extension tool, which is resolved
    /// dynamically and therefore cannot be pre-registered here.
    func dispatch(
        name: String,
        arguments: [String: Any],
        context: AgentToolContext
    ) async -> AgentToolResult? {
        guard let tool = tool(named: name) else { return nil }
        return await tool.handler(arguments, context)
    }

    // MARK: - Schemas

    enum SchemaFormat {
        case openAI
        case anthropic
        case gemini
    }

    /// The tool list as a provider expects to receive it. One source, three renderings —
    /// the differences between providers are pure formatting, and keeping them here stops
    /// the tool sets drifting apart per provider.
    func schemas(format: SchemaFormat) -> [[String: Any]] {
        allTools.map { tool in
            switch format {
            case .openAI:
                return [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": [
                            "type": "object",
                            "properties": tool.properties,
                            "required": tool.required,
                        ],
                    ],
                ]
            case .anthropic:
                return [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": [
                        "type": "object",
                        "properties": tool.properties,
                        "required": tool.required,
                    ],
                ]
            case .gemini:
                return [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": [
                        "type": "object",
                        "properties": tool.properties,
                        "required": tool.required,
                    ],
                ]
            }
        }
    }

    // MARK: - Search aliases

    /// Extra words that should match a capability whose id and title do not contain them.
    ///
    /// This is search vocabulary, not routing: it only widens what `find_capability` will
    /// surface, and the model still decides whether any result fits. Without it, "paste what
    /// I copied" matched nothing, because no word in the phrase appears in "clipboard.read /
    /// Read Clipboard" — the model would have had to guess the word DoraX happens to use.
    private static func searchAliases(for capabilityID: String) -> String {
        switch capabilityID.split(separator: ".").first.map(String.init) ?? "" {
        case "clipboard": return "copied copy paste pasteboard cut"
        case "notifications": return "alerts unread banners"
        case "skills": return "workflows playbooks instructions prompts"
        case "system": return "apps applications open running processes frontmost"
        case "window": return "windows resize move fullscreen split tile screen layout"
        case "git": return "commit commits branch repository repo diff staged version control"
        case "notes": return "note memo jot"
        case "calendar": return "event events meeting schedule agenda"
        case "reminders": return "todo task tasks"
        case "contacts": return "person people address phone email"
        case "finder": return "file files folder folders trash disk"
        case "music": return "song songs track play playback"
        case "messages": return "imessage text texts chat"
        case "mail": return "email emails inbox"
        case "photos": return "image images picture pictures"
        case "xcode": return "build compile project scheme"
        default: return ""
        }
    }

    // MARK: - Built-in tools

    private func registerBuiltInsIfNeeded() {
        guard !didRegisterBuiltIns else { return }
        didRegisterBuiltIns = true

        register(AgentTool(
            name: "run_command",
            description: "Execute a terminal command on the user's Mac and return its output. "
                + "Use for commands that complete quickly (ls, git status, find). For long-running "
                + "processes like media players or downloads, use spawn_worker instead.",
            properties: [
                "command": ["type": "string", "description": "The exact shell command to run"],
                "purpose": ["type": "string", "description": "One-line explanation of what this command does"],
                "requires_approval": [
                    "type": "boolean",
                    "description": "True when the command modifies files, installs software, or has irreversible effects",
                ],
            ],
            required: ["command", "purpose"]
        ) { arguments, context in
            guard let command = arguments["command"] as? String,
                  let purpose = arguments["purpose"] as? String
            else {
                return AgentToolResult(
                    success: false,
                    output: "run_command requires 'command' and 'purpose'.",
                    displayCommand: "run_command(invalid)")
            }
            let needsApproval = arguments["requires_approval"] as? Bool ?? false
            let (success, output) = await context.commandExecutor(command, purpose, needsApproval)
            return AgentToolResult(
                success: success, output: output, displayCommand: "run_command(\(command))")
        })

        register(AgentTool(
            name: "spawn_worker",
            description: "Start a long-running command in the background without waiting for it "
                + "to finish. Use for media players, downloaders, timers, and any process that "
                + "should keep running. Returns a worker_id you can reference later.",
            properties: [
                "command": ["type": "string", "description": "The shell command to start in background"],
                "purpose": ["type": "string", "description": "What this background process is doing"],
            ],
            required: ["command", "purpose"]
        ) { arguments, _ in
            guard let command = arguments["command"] as? String,
                  let purpose = arguments["purpose"] as? String
            else {
                return AgentToolResult(
                    success: false,
                    output: "spawn_worker requires 'command' and 'purpose'.",
                    displayCommand: "spawn_worker(invalid)")
            }
            let workerID = await TerminalCommandExecutor.shared.spawnWorker(
                command: command, purpose: purpose)
            return AgentToolResult(
                success: true,
                output: "{\"worker_id\": \"\(workerID)\", \"status\": \"running\", "
                    + "\"message\": \"'\(command)' started in background.\"}",
                displayCommand: "spawn_worker(\(command))")
        })

        register(AgentTool(
            name: "send_keys",
            description: "Inject keystrokes into the active TUI app running in the live terminal "
                + "panel. Use after spawn_worker has launched a TUI app, to navigate its menus or "
                + "send input. Supports plain text, \\r (Enter), \\u{1B} (Esc), \\u{03} (Ctrl-C), "
                + "and \\u{1B}[A/B/C/D for arrow keys.",
            properties: [
                "keys": ["type": "string", "description": "The keystroke sequence to inject"],
                "purpose": ["type": "string", "description": "What action this keystroke performs"],
            ],
            required: ["keys", "purpose"]
        ) { arguments, _ in
            guard let keys = arguments["keys"] as? String else {
                return AgentToolResult(
                    success: false,
                    output: "send_keys requires 'keys'.",
                    displayCommand: "send_keys(invalid)")
            }
            let output = await TerminalCommandExecutor.shared.sendKeys(keys)
            // A TUI needs a moment to react before the next call lands.
            try? await Task.sleep(nanoseconds: 300_000_000)
            return AgentToolResult(
                success: true, output: output, displayCommand: "send_keys(\(keys))")
        })

        // MARK: Capability access
        //
        // The registry holds ~50 capabilities across git, finder, notes, calendar, music,
        // reminders, xcode and more. Emitting all of them as tool schemas would cost roughly
        // 35k tokens per message, so they are reached through two tools instead: search,
        // then call. The model discovers what exists at the moment it needs it, and pays for
        // only what it looked up.

        register(AgentTool(
            name: "find_capability",
            description: "Search the user's Mac for a capability that can do something, and "
                + "get the exact id and input fields needed to run it. Use this FIRST whenever "
                + "a request involves the user's apps or data — git history, files, notes, "
                + "calendar, reminders, music, contacts, Xcode — rather than assuming you have "
                + "no access. Returns matching capability ids to pass to run_capability.",
            properties: [
                "query": [
                    "type": "string",
                    "description": "What you want to do, e.g. \"recent git commits\", "
                        + "\"search notes\", \"today's calendar events\".",
                ],
            ],
            required: ["query"]
        ) { arguments, _ in
            let query = (arguments["query"] as? String ?? "").lowercased()
            // Three characters minimum. Two-letter words are almost never the subject and
            // they substring-match inside real words — "in" hits "Window" and
            // "instructions", so "what repo am i in" ranked window.arrange above git.log.
            let terms = query
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count > 2 }
            let matches = await MainActor.run { () -> [AICapability] in
                let all = CapabilityRegistry.shared.all
                guard !terms.isEmpty else { return [] }
                return all
                    .map { capability -> (score: Int, capability: AICapability) in
                        let haystack = (capability.id + " " + capability.title
                            + " " + Self.searchAliases(for: capability.id)).lowercased()
                        let score = terms.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
                        return (score, capability)
                    }
                    .filter { $0.score > 0 }
                    .sorted { $0.score > $1.score }
                    .prefix(12)
                    .map(\.capability)
            }
            guard !matches.isEmpty else {
                return AgentToolResult(
                    success: true,
                    output: "No capability matched \"\(query)\". Registered capability families: "
                        + (await MainActor.run {
                            Set(CapabilityRegistry.shared.all.compactMap {
                                $0.id.split(separator: ".").first.map(String.init)
                            }).sorted().joined(separator: ", ")
                        })
                        + ". Try one of those words, or use run_command for anything shell-based.",
                    displayCommand: "find_capability(\(query))")
            }
            let lines = matches.map { capability -> String in
                let fields = capability.inputSchema.fields
                    .map { "\($0.name)\($0.required ? "" : "?")" }
                    .joined(separator: ", ")
                return "- \(capability.id): \(capability.title) | input: [\(fields)]"
                    + " | risk: \(capability.riskLevel.rawValue)"
            }
            return AgentToolResult(
                success: true,
                output: "Matching capabilities — call one with run_capability:\n"
                    + lines.joined(separator: "\n"),
                displayCommand: "find_capability(\(query))")
        })

        register(AgentTool(
            name: "run_capability",
            description: "Run a capability found with find_capability. High-risk capabilities "
                + "show the user an approval sheet before anything happens; you do not need to "
                + "ask for permission yourself.",
            properties: [
                "capability_id": [
                    "type": "string",
                    "description": "Exact id from find_capability, e.g. \"git.log\".",
                ],
                "input": [
                    "type": "object",
                    "description": "Input fields for this capability. Use the field names "
                        + "find_capability reported. Pass {} when it takes none.",
                ],
                "explanation": [
                    "type": "string",
                    "description": "One line on why you are running it, shown in the approval sheet.",
                ],
            ],
            required: ["capability_id"]
        ) { arguments, context in
            guard let capabilityID = arguments["capability_id"] as? String, !capabilityID.isEmpty
            else {
                return AgentToolResult(
                    success: false,
                    output: "run_capability requires 'capability_id'.",
                    displayCommand: "run_capability(invalid)")
            }
            // Input values are stringified: AIActionPlan carries [String: String], and a
            // model will happily send a number or bool for a field declared as text.
            var input: [String: String] = [:]
            if let raw = arguments["input"] as? [String: Any] {
                for (key, value) in raw {
                    input[key] = (value as? String) ?? String(describing: value)
                }
            }
            let explanation = arguments["explanation"] as? String ?? "Requested from AI chat"
            let plan = AIActionPlan(
                capability: capabilityID, input: input, explanation: explanation)
            do {
                let result = try await AIExecutionEngine.shared.executeWithApproval(
                    plan, context: context.userContext)
                return AgentToolResult(
                    success: result.success,
                    output: result.output.isEmpty
                        ? (result.success ? "(completed, no output)" : "(failed, no output)")
                        : result.output,
                    displayCommand: "run_capability(\(capabilityID))")
            } catch {
                return AgentToolResult(
                    success: false,
                    output: "\(capabilityID) failed: \(error.localizedDescription)",
                    displayCommand: "run_capability(\(capabilityID))")
            }
        })

        register(AgentTool(
            name: "get_messages_conversations",
            description: "Read recent Messages conversations. Use for questions about unread or "
                + "recent messages, latest chats, or conversation summaries.",
            properties: [
                "contact_filter": [
                    "type": "string",
                    "description": "Optional contact name, phone, email, or empty string.",
                ],
                "limit": ["type": "integer", "description": "Maximum conversations to return, 1-30."],
            ],
            required: []
        ) { arguments, _ in
            let contactFilter = arguments["contact_filter"] as? String ?? ""
            let limit = arguments["limit"] as? Int ?? 15
            let output = await MessagesAutomation.conversationSnapshot(
                contactFilter: contactFilter, limit: limit)
            return AgentToolResult(
                success: true, output: output, displayCommand: "get_messages_conversations")
        })

        register(AgentTool(
            name: "search_messages",
            description: "Open Messages and search for a contact, keyword, or phrase using the "
                + "Messages search UI.",
            properties: [
                "query": [
                    "type": "string",
                    "description": "Contact name, phone, email, keyword, or phrase to search.",
                ],
            ],
            required: ["query"]
        ) { arguments, _ in
            guard let query = arguments["query"] as? String else {
                return AgentToolResult(
                    success: false,
                    output: "search_messages requires 'query'.",
                    displayCommand: "search_messages(invalid)")
            }
            let output = await MessagesAutomation.openSearch(query: query)
            return AgentToolResult(
                success: !output.hasPrefix("❌"),
                output: output,
                displayCommand: "search_messages(\(query))")
        })

        register(AgentTool(
            name: "compose_message",
            description: "Open a Messages compose window for a recipient with an optional draft "
                + "body. Does not send automatically; the user reviews and sends.",
            properties: [
                "recipient": ["type": "string", "description": "Recipient phone, email, or contact name."],
                "body": ["type": "string", "description": "Optional draft message body."],
            ],
            required: ["recipient"]
        ) { arguments, _ in
            guard let recipient = arguments["recipient"] as? String else {
                return AgentToolResult(
                    success: false,
                    output: "compose_message requires 'recipient'.",
                    displayCommand: "compose_message(invalid)")
            }
            let body = arguments["body"] as? String ?? ""
            let output = await MessagesAutomation.composeMessage(to: recipient, body: body)
            return AgentToolResult(
                success: !output.hasPrefix("❌"),
                output: output,
                displayCommand: "compose_message(\(recipient))")
        })
    }
}
