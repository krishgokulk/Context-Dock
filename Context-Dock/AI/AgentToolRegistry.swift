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
import PDFKit

/// What a tool receives. Carries the per-request collaborators a handler may need, so
/// handlers stay free of ambient state and can be tested by constructing one of these.
/// Writes the tool loop has already made, so it does not make them twice.
///
/// A model that is unsure whether a call landed calls it again. For a read that costs a
/// duplicate request; for `notes.create` it costs a duplicate note, and one request has
/// produced four. Nothing downstream deduplicates, because at the capability layer four
/// identical creates are four legitimate creates.
///
/// So the guard sits here, where the repetition happens: an identical capability and input
/// that already succeeded moments ago returns that result again instead of writing again.
/// Two genuinely intended identical writes seconds apart is not a workflow anyone has; a
/// model looping is one we have watched.
@MainActor
enum RecentCapabilityWrites {
    private static var succeeded: [String: Date] = [:]
    /// Long enough to cover a tool loop's retries, short enough that a deliberate repeat
    /// later in the conversation is not swallowed.
    private static let window: TimeInterval = 45

    private static func key(_ capabilityID: String, _ input: [String: String]) -> String {
        capabilityID + "|" + input.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    }

    static func alreadyRan(_ capabilityID: String, input: [String: String]) -> Bool {
        guard let at = succeeded[key(capabilityID, input)] else { return false }
        return Date().timeIntervalSince(at) < window
    }

    static func record(_ capabilityID: String, input: [String: String]) {
        succeeded[key(capabilityID, input)] = Date()
    }
}

struct AgentToolContext {
    /// Runs a shell command through the classifier / argv gate / approval path.
    /// The Bool is the model's own `requires_approval` answer.
    let commandExecutor: (String, String, Bool) async -> (Bool, String, Int32)

    /// What the user had selected or focused when they asked. Capabilities read it to
    /// resolve implicit targets ("this file", "the current folder").
    var userContext: UserContext = .none

    /// Files attached to this turn.
    ///
    /// They reached the provider as vision blocks, and stopped there — the tool loop had no
    /// idea a file existed. So "read this screenshot and paste it as markdown" was answered
    /// by guessing the content was on the clipboard and running pbpaste, then inventing a
    /// `markdown` binary to pipe it through. The model was not being stupid; the attachment
    /// was invisible from where it was standing.
    var attachments: [URL] = []

    init(
        commandExecutor: @escaping (String, String, Bool) async -> (Bool, String, Int32),
        userContext: UserContext = .none,
        attachments: [URL] = []
    ) {
        self.commandExecutor = commandExecutor
        self.userContext = userContext
        self.attachments = attachments
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

/// Renders a tool result for the model.
///
/// The three provider loops each computed `success` and then sent only `output` back:
///
///     messages.append(["role": "tool", "content": output.isEmpty ? "(no output)" : output])
///
/// So a command that failed and a command that returned nothing were the same eight
/// characters — "(no output)" — and the model had no way to know a call had failed. That is
/// why it could not retry: not because the loop stopped too early, but because failure was
/// invisible to it. A model that cannot see an error can only guess that its plan worked,
/// which is exactly what produced answers claiming work that never happened.
enum AgentToolTranscript {
    static func payload(success: Bool, output: String, exitCode: Int32? = nil) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        var header = success ? "status: ok" : "status: FAILED"
        if let exitCode { header += " (exit code \(exitCode))" }

        if trimmed.isEmpty {
            // Distinguish the two cases that used to look identical. "Succeeded quietly" and
            // "failed silently" call for opposite next moves.
            return success
                ? header + "\nThe command completed and produced no output. Treat that as "
                    + "success, not as missing data."
                : header + "\nThe command failed and produced no output. Do not report it as "
                    + "done — try a different approach, or say what could not be done."
        }
        if success {
            return header + "\n" + trimmed
        }
        return header + "\nerror output:\n" + trimmed
            + "\n\nRead the error and decide: retry with a corrected command, use a different "
            + "tool, or tell the user plainly what failed. Do not report this as done."
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

    /// A message pointing at the registered capability, when a shell command would do the
    /// same job to the user's own files without any of the protection.
    ///
    /// `mkdir ~/Desktop/X` and `finder.newFolder` create the same folder, but the
    /// capability shows the destination in an approval card and reads the folder back
    /// afterwards, while the shell command reports whatever mkdir's exit code said. The
    /// model picked the shell, and the user got "successfully created" on an exit code.
    ///
    /// Deliberately limited to the Finder-managed folders. Inside a repository the shell is
    /// the right tool and the capability has nothing to add — redirecting `rm` in a build
    /// directory would just be in the way.
    static func capabilityInsteadOfShell(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        let home = NSHomeDirectory()
        let userFolders = ["Desktop", "Documents", "Downloads"]
        let touchesUserFolder = userFolders.contains { folder in
            trimmed.contains("~/\(folder)") || trimmed.contains("\(home)/\(folder)")
        }
        guard touchesUserFolder else { return nil }

        if trimmed.hasPrefix("mkdir ") {
            return "Use run_capability with finder.newFolder for folders in the user's own "
                + "folders — it previews the destination for approval and confirms the "
                + "folder afterwards. Fields: destination (absolute parent path), name."
        }
        if trimmed.hasPrefix("rm ") || trimmed.hasPrefix("rm -") {
            return "Use run_capability with finder.trash instead of rm for the user's own "
                + "files — it is recoverable from the Trash and confirms the file is gone. "
                + "Field: path."
        }
        return nil
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
        // Whole-id aliases first. Families are too coarse when one mixes reading with
        // doing: "system" covers both listing running apps and taking a screenshot, and
        // giving the screenshot capability the family's "apps applications" made "what did
        // I capture from Code?" rank *taking a new screenshot* above reading the captures
        // already taken. A request to read something must not be answered by doing it.
        switch capabilityID {
        case "system.captureScreenshot":
            return "screenshot screengrab grab snap take picture of the screen new"
        // These two differ by tense, and tense is the whole question: one is what is on the
        // pasteboard now, the other is what was on it before. Sharing the family's words
        // made "what did I capture from Code?" rank the current clip first — a single item,
        // usually unrelated, presented as the answer to a question about many.
        case "clipboard.read":
            return "current now latest pasteboard paste this what is copied"
        case "capture.text":
            return "ocr read text on screen snip select region grab words from picture "
                + "scan recognise recognize"
        case "capture.area":
            return "region area crop snip selection part of the screen rectangle grab"
        case "app.menu.click":
            return "menu minimize maximize zoom hide quit close window save open new "
                + "preferences settings command item click run app"
        case "app.insertText":
            return "insert paste type write put text into markdown convert replace "
                + "editor document frontmost app"
        case "clipboard.history":
            return "history earlier previous past clips captures captured capturing "
                + "screenshots screenshot ocr snippets from source app apps saved took "
                + "taken all list recent"
        default: break
        }

        switch capabilityID.split(separator: ".").first.map(String.init) ?? "" {
        // Both clipboard capabilities are matched by whole id above; this covers any that
        // are added later without their own entry.
        case "clipboard": return "copied copy paste pasteboard cut clip"
        case "extensions": return "extension extensions script scripts plugin plugins addon"
        case "globalcmd":
            return "command commands global system toggle setting settings shortcut"
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
        // The words people actually use. A capability is only findable through the terms
        // its user would type, and nobody asks about their "browser history capability" —
        // they ask whether they visited a website. Registering the reader without these is
        // registering something that still cannot be found.
        case "browser":
            return "website websites site sites web page pages visit visited visiting "
                + "browsing browse url urls link links tab tabs bookmark bookmarks safari "
                + "chrome edge brave arc firefox online internet read looked"
        case "files":
            return "file document documents recent recently opened downloads folder search find"
        case "quicknotes":
            return "note notes captured capture saved jot scratch snippet quick"
        case "apps":
            return "app application applications used usage often frequently favourite favorite"
        case "project": return "build compile make run test rebuild"
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
            if let redirect = Self.capabilityInsteadOfShell(command) {
                return AgentToolResult(
                    success: false,
                    output: redirect,
                    displayCommand: "run_command(\(command))")
            }
            let needsApproval = arguments["requires_approval"] as? Bool ?? false
            let (success, output, exitCode) = await context.commandExecutor(
                command, purpose, needsApproval)
            return AgentToolResult(
                success: success,
                output: output,
                displayCommand: "run_command(\(command))",
                exitCode: exitCode)
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
            name: "read_attachment",
            description: "Read a file the user attached to this message — OCR for images and "
                + "screenshots, plain text for text/markdown/code, extracted text for PDFs. "
                + "Call this FIRST whenever the user says \"this\", \"this screenshot\", "
                + "\"the attached file\", or asks to convert, summarise or reformat something "
                + "they attached. Do not guess the content from the clipboard.",
            properties: [
                "index": [
                    "type": "integer",
                    "description": "Which attachment, 0-based. Omit for the first one.",
                ]
            ],
            required: []
        ) { arguments, context in
            let attachments = context.attachments
            guard !attachments.isEmpty else {
                return AgentToolResult(
                    success: false,
                    output: "Nothing is attached to this message.",
                    displayCommand: "read_attachment()")
            }
            let index = (arguments["index"] as? Int) ?? 0
            guard attachments.indices.contains(index) else {
                return AgentToolResult(
                    success: false,
                    output: "There \(attachments.count == 1 ? "is 1 attachment" : "are \(attachments.count) attachments"), so index \(index) doesn't exist.",
                    displayCommand: "read_attachment(\(index))")
            }
            let url = attachments[index]
            let label = url.lastPathComponent
            guard let data = try? Data(contentsOf: url) else {
                return AgentToolResult(
                    success: false,
                    output: "Couldn't read \(label).",
                    displayCommand: "read_attachment(\(label))")
            }

            let imageTypes: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "tiff", "bmp", "webp"]
            let ext = url.pathExtension.lowercased()
            var text = ""
            if imageTypes.contains(ext) {
                text = ScreenCaptureService.recognizeText(in: data)
                if text.isEmpty {
                    // An image with no text is a real answer, not a failure — and saying so
                    // stops the model inventing content it cannot see.
                    return AgentToolResult(
                        success: true,
                        output: "\(label) is an image with no readable text in it. If the user "
                            + "is asking about what it depicts, describe it from the image you "
                            + "were shown rather than from this tool.",
                        displayCommand: "read_attachment(\(label))")
                }
            } else if ext == "pdf" {
                text = PDFDocument(url: url)?.string ?? ""
            } else {
                text = String(data: data, encoding: .utf8) ?? ""
            }

            guard !text.isEmpty else {
                return AgentToolResult(
                    success: false,
                    output: "\(label) has no text I can extract.",
                    displayCommand: "read_attachment(\(label))")
            }
            // Bounded: a long PDF would otherwise crowd out the rest of the turn.
            let clipped = text.count > 20_000
                ? String(text.prefix(20_000)) + "\n…(truncated)" : text
            return AgentToolResult(
                success: true,
                output: "Contents of \(label):\n\n\(clipped)",
                displayCommand: "read_attachment(\(label))")
        })

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
            // App adapter actions are DoraX routes too, and the scope prompt lists them —
            // but they were invisible to the tool the model is told to search with, so it
            // guessed ids from the prompt and got a failure back.
            let adapterMatches = await MainActor.run { () -> [(String, String, String)] in
                guard !terms.isEmpty else { return [] }
                var out: [(score: Int, line: (String, String, String))] = []
                for adapter in AppAdapterManager.shared.adapters where adapter.isEnabled {
                    for action in adapter.actions where action.type != .aiPrompt {
                        let haystack = "\(action.id) \(action.name) \(adapter.appName)".lowercased()
                        let score = terms.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
                        guard score > 0 else { continue }
                        out.append(
                            (score, (action.id, action.name, adapter.appName)))
                    }
                }
                return out.sorted { $0.score > $1.score }.prefix(8).map(\.line)
            }
            let adapterLines = adapterMatches.map { id, name, app in
                "- \(id): \(name) (\(app) app action) | input: [] | risk: low"
            }

            guard !matches.isEmpty || !adapterLines.isEmpty else {
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
                    + (lines + adapterLines).joined(separator: "\n"),
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
            // An id that is not a registered capability is usually an app adapter's action
            // id: the scope prompt lists those for `adapter_call`, and a model asked to
            // "run this" reaches for the tool named run_capability. Both are DoraX routes
            // to the same action, so run it rather than reporting a failure the user can
            // do nothing about.
            if CapabilityRegistry.shared.capability(id: capabilityID) == nil,
                let adapter = AppAdapterManager.shared.adapters.first(where: { candidate in
                    candidate.actions.contains { $0.id == capabilityID }
                }),
                let action = adapter.actions.first(where: { $0.id == capabilityID })
            {
                let (ok, output) = await AppAdapterManager.shared.execute(
                    action,
                    context: AXContextReader.shared.current,
                    targetBundleId: adapter.bundleId,
                    query: explanation)
                return AgentToolResult(
                    success: ok,
                    output: output.isEmpty
                        ? (ok ? "Done — \(action.name)." : "Couldn't run \(action.name).")
                        : output,
                    displayCommand: "run_capability(\(capabilityID))")
            }

            // A capability that changes something and already ran with these exact inputs is
            // not run again. Reads are exempt: repeating one is harmless, and refusing it
            // would stop the model re-checking state it is right to re-check.
            let capability = CapabilityRegistry.shared.capability(id: capabilityID)
            let isWrite = capability.map { $0.riskLevel != .low } ?? false
            if isWrite, RecentCapabilityWrites.alreadyRan(capabilityID, input: input) {
                return AgentToolResult(
                    success: true,
                    output: "Already done a moment ago with exactly these inputs — not "
                        + "repeated. Continue; do not call this again.",
                    displayCommand: "run_capability(\(capabilityID))")
            }

            let plan = AIActionPlan(
                capability: capabilityID, input: input, explanation: explanation)
            do {
                let result = try await AIExecutionEngine.shared.executeWithApproval(
                    plan, context: context.userContext)
                if result.success, isWrite {
                    RecentCapabilityWrites.record(capabilityID, input: input)
                }
                // Read the write back, exactly as the candidate path does. Without this the
                // tool loop reported whatever the executor returned, and an executor
                // returning success means the command ran — not that the thing exists.
                var output = result.output.isEmpty
                    ? (result.success ? "(completed, no output)" : "(failed, no output)")
                    : result.output
                var succeeded = result.success
                if result.success {
                    switch await GeneralAIActionExecutor.shared.verifyCapability(
                        id: capabilityID, inputValues: input)
                    {
                    case .verified(let refined):
                        output = refined ?? output
                    case .unverified(let fallback):
                        // The command ran and the result could not be found. Saying so is
                        // the whole point; reporting success here is how a chat claims to
                        // have created something that is not there.
                        succeeded = false
                        output = "\(output)\n\nCouldn't confirm it: \(fallback)"
                    case .skipped:
                        break
                    }
                }
                return AgentToolResult(
                    success: succeeded,
                    output: output,
                    displayCommand: "run_capability(\(capabilityID))")
            } catch {
                // Name the failure precisely: "unknown id" and "the capability ran and
                // failed" need different next moves from the model, and one vague message
                // for both is what produced "it seems there was an issue".
                let known = CapabilityRegistry.shared.capability(id: capabilityID) != nil
                return AgentToolResult(
                    success: false,
                    output: known
                        ? "\(capabilityID) failed: \(error.localizedDescription)"
                        : "No capability or app action with id \"\(capabilityID)\". Call "
                            + "find_capability first and use an id it returns.",
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
