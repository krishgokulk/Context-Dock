@MainActor
private func runningApplication(named name: String) -> NSRunningApplication? {
    let query = name.trimmingCharacters(in: .whitespaces).lowercased()
    guard !query.isEmpty else { return nil }
    let running = NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular
            && $0.bundleIdentifier != Bundle.main.bundleIdentifier
    }
    if let exact = running.first(where: { $0.localizedName?.lowercased() == query }) {
        return exact
    }
    if let byBundle = running.first(where: { $0.bundleIdentifier?.lowercased() == query }) {
        return byBundle
    }
    // "Code" for Visual Studio Code, "Chrome" for Google Chrome — the name the user says
    // is rarely the name in the bundle.
    return running.first {
        guard let localised = $0.localizedName?.lowercased() else { return false }
        return localised.contains(query) || query.contains(localised)
    }
}

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
import OSLog
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

/// One agent turn, as far as repeat-suppression is concerned.
///
/// The registry is a singleton and more than one chat runs against it at a time — the dock's
/// scoped chat and the chat window's threads are separate conversations sharing one process.
/// A turn identifies whose calls are whose, so one conversation starting a turn cannot erase
/// another's record, and a call repeated in a *different* turn is not mistaken for a repeat.
struct AgentTurnToken: Hashable, Sendable {
    let id: UUID
    init() { id = UUID() }
}

/// What to say when a call names inputs the capability does not have, or nil when every
/// key is declared.
///
/// Asked to remind at 5pm the model called reminders.create with `date`, and the field is
/// `dueDate`. The unknown key was dropped, the reminder was created with no due date, and
/// every check afterwards told the truth about a different thing: the read-back found it by
/// title and verified, reminders.today found nothing due today, and the user was told the
/// reminder had not been created. It had. It simply had no date, because nothing objected.
///
/// The message names what was wrong and what the names are, so the next call is right rather
/// than another guess.
extension AgentToolRegistry {
    static func undeclaredInputComplaint(
        capabilityID: String, capability: AICapability, input: [String: String]
    ) -> String? {
        let fields = capability.inputSchema.fields
        guard !fields.isEmpty else { return nil }
        let declared = Set(fields.map(\.name))
        let unknown = input.keys.filter { !declared.contains($0) }.sorted()
        guard !unknown.isEmpty else { return nil }
        let takes = fields
            .map { $0.required ? "\($0.name) (required)" : $0.name }
            .joined(separator: ", ")
        return "\(capabilityID) has no input named "
            + unknown.map { "`\($0)`" }.joined(separator: ", ")
            + ". It takes: \(takes). Call it again using those names — nothing ran."
    }
}

/// Why a path cannot be read as text, or nil when it can.
///
/// A content check that could not be performed is not a content check that failed, and
/// saying "does not contain the expected text" about a directory is the second kind wearing
/// the first kind's words. Asked to confirm a reminder, a model checked
/// ~/Library/Reminders/Reminders — a directory holding a SQLite store — was told the text
/// was not there, and reported to the user that the reminder had not been created. It had.
extension AgentToolRegistry {
    static func unreadableAsText(_ path: String) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return "Nothing exists at \(path), so its contents prove nothing either way. "
                + "This check could not be performed."
        }
        if isDirectory.boolValue {
            return "\(path) is a directory, not a text file. Its contents cannot be searched "
                + "this way and this check proves nothing. Use a capability that reads the "
                + "data, or trust a read-back that already ran."
        }
        guard (try? String(contentsOfFile: path, encoding: .utf8)) != nil else {
            return "\(path) could not be read as text — it is binary or uses another "
                + "encoding. This check proves nothing."
        }
        return nil
    }
}

struct AgentToolContext {
    /// Runs a shell command through the classifier / argv gate / approval path.
    /// The Bool is the model's own `requires_approval` answer.
    let commandExecutor: (String, String, Bool) async -> (Bool, String, Int32)

    /// Factual execution progress for the chat surface. This reports observable lifecycle
    /// events only (tool selected, started, completed); it never exposes model chain-of-thought.
    var onStatus: ((String) -> Void)? = nil

    /// Apps this conversation is allowed to reach, by lowercased name and by bundle id.
    ///
    /// A scoped thread has exactly one; General Chat has whichever the user granted at the
    /// access gate. Without it, a tool asked about "Pearcleaner" in General Chat had no way
    /// to turn that word into a bundle id, so it refused — one message after the user had
    /// explicitly said yes to that app.
    var grantedApps: [String: String] = [:]

    /// The turn these calls belong to. Nil means no repeat-suppression: a one-shot repair
    /// pass (the answer verifier) is deliberately allowed to re-run a call the turn it is
    /// checking already made — that re-run is the whole point of it.
    var turn: AgentTurnToken? = nil

    /// What the user had selected or focused when they asked. Capabilities read it to
    /// resolve implicit targets ("this file", "the current folder").
    var userContext: UserContext = .none

    /// What the user actually asked, verbatim.
    ///
    /// The tool loop could see authority and risk and never intent, so "what's in my trash
    /// bin" was answered by calling the Empty Trash capability — permitted, high risk,
    /// approved on a card, and the wrong thing entirely. A question is not a licence to
    /// write, and deciding that needs the sentence the user typed.
    var userRequest: String = ""

    /// Files attached to this turn.
    ///
    /// They reached the provider as vision blocks, and stopped there — the tool loop had no
    /// idea a file existed. So "read this screenshot and paste it as markdown" was answered
    /// by guessing the content was on the clipboard and running pbpaste, then inventing a
    /// `markdown` binary to pipe it through. The model was not being stupid; the attachment
    /// was invisible from where it was standing.
    var attachments: [URL] = []

    /// The thread this turn belongs to. Carries the folder a capability may not reach
    /// outside of, and where a report it produces should be filed. Without it, every
    /// capability called through the tool loop ran unscoped — the boundary the folder
    /// threads promise existed only on the prose-recovery path.
    var chatScope: GeneralChatScope? = nil

    init(
        commandExecutor: @escaping (String, String, Bool) async -> (Bool, String, Int32),
        userContext: UserContext = .none,
        userRequest: String = "",
        attachments: [URL] = [],
        chatScope: GeneralChatScope? = nil,
        grantedApps: [String: String] = [:],
        turn: AgentTurnToken? = nil,
        onStatus: ((String) -> Void)? = nil
    ) {
        self.commandExecutor = commandExecutor
        self.userContext = userContext
        self.userRequest = userRequest
        self.attachments = attachments
        self.chatScope = chatScope
        self.grantedApps = grantedApps
        self.turn = turn
        self.onStatus = onStatus
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
    /// Set when this call did not merely act but read the result back and saw it — the
    /// reading itself, in the words the user would be shown. It is the strongest evidence
    /// the system produces, and it ends the question for the rest of the turn.
    var verifiedByReadBack: String? = nil

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
    @MainActor
    static func capabilityInsteadOfShell(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        let home = NSHomeDirectory()
        // Anywhere in the user's own tree, not three named folders. A folder thread can be
        // rooted at ~/Pictures/Screenshot or ~/Projects, and a shell rearrangement of those
        // is exactly as unwanted as one of Desktop.
        let touchesUserFolder = trimmed.contains("~/") || trimmed.contains(home + "/")
        guard touchesUserFolder else { return nil }

        // Chained commands are rejected by the gate anyway, but the redirect should name
        // the right tool for what was intended rather than let the model discover the
        // refusal one command at a time.
        let verb = trimmed
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        guard !verb.isEmpty,
            let capability = CapabilityRegistry.shared.capabilitySuperseding(shellVerb: verb)
        else { return nil }

        // Built from the capability itself, so its real field names are quoted and a new
        // capability is preferred the moment it declares the verb — no second list to
        // update, and no advice that names a field the capability does not have.
        let fields: [AICapabilityInputField] = capability.inputSchema.fields
        let required = fields.filter { $0.required }.map { $0.name }
        let optional = fields.filter { !$0.required }.map { $0.name }
        var advice = "Use run_capability with \(capability.id) instead of `\(verb)` for the "
            + "user's own files — \(capability.title.lowercased()), through an approval the "
            + "user sees, with the result read back afterwards."
        if !required.isEmpty {
            advice += " Required fields: \(required.joined(separator: ", "))."
        }
        if !optional.isEmpty {
            advice += " Optional: \(optional.joined(separator: ", "))."
        }
        return advice
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
    /// Calls seen in each live turn, so an identical one is not run again.
    ///
    /// Watched adapterpack.recommend run ten times in a row with the same arguments and the
    /// same reply, then the turn announce "commands completed" having done nothing. Repeating
    /// a call whose answer has not changed cannot make progress — it burns the user's tokens
    /// and their time, and produces a receipt that looks like work.
    ///
    /// Keyed by turn, because this registry is shared and the surfaces are not. As one flat
    /// dictionary it was a conversation-crossing bug in both directions: the dock starting a
    /// turn wiped the window's record mid-loop, and two threads asking the same question in
    /// parallel had the second one's first call refused as a repeat of the first one's.
    private var callsByTurn: [AgentTurnToken: [String: String]] = [:]
    /// Turns in the order they started, so finished ones are evicted without needing every
    /// loop exit path to remember to close its turn.
    private var turnOrder: [AgentTurnToken] = []
    /// Readings taken this turn by a typed verifier, in the order they were taken.
    private var settledByTurn: [AgentTurnToken: [String]] = [:]
    private let maxLiveTurns = 8

    /// Opens a turn. Hand the token to every `AgentToolContext` built for it.
    func beginTurn() -> AgentTurnToken {
        let token = AgentTurnToken()
        callsByTurn[token] = [:]
        settledByTurn[token] = []
        turnOrder.append(token)
        while turnOrder.count > maxLiveTurns {
            let evicted = turnOrder.removeFirst()
            callsByTurn.removeValue(forKey: evicted)
            settledByTurn.removeValue(forKey: evicted)
        }
        return token
    }

    /// Closes a turn. Optional — an abandoned turn is evicted by age — but calling it keeps
    /// the live set to the turns that are actually running.
    func endTurn(_ token: AgentTurnToken) {
        callsByTurn.removeValue(forKey: token)
        settledByTurn.removeValue(forKey: token)
        turnOrder.removeAll { $0 == token }
    }

    /// Whether this call is asking a question a typed read-back has already answered.
    ///
    /// Only `verify_outcome` is superseded. A verified write does not end the turn — the
    /// user may have asked for two things and the second still needs doing — so every
    /// other tool keeps working.
    static func isSupersededVerification(toolName: String, settledReadings: [String]) -> Bool {
        guard !settledReadings.isEmpty else { return false }
        return toolName == "verify_outcome"
    }

    /// What to say instead of running it. The refusal has to hand the reading back: told
    /// only "no", the model has lost its tool and its evidence at once, and reports that it
    /// could not confirm the thing it just confirmed.
    static func supersededVerificationMessage(settledReadings: [String]) -> String {
        "This was already verified by reading the result back:\n"
            + settledReadings.map { "- \($0)" }.joined(separator: "\n")
            + "\n\nThat reading is the evidence. A file check cannot add to it and can only "
            + "disagree with it by looking somewhere else. Report what was observed above."
    }

    /// Stable identity of the operation, excluding model-authored prose that cannot alter it.
    static func callSignature(name: String, arguments: [String: Any]) -> String {
        let signatureArguments = arguments.filter { key, _ in
            !(name == "run_capability" && key == "explanation")
        }
        if JSONSerialization.isValidJSONObject(signatureArguments),
            let data = try? JSONSerialization.data(
                withJSONObject: signatureArguments, options: [.sortedKeys]),
            let encoded = String(data: data, encoding: .utf8)
        {
            return name + "|" + encoded
        }
        return name + "|" + String(describing: signatureArguments)
    }

    /// Reads must be fresh after resume. Writes and screen-driving actions must not be
    /// replayed merely because the provider/session restarted after their side effect landed.
    static func isReplaySensitive(name: String, arguments: [String: Any]) -> Bool {
        switch name {
        case "run_command", "run_menu_command", "run_adapter_action", "window_control":
            return true
        case "run_capability":
            guard let id = arguments["capability_id"] as? String,
                let capability = CapabilityRegistry.shared.capability(id: id)
            else { return false }
            return capability.riskLevel != .low
        default:
            return false
        }
    }

    /// Models occasionally wrap a built-in DoraX capability in the MCP envelope. The two
    /// namespaces look alike in the prompt, but `builtin` is not an MCP server: sending it
    /// to MCPRuntime discards the local Safari/Calendar/etc. context. Normalize that call at
    /// the dispatch boundary so the capability keeps its ordinary scope, approval and
    /// verification behaviour.
    static func bridgedBuiltInCapabilityID(
        toolName: String,
        arguments: [String: Any],
        registeredCapabilityIDs: Set<String>
    ) -> String? {
        guard toolName == "run_mcp_tool" else { return nil }
        let server = (arguments["server"] as? String ?? "").lowercased()
        let app = (arguments["app"] as? String ?? "").lowercased()
        guard server == "builtin" || app == "builtin" else { return nil }
        guard let capabilityID = arguments["tool"] as? String,
            registeredCapabilityIDs.contains(capabilityID)
        else { return nil }
        return capabilityID
    }

    func dispatch(
        name: String,
        arguments: [String: Any],
        context: AgentToolContext
    ) async -> AgentToolResult? {
        if let capabilityID = Self.bridgedBuiltInCapabilityID(
            toolName: name,
            arguments: arguments,
            registeredCapabilityIDs: Set(CapabilityRegistry.shared.all.map(\.id)))
        {
            return await dispatch(
                name: "run_capability",
                arguments: [
                    "capability_id": capabilityID,
                    "input": (arguments["arguments"] as? [String: Any]) ?? [:],
                    "explanation": "Requested through the built-in capability bridge",
                ],
                context: context)
        }
        guard let tool = tool(named: name) else { return nil }

        context.onStatus?(ScopedToolStep.label(for: name))

        if let turn = context.turn,
            Self.isSupersededVerification(
                toolName: name, settledReadings: settledByTurn[turn] ?? [])
        {
            return AgentToolResult(
                success: true,
                output: Self.supersededVerificationMessage(
                    settledReadings: settledByTurn[turn] ?? []),
                displayCommand: "\(name) (already settled by a read-back)")
        }

        // A model may rephrase its explanation after an approval is denied or expires.
        // That prose is not an action input, so it must not turn the same mutation into a
        // fresh call (the reminder test otherwise raised two one-minute approvals).
        let signature = Self.callSignature(name: name, arguments: arguments)
        if let turn = context.turn, let previous = callsByTurn[turn]?[signature] {
            return AgentToolResult(
                success: false,
                output: "Already called \(name) with these exact arguments this turn, and the "
                    + "answer was:\n\(previous)\n\nIt will not change. Use that result, try a "
                    + "different approach, or tell the user what is missing.",
                displayCommand: "\(name) (repeat suppressed)")
        }

        if let budgetMessage = TaskRunStore.shared.reserveToolCall(name) {
            return AgentToolResult(
                success: false, output: budgetMessage,
                displayCommand: "\(name) (tool budget reached)")
        }

        if Self.isReplaySensitive(name: name, arguments: arguments),
            let checkpoint = TaskRunStore.shared.resumedAction(key: signature)
        {
            let output = "Resumed from a durable action checkpoint; this side effect was not "
                + "run twice. Previous result:\n\(checkpoint.output)\n\nPerform a fresh read-only "
                + "verification before reporting completion."
            TaskRunStore.shared.finishToolCall(node: name, success: true, output: output)
            return AgentToolResult(
                success: true, output: output,
                displayCommand: "\(name) (resumed checkpoint)")
        }

        let result = await tool.handler(arguments, context)
        context.onStatus?(
            result.success
                ? ScopedToolStep.completedLabel(for: name)
                : ScopedToolStep.failedLabel(for: name))
        TaskRunStore.shared.finishToolCall(
            node: name, success: result.success, output: result.output)
        if result.success, Self.isReplaySensitive(name: name, arguments: arguments) {
            TaskRunStore.shared.checkpointAction(key: signature, output: result.output)
        }
        if let turn = context.turn, callsByTurn[turn] != nil {
            callsByTurn[turn]?[signature] = String(result.output.prefix(400))
        }
        if let turn = context.turn, let reading = result.verifiedByReadBack,
            settledByTurn[turn] != nil
        {
            settledByTurn[turn]?.append(reading)
        }
        guard result.success, result.verifiedByReadBack == nil, name != "read_tool_result" else {
            return result
        }
        let compacted = AgentToolResultStore.compactForModel(
            result.output, toolName: name)
        guard compacted != result.output else { return result }
        var offloaded = AgentToolResult(
            success: result.success,
            output: compacted,
            displayCommand: result.displayCommand,
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr)
        offloaded.verifiedByReadBack = result.verifiedByReadBack
        return offloaded
    }

    // MARK: - Schemas

    enum SchemaFormat {
        case openAI
        case anthropic
        case gemini
    }

    /// What this turn is about, so the list can be cut to it.
    ///
    /// Set by the surface starting a turn. Without it every tool is offered, which is the
    /// old behaviour and the right default: a caller that has not said what the question
    /// is has given no grounds for leaving anything out.
    private var turnQuery: String = ""
    private var turnProvider: AIProvider?
    private var turnAllowedToolNames: Set<String>?

    /// Told before the turn starts, separately from beginTurn, which the provider loops
    /// own and call themselves.
    ///
    /// Called once, by sendWithTools, rather than by each surface: a budget a caller can
    /// forget to set is a budget that silently stops applying, and the preview did briefly
    /// set its own alongside this one.
    func prepareTurnBudget(
        query: String, provider: AIProvider, allowedToolNames: Set<String>? = nil
    ) {
        turnQuery = query
        turnProvider = provider
        turnAllowedToolNames = allowedToolNames
        AgentToolDiagnostics.record(
            "turn prepared — query=\"\(query.prefix(60))\" provider=\(provider.rawValue) "
            + "allowed=\(allowedToolNames.map { $0.sorted().joined(separator: ",") } ?? "all")")
    }

    /// The tool list as a provider expects to receive it. One source, three renderings —
    /// the differences between providers are pure formatting, and keeping them here stops
    /// the tool sets drifting apart per provider.
    ///
    /// Trimmed to the turn's budget when the surface said what the turn is about. The cut
    /// happens here rather than at each call site so no provider path can forget it.
    func schemas(format: SchemaFormat) -> [[String: Any]] {
        let available = toolsAvailable(for: turnQuery)
        let rendered = renderedSchemas(format: format, tools: available)
        guard let provider = turnProvider else { return logged(rendered) }
        return logged(AIToolBudget.trim(rendered, query: turnQuery, provider: provider))
    }

    /// What the model was actually handed.
    ///
    /// A chat reported it had no run_menu_command while the plan granted it, the filter kept
    /// it and the prompt named it — every check that could be made without a live turn said
    /// the tool was there. This is the one fact none of them can see: the list as sent.
    ///
    /// Written to a file rather than OSLog because this app's Logger output does not reach
    /// the unified log store on this machine — a diagnostic nobody can read is not one.
    private func logged(_ schemas: [[String: Any]]) -> [[String: Any]] {
        let names = schemas.compactMap {
            $0["name"] as? String ?? ($0["function"] as? [String: Any])?["name"] as? String
        }
        AgentToolDiagnostics.record(
            "schemas requested — query=\"\(turnQuery.prefix(60))\" count=\(names.count) "
            + "tools=\(names.sorted().joined(separator: ","))")
        return schemas
    }

    /// Questions get readers, not controls or command catalogues. Tool schemas are an
    /// authority boundary: a model shown a tool treats it as available no matter how many
    /// prompt sentences ask it not to use it.
    func toolNamesAvailable(for query: String) -> Set<String> {
        Set(toolsAvailable(for: query).map(\.name))
    }

    private func toolsAvailable(for query: String) -> [AgentTool] {
        let policyFiltered = turnAllowedToolNames.map { allowed in
            allTools.filter { allowed.contains($0.name) }
        } ?? allTools
        // Agreeing is not asking. "Do it" carries no verb of its own, so it reads as a
        // question and had the action tools stripped from the very turn it approved.
        guard !query.isEmpty, !ChatRouteRecovery.isBareConfirmation(query),
            GeneralAIActionResolver.shared.asksOnly(query)
        else {
            return policyFiltered
        }
        let actionOnly: Set<String> = [
            "run_command", "spawn_worker", "send_keys", "window_control",
            "run_adapter_action", "run_menu_command", "compose_message",
        ]
        return policyFiltered.filter { !actionOnly.contains($0.name) }
    }

    private func renderedSchemas(format: SchemaFormat, tools: [AgentTool]? = nil) -> [[String: Any]] {
        (tools ?? allTools).map { tool in
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

    // MARK: - Scope

    /// Which app a thread is about, for filtering the capability catalogue. Nil means the
    /// conversation is not scoped to one app and the whole catalogue is legitimately in play.
    static func scopedBundleID(for scope: GeneralChatScope?) -> String? {
        switch scope {
        case .app(let bundleId): return bundleId.isEmpty ? nil : bundleId
        // A folder thread is Finder's work aimed at one directory — the file capabilities
        // are registered against Finder, and nothing else belongs there either.
        case .folder: return ChatAppDirectory.finderBundleID
        case .cli, .thread, .general, .none: return nil
        }
    }

    /// Capabilities a scoped chat may see.
    ///
    /// A Code chat was offered mail.recent, messages.recent and photos.recent, because the
    /// tool the model is told to search with read the whole registry while every other layer
    /// — the prompt, the routes, the access policy — was carefully scoped to one app. So the
    /// model spent its rounds calling other apps' capabilities, and the surface that promises
    /// "this conversation is about Code" quietly offered the user's mail.
    ///
    /// Kept: the app's own capabilities, and the ones that belong to no app — git, files,
    /// finder, clipboard, the DoraX surface itself. Those are the machine, not another app,
    /// and a question about a repository in a Code thread is answered with git.log.
    ///
    /// Dropped: everything owned by a different app. Not ranked lower — absent. A model shown
    /// a capability treats it as available, and "available but please do not use it" is an
    /// instruction, not a boundary.
    static func capabilitiesInScope(
        _ capabilities: [AICapability], scopedBundleID: String?,
        alsoAllowed: Set<String> = []
    ) -> [AICapability] {
        guard let scopedBundleID, !scopedBundleID.isEmpty else { return capabilities }
        // The thread's own app, plus any the user has explicitly allowed into this
        // conversation. Without the second half, "save this page to my notes" in a Safari
        // thread could never reach notes.append however clearly the user asked for it — and
        // the request fell through to driving Notes' menu bar instead, which is the same
        // app reached by a worse road and without being asked.
        var allowed = Set(alsoAllowed.map { $0.lowercased() })
        allowed.insert(scopedBundleID.lowercased())
        return capabilities.filter { capability in
            guard let owner = capability.appBundleID, !owner.isEmpty else { return true }
            return allowed.contains(owner.lowercased())
        }
    }

    /// What to say when the model asks for a capability belonging to another app. Naming the
    /// app and the way out is the difference between a refusal the user can act on and one
    /// that reads as a malfunction.
    static func outOfScopeMessage(
        capabilityID: String, owner: String, scopedBundleID: String
    ) -> String {
        let ownerName = InstalledApplicationsCatalog.cachedInstalledApps()
            .first { $0.bundleId.caseInsensitiveCompare(owner) == .orderedSame }?.name ?? owner
        let scopeName = InstalledApplicationsCatalog.cachedInstalledApps()
            .first { $0.bundleId.caseInsensitiveCompare(scopedBundleID) == .orderedSame }?.name
            ?? scopedBundleID
        return "\(capabilityID) belongs to \(ownerName), and this conversation is scoped to "
            + "\(scopeName). Answer from \(scopeName) instead, or tell the user to ask in a "
            + "\(ownerName) chat — do not look for another way to reach \(ownerName)."
    }

    // MARK: - Search aliases

    /// Extra words that should match a capability whose id and title do not contain them.
    ///
    /// This is search vocabulary, not routing: it only widens what `find_capability` will
    /// surface, and the model still decides whether any result fits. Without it, "paste what
    /// I copied" matched nothing, because no word in the phrase appears in "clipboard.read /
    /// Read Clipboard" — the model would have had to guess the word DoraX happens to use.
    /// Capability ids that match `query`, best first.
    ///
    /// Extracted from the find_capability tool so the ranking can be tested without a
    /// provider, a registry or a running app. Every alias change this session was verified
    /// by hand in a throwaway script; the same phrasings now live in the test suite, where
    /// a change that breaks one is caught rather than noticed later in a screenshot.
    static func rankedCapabilityIDs(
        query: String, catalogue: [(id: String, title: String)]
    ) -> [String] {
        // Three characters minimum, matching the tool: two-letter words are almost never
        // the subject and substring-match inside real words.
        let terms = query.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 && !Self.stopwords.contains($0) }
        guard !terms.isEmpty else { return [] }
        // Written as statements rather than a map/filter/sorted chain: the chain, with a
        // labelled tuple and three closures, exceeds the type-checker's budget outright.
        //
        // Flat scoring, deliberately. Weighting id and title above aliases was tried and
        // traded one failure for another — it fixed "capture the screen" and broke "what
        // did I capture from Code", because "capture" as a verb and as a noun are the same
        // substring. No weighting resolves that, so the tests assert only what this layer
        // can promise, which is that the right capability is offered; which one is meant is
        // left to the model reading the titles, and to the on-device fallback when nothing
        // matches at all.
        var scored: [(score: Int, rank: Int, id: String)] = []
        for (index, entry) in catalogue.enumerated() {
            let aliases: String = searchAliases(for: entry.id)
            let haystack: String = "\(entry.id) \(entry.title) \(aliases)".lowercased()
            var score = 0
            for term in terms where haystack.contains(term) {
                score += 1
            }
            if score > 0 {
                scored.append((score: score, rank: index, id: entry.id))
            }
        }
        // Ties broken by registration order, which makes the result the same every run —
        // Swift's sort is not stable, so equal scores previously came back however the sort
        // left them, and the same question could rank differently twice.
        //
        // Registration order rather than alphabetical. Alphabetical is equally
        // deterministic and consistently wrong: it put bookmarks above history, the
        // clipboard's history above its current contents, and — worst — memory.save above
        // memory.search, so "what do you remember about me" led with a capability that
        // writes. Registration order is the author's own precedence, and reads are
        // registered before the writes beside them.
        scored.sort { left, right in
            left.score == right.score ? left.rank < right.rank : left.score > right.score
        }
        return scored.map(\.id)
    }

    /// Words that carry no subject. Aliases are written as readable phrases, so "what is
    /// copied" put "what" into the haystack and every question starting with it scored a
    /// point — "what is the weather" matched the clipboard, the screenshot and the region
    /// capture. Filtering the query rather than rewriting every phrase fixes the aliases
    /// nobody has written yet as well as the ones here now.
    /// Split across several arrays rather than written as one literal: a single set literal
    /// this long defeats the type-checker ("unable to type-check this expression in
    /// reasonable time"), which is a compile error rather than a style opinion.
    private static let stopwords: Set<String> = {
        let determiners = ["the", "and", "for", "any", "all", "some", "this", "that", "these", "those"]
        let questions = ["what", "which", "who", "whom", "whose", "how", "why", "when", "where"]
        let modals = ["can", "could", "would", "should", "will", "shall", "may", "might", "must"]
        let auxiliaries = ["are", "was", "were", "have", "has", "had", "did", "does", "get", "got"]
        let pronouns = ["you", "your", "yours", "our", "its", "them", "they", "his", "her", "him", "she", "hers"]
        let prepositions = ["there", "here", "into", "onto", "from", "with", "about", "than", "then"]
        let adverbs = ["not", "but", "out", "off", "over", "under", "again", "just", "only", "very", "too", "now", "please"]
        return Set(
            determiners + questions + modals + auxiliaries + pronouns + prepositions + adverbs)
    }()

    private static func searchAliases(for capabilityID: String) -> String {
        // Whole-id aliases first. Families are too coarse when one mixes reading with
        // doing: "system" covers both listing running apps and taking a screenshot, and
        // giving the screenshot capability the family's "apps applications" made "what did
        // I capture from Code?" rank *taking a new screenshot* above reading the captures
        // already taken. A request to read something must not be answered by doing it.
        switch capabilityID {
        // "Summarise quarterly-notes.md" found no file tool at all. The scorer matches
        // words against ids and titles, and finder.readFile's title says "Read a file's
        // contents" — nothing a person asking for a summary would type. So the query
        // scored zero against it and one against every Apple Notes capability, because the
        // FILENAME contained "notes". The model looped on read_attachment and gave up.
        case "finder.readFile":
            return "read open summarise summarize explain describe contents what does say "
                + "inside text pdf document markdown md txt docx file"
        case "finder.grepFiles":
            return "search find inside contents mentions containing text within files "
                + "which file says look for"
        case "finder.fileInfo":
            return "how big size kind when modified created details about this file"
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
        case "browser.currentPage":
            return "current active open frontmost exact title domain summary summarize "
                + "content page website site url tab"
        case "app.menu.click":
            return "menu minimize maximize zoom hide quit close window save open new "
                + "preferences settings command item click run app"
        case "app.insertText":
            return "insert paste type write put text into markdown convert replace "
                + "editor document frontmost app"
        case "clipboard.history":
            // No "took"/"taken": both contain "take", so "take a screenshot" — an
            // instruction to capture — scored here as highly as on the capability that
            // actually captures, and won the tie. "captures" and "screenshots" already
            // carry the past sense without colliding with the imperative.
            return "history earlier previous past clips captures captured capturing "
                + "screenshots screenshot ocr snippets source app apps saved list recent"
        default: break
        }

        switch capabilityID.split(separator: ".").first.map(String.init) ?? "" {
        // Both clipboard capabilities are matched by whole id above; this covers any that
        // are added later without their own entry.
        // These two are families, not ids. Written in the whole-id switch above they never
        // matched anything, because no capability is called "cli" or "memory" — so "what do
        // you remember about me" scored zero against memory.search, the exact silent miss
        // this table exists to prevent.
        case "cli": return "tool tools command line terminal binary linked utility run"
        case "memory":
            return "remember remembered recall know knows told saved fact facts note "
                + "preference preferences people projects tasks forget"
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

        // Registered first, and deliberately so: reading is what the model should reach for
        // before it reaches for anything that acts. See ReadingTools.swift.
        registerReadingTools()
        // The deterministic resolver, offered rather than applied. See RouteTools.swift.
        registerRouteTools()

        register(AgentTool(
            name: "read_tool_result",
            description: "Read one bounded chunk of a large tool result that DoraX offloaded. "
                + "Use only with a result_id returned by another tool in this turn.",
            properties: [
                "result_id": [
                    "type": "string",
                    "description": "Opaque result_id returned by an offloaded tool result",
                ],
                "offset": [
                    "type": "integer",
                    "description": "Character offset to start at (default 0)",
                ],
                "limit": [
                    "type": "integer",
                    "description": "Maximum characters to return (default 3000, maximum 6000)",
                ],
            ],
            required: ["result_id"]
        ) { arguments, _ in
            guard let id = arguments["result_id"] as? String else {
                return AgentToolResult(
                    success: false,
                    output: "read_tool_result requires result_id.",
                    displayCommand: "read_tool_result(invalid)")
            }
            let offset = arguments["offset"] as? Int ?? 0
            let limit = arguments["limit"] as? Int ?? 3_000
            switch AgentToolResultStore.read(id: id, offset: offset, limit: limit) {
            case .success(let chunk):
                return AgentToolResult(
                    success: true, output: chunk,
                    displayCommand: "read_tool_result(\(id), offset: \(offset))")
            case .failure(let error):
                return AgentToolResult(
                    success: false, output: error.localizedDescription,
                    displayCommand: "read_tool_result(\(id), offset: \(offset))")
            }
        })

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
            // An unfilled placeholder is not a command. `graft --dir <your_project_directory>`
            // ran verbatim, zsh choked on the angle brackets, and the answer said the
            // visualisation was rendering. The prompt already says never to invent
            // placeholders; this refuses the ones that get written anyway, because a
            // command containing <…> cannot do what it claims and its failure reads like a
            // shell quirk rather than a missing value.
            if let placeholder = command.range(
                of: #"<[A-Za-z_][A-Za-z0-9_ ]*>"#, options: .regularExpression)
            {
                return AgentToolResult(
                    success: false,
                    output: "That command still contains the placeholder "
                        + "`\(command[placeholder])` — it was never filled in, so it cannot "
                        + "run. Work out the real value first (the thread's folder, the "
                        + "current project, the file the user named) and send the command "
                        + "with it, or ask the user which one they mean. Do not run it with "
                        + "the placeholder text.",
                    displayCommand: "run_command(\(command))")
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
            // A missing binary is not a wrong invocation, and the difference matters.
            // "code --theme light" failed with "command not found: code", and the model
            // read that as bad syntax and tried "--set-theme" — a flag that does not exist
            // either, against a binary that was never there. Two failed commands and an
            // answer telling the user to do it by hand. Say which of the two it was, and
            // that retrying cannot help.
            let missingBinary = output.contains("command not found")
                || output.contains("No such file or directory")
            if !success, missingBinary {
                let name = command.split(separator: " ").first.map(String.init) ?? command
                return AgentToolResult(
                    success: false,
                    output: "`\(name)` is not installed on this Mac, or is not on the PATH "
                        + "DoraX runs commands with — the command never ran, so nothing is "
                        + "wrong with how it was written. Do NOT retry with different flags. "
                        + "Use find_capability to see whether an app action, menu command or "
                        + "capability can do this instead, and if none can, tell the user "
                        + "plainly that \(name) is missing.",
                    displayCommand: "run_command(\(command))",
                    exitCode: exitCode)
            }
            // Exit zero means the command ran, not that it worked. `defaults write
            // AppleInterfaceStyle` returns nothing and exits zero whether or not the
            // desktop changed, and the model — seeing only an exit code — reported the
            // change as done. Where the effect can be read back, it is, and the reading
            // travels with the output; where it cannot, the result says so, because the
            // model cannot tell an unverifiable command from a verified one.
            let verification = await MainActor.run {
                CommandOutcomeVerifier.verify(command: command)
            }
            let verified: String
            switch verification?.status {
            case .verified:
                verified = "\n\nVerified: \(verification?.message ?? "")"
            case .contradicted:
                verified = "\n\nIt did not take effect: \(verification?.message ?? "")"
            case .unverified:
                verified = "\n\nCouldn't confirm it: \(verification?.message ?? "")"
            case .notApplicable, nil:
                verified = "\n\n(Not verified: this command's effect cannot be read back. "
                    + "Say what you ran, not that it worked.)"
            }
            return AgentToolResult(
                success: success && (verification?.status.claimsSuccess ?? true),
                output: output + verified,
                displayCommand: "run_command(\(command))",
                exitCode: exitCode)
        })

        register(AgentTool(
            name: "verify_outcome",
            description: "Read back filesystem state after an action. Every criterion starts "
                + "failing; call this after work that creates, removes, or changes a file and "
                + "before claiming completion. Use only when the requested outcome concerns a "
                + "real absolute file path supplied by the user or returned by a tool. Never "
                + "invent placeholder paths and never use it to verify URLs, opened apps, Global "
                + "Commands, menus, or other non-filesystem outcomes. This tool is read-only and "
                + "cannot run commands. Report what was observed about the file, never that "
                + "a verification was run — \"the outcome verification is successful\" tells "
                + "the user about DoraX's plumbing instead of about their file.",
            properties: [
                "kind": [
                    "type": "string",
                    "enum": [
                        "file_exists", "file_does_not_exist", "file_contains", "file_equals",
                    ],
                    "description": "The exact read-only verification to perform",
                ],
                "path": [
                    "type": "string",
                    "description": "Path to verify. Absolute, or relative to the folder this "
                        + "conversation is scoped to — the same folder commands run in.",
                ],
                "expected_text": [
                    "type": "string",
                    "description": "Required only for file_contains",
                ],
            ],
            required: ["kind", "path"]
        ) { arguments, context in
            // Commands run in the thread's folder, so the model answers with the paths it
            // used — "Images/IMG_4151.heic". Demanding an absolute path failed a
            // verification of work that had actually succeeded, and reported it as though
            // the model had invented the path. Relative paths resolve against the same
            // folder the command ran in; only a placeholder is refused now.
            guard let kind = arguments["kind"] as? String,
                  let rawPath = arguments["path"] as? String,
                  !rawPath.trimmingCharacters(in: .whitespaces).isEmpty,
                  !rawPath.lowercased().hasPrefix("/path/to/"),
                  !rawPath.lowercased().hasPrefix("path/to/")
            else {
                return AgentToolResult(
                    success: false,
                    output: "Verification requires a supported kind and a real path; "
                        + "placeholder paths are not evidence.",
                    displayCommand: "verify_outcome(invalid)")
            }

            let expanded = NSString(string: rawPath).expandingTildeInPath
            let absolute: String
            if expanded.hasPrefix("/") {
                absolute = expanded
            } else if let root = context.chatScope?.folderURL {
                absolute = root.appendingPathComponent(expanded).path
            } else {
                return AgentToolResult(
                    success: false,
                    output: "Verification needs an absolute path here: this conversation is "
                        + "not scoped to a folder, so \(rawPath) could be anywhere.",
                    displayCommand: "verify_outcome(invalid)")
            }
            let path = NSString(string: absolute).standardizingPath
            let fileManager = FileManager.default
            let passed: Bool
            let observation: String
            switch kind {
            case "file_exists":
                if let installed = installedAppSummary(at: path) {
                    passed = true
                    observation = installed
                } else {
                    passed = fileManager.fileExists(atPath: path)
                    observation = passed
                        ? "File exists at \(path)."
                        : "No file exists at \(path)."
                }
            case "file_does_not_exist":
                if let installed = installedAppSummary(at: path) {
                    passed = false
                    observation = installed
                } else {
                    passed = !fileManager.fileExists(atPath: path)
                    observation = passed
                        ? "No file exists at \(path)."
                        : "A file still exists at \(path)."
                }
            case "file_contains":
                guard let expected = arguments["expected_text"] as? String else {
                    return AgentToolResult(
                        success: false,
                        output: "file_contains requires expected_text.",
                        displayCommand: "verify_outcome(file_contains, \(path))")
                }
                if let unreadable = Self.unreadableAsText(path) {
                    return AgentToolResult(
                        success: false, output: unreadable,
                        displayCommand: "verify_outcome(file_contains, \(path))")
                }
                let contents = try? String(contentsOfFile: path, encoding: .utf8)
                passed = contents?.contains(expected) == true
                observation = passed
                    ? "File at \(path) contains the expected text."
                    : "File at \(path) does not contain the expected text."
            case "file_equals":
                guard let expected = arguments["expected_text"] as? String else {
                    return AgentToolResult(
                        success: false,
                        output: "file_equals requires expected_text.",
                        displayCommand: "verify_outcome(file_equals, \(path))")
                }
                if let unreadable = Self.unreadableAsText(path) {
                    return AgentToolResult(
                        success: false, output: unreadable,
                        displayCommand: "verify_outcome(file_equals, \(path))")
                }
                let contents = try? String(contentsOfFile: path, encoding: .utf8)
                passed = contents == expected
                observation = passed
                    ? "File at \(path) exactly matches the expected text."
                    : "File at \(path) does not exactly match the expected text."
            default:
                return AgentToolResult(
                    success: false,
                    output: "Unsupported verification kind: \(kind).",
                    displayCommand: "verify_outcome(\(kind), \(path))")
            }

            return AgentToolResult(
                success: passed,
                output: observation,
                displayCommand: "verify_outcome(\(kind), \(path))")
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
                + "and \\u{1B}[A/B/C/D for arrow keys. This types into a terminal and nothing "
                + "else: it cannot drive a Mac app, press ⌘-anything, copy from Safari or paste "
                + "into an editor. For an app's commands use run_menu_command.",
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
            // ⌘ means nothing to a program reading a pseudo-terminal — there are no
            // modifier keys down there, only bytes. Asked to copy a link out of Safari and
            // paste it into VS Code, the model sent ⌘L, ⌘C and ⌘V here, got three successes
            // back, and told the user it had done it. The literal characters went into a
            // terminal, no app was touched, and the receipt said Action ✓ three times.
            if keys.contains(where: { "⌘⌥⌃⇧".contains($0) }) {
                return AgentToolResult(
                    success: false,
                    output: "send_keys types into the terminal panel, where ⌘ and the other "
                        + "modifiers do not exist — nothing was sent. This tool cannot drive "
                        + "a Mac app. Use run_menu_command for an app's own commands, and say "
                        + "plainly if what was asked needs an app you cannot reach.",
                    displayCommand: "send_keys(\(keys)) — not a terminal key")
            }
            let output = await TerminalCommandExecutor.shared.sendKeys(keys)
            // A TUI needs a moment to react before the next call lands.
            try? await Task.sleep(nanoseconds: 300_000_000)
            // Reported as it happened. Success was unconditional, so "No active terminal —
            // launch the TUI first" arrived as a green tick, and a turn built on three of
            // those reads as three completed actions.
            let reached = !output.hasPrefix("No active terminal")
            return AgentToolResult(
                success: reached, output: output, displayCommand: "send_keys(\(keys))")
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
                // "These files" usually means the Finder selection, not an upload. Ending
                // the turn on "nothing is attached" left the model with a flat no while the
                // files the user was pointing at sat one tool call away — so this says what
                // *is* there and which tool reaches it.
                if case .filesSelected(let selected) = context.userContext, !selected.isEmpty {
                    let names = selected.prefix(10).map(\.path).joined(separator: "\n")
                    return AgentToolResult(
                        success: false,
                        output: "Nothing is attached to this message, but the user has "
                            + "\(selected.count) item(s) selected in Finder:\n\(names)\n\n"
                            + "That is what \"these files\" means. Any image among them has "
                            + "already been shown to you — describe it directly. For anything "
                            + "else use finder.readFile or finder.fileInfo on the paths above.",
                        displayCommand: "read_attachment()")
                }
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
        ) { arguments, context in
            let query = (arguments["query"] as? String ?? "").lowercased()
            // Three characters minimum. Two-letter words are almost never the subject and
            // they substring-match inside real words — "in" hits "Window" and
            // "instructions", so "what repo am i in" ranked window.arrange above git.log.
            let terms = query
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count > 2 }
            // "notes.md" is a filename, not a request about Apple Notes. Detected on the
            // raw query because tokenising splits the extension off the stem, losing the
            // one signal that says which of the two this is.
            let namesAFile = query.range(
                of: "[\\w-]+\\.(md|txt|pdf|docx?|rtf|csv|json|ya?ml|html?|pages|key|numbers|xlsx?|pptx?)\\b",
                options: [.regularExpression, .caseInsensitive]) != nil
            // The thread's app. Everything below is filtered to it: this tool was the one
            // door in the scoped chat that still opened onto the whole machine.
            let scopedBundleID = await MainActor.run {
                Self.scopedBundleID(for: context.chatScope)
            }
            let granted = Set(context.grantedApps.values)
            let matches = await MainActor.run { () -> [AICapability] in
                let all = Self.capabilitiesInScope(
                    CapabilityRegistry.shared.all, scopedBundleID: scopedBundleID,
                    alsoAllowed: granted)
                guard !terms.isEmpty else { return [] }
                let scored = all
                    .map { capability -> (score: Int, capability: AICapability) in
                        let haystack = (capability.id + " " + capability.title
                            + " " + Self.searchAliases(for: capability.id)).lowercased()
                        var score = terms.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
                        // A question naming a file is a question about files. Without this
                        // "summarise quarterly-notes.md" ranked Apple Notes above every
                        // file tool, on the strength of the word inside the filename.
                        if namesAFile, capability.id.hasPrefix("finder.") { score += 2 }
                        return (score, capability)
                    }
                    .filter { $0.score > 0 }
                    .sorted { $0.score > $1.score }
                guard let highest = scored.first?.score else { return [] }
                // A multi-term hit is specific enough to suppress one-word coincidences.
                // "installed VS Code extensions" should return the VS Code inventory, not
                // Xcode, System Settings, and every action whose title contains "Code".
                let narrowed = highest >= 2 ? scored.filter { $0.score == highest } : scored
                return Array(narrowed.prefix(12).map(\.capability))
            }
            // App adapter actions are DoraX routes too, and the scope prompt lists them —
            // but they were invisible to the tool the model is told to search with, so it
            // guessed ids from the prompt and got a failure back.
            let adapterMatches = await MainActor.run { () -> [(String, String, String)] in
                guard !terms.isEmpty else { return [] }
                var out: [(score: Int, line: (String, String, String))] = []
                let adapters = AppAdapterManager.shared.adapters.filter { adapter in
                    guard adapter.isEnabled else { return false }
                    // Another app's actions are another app's business, whatever they are
                    // called: "ai.draft-commit-summary-email" is a Code action and belongs
                    // here, Mail's compose action does not.
                    guard let scopedBundleID else { return true }
                    return adapter.bundleId.caseInsensitiveCompare(scopedBundleID) == .orderedSame
                }
                for adapter in adapters {
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

            // Word search found nothing. Before telling the model this Mac cannot do the
            // thing — the answer that produced "you have no browsing history" — let the
            // on-device model read the request against what exists. Only here, only when
            // the deterministic path has already failed.
            var fallbackMatches: [AICapability] = []
            if matches.isEmpty, adapterLines.isEmpty {
                let all = await MainActor.run {
                    Self.capabilitiesInScope(
                        CapabilityRegistry.shared.all, scopedBundleID: scopedBundleID,
                        alsoAllowed: granted)
                }
                let picked = await CapabilityFallbackClassifier.pick(
                    query: query, from: all.map { (id: $0.id, title: $0.title) })
                let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
                fallbackMatches = picked.compactMap { byID[$0] }
            }

            guard !matches.isEmpty || !adapterLines.isEmpty || !fallbackMatches.isEmpty else {
                return AgentToolResult(
                    success: true,
                    output: "No capability matched \"\(query)\". Registered capability families: "
                        + (await MainActor.run {
                            Set(
                                Self.capabilitiesInScope(
                                    CapabilityRegistry.shared.all,
                                    scopedBundleID: scopedBundleID
                                ).compactMap {
                                    $0.id.split(separator: ".").first.map(String.init)
                                }
                            ).sorted().joined(separator: ", ")
                        })
                        + ". Try one of those words, or use run_command for anything shell-based.",
                    displayCommand: "find_capability(\(query))")
            }
            let lines = (matches + fallbackMatches).map { capability -> String in
                let fields = capability.inputSchema.fields
                    .map { "\($0.name)\($0.required ? "" : "?")" }
                    .joined(separator: ", ")
                return "- \(capability.id): \(capability.title) | input: [\(fields)]"
                    + " | risk: \(capability.riskLevel.rawValue)"
            }
            return AgentToolResult(
                success: true,
                // The closing rule matters more than the list. Handed these ids, a model
                // asked for something none of them covered invented a capability, then a
                // log path under the app's Application Support, and reported that the file
                // was missing — turning "I can't read that" into a plausible-sounding
                // investigation of a file that never existed.
                output: "Matching capabilities — call one with run_capability:\n"
                    + (lines + adapterLines).joined(separator: "\n")
                    + "\n\nThese are the only capabilities for this request. If none of them "
                    + "can answer it, say so plainly and stop. Do not invent a capability id, "
                    + "and do not guess at file paths, log locations or support directories to "
                    + "read instead — a guessed path is not a source.",
                displayCommand: "find_capability(\(query))")
        })

        // Clicking a menu item is the one capability an app always has, and the loop had no
        // way to ask for it. For an app whose only integration *is* its menu bar that left
        // nothing legal to call — so the model recommended building an adapter pack, ten
        // times in a row, and then reported "commands completed" having done nothing.
        // Window controls are properties of a window, not commands in a menu. Asked to
        // minimise VS Code, the loop had only run_menu_command — whose cache holds no Window
        // menu for that app — and a shell, where the usual AppleScript fails on Electron.
        register(AgentTool(
            name: "window_control",
            description: "Minimise, restore, zoom or close an app's front window. Works on "
                + "every app, including ones with no cached Window menu. Prefer this over a "
                + "menu command or a shell script for these four operations.",
            properties: [
                "app": ["type": "string", "description": "The app's name."],
                "command": [
                    "type": "string",
                    "description": "minimize, restore, zoom or close.",
                ],
            ],
            required: ["app", "command"]
        ) { arguments, _ in
            let appName = (arguments["app"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = (arguments["command"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let command = WindowControlTool.Command(rawValue: raw) else {
                return AgentToolResult(
                    success: false,
                    output: "window_control takes one of: "
                        + WindowControlTool.Command.allCases.map(\.rawValue)
                            .joined(separator: ", ") + ".",
                    displayCommand: "window_control(\(raw))")
            }
            let target = await MainActor.run {
                GeneralAIActionResolver.shared.installedAppMatch(named: appName)
            }
            guard let target else {
                return AgentToolResult(
                    success: false,
                    output: "No installed app called \"\(appName)\".",
                    displayCommand: "window_control(\(appName): \(raw))")
            }
            let outcome = await WindowControlTool.run(
                command, bundleId: target.bundleId, appName: target.name)
            return AgentToolResult(
                success: outcome.success,
                output: outcome.message,
                displayCommand: "window_control(\(target.name): \(raw))")
        })

        // The two routes a scoped chat was told to ask for in prose, because they had no
        // tool of their own.
        //
        // The prompt taught {"adapter_call":…} and {"mcp_call":…} as JSON lines to write into
        // an answer, which meant the model was running two protocols at once: real tool calls
        // for run_command and run_menu_command, and hand-written JSON for these. It mixed
        // them — writing a tool call as prose, or a prose call into a tool argument — and a
        // recovery layer grew to catch what fell between. These make every route in the scope
        // prompt reachable the same way, so there is one protocol to confuse with nothing.
        register(AgentTool(
            name: "run_adapter_action",
            description: "Run one of the scoped app's installed adapter actions — the ids "
                + "listed under Actions in this conversation's app inventory. Prefer this "
                + "over a menu command or a shell script when an action matches: it is the "
                + "app's own route, and destructive ones show their own approval card.",
            properties: [
                "action_id": [
                    "type": "string",
                    "description": "The action id exactly as listed in the app inventory.",
                ],
                "reason": [
                    "type": "string",
                    "description": "One line on why, shown to the user with the action.",
                ],
            ],
            required: ["action_id"]
        ) { arguments, context in
            let actionID = (arguments["action_id"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !actionID.isEmpty else {
                return AgentToolResult(
                    success: false,
                    output: "run_adapter_action needs 'action_id'.",
                    displayCommand: "run_adapter_action")
            }
            let scopedBundleID = Self.scopedBundleID(for: context.chatScope)
            let adapter = AppAdapterManager.shared.adapters.first { candidate in
                guard candidate.actions.contains(where: { $0.id == actionID }) else {
                    return false
                }
                guard let scopedBundleID else { return true }
                return candidate.bundleId.caseInsensitiveCompare(scopedBundleID) == .orderedSame
            }
            guard let adapter, let action = adapter.actions.first(where: { $0.id == actionID })
            else {
                return AgentToolResult(
                    success: false,
                    output: "No adapter action '\(actionID)' is available in this conversation. "
                        + "Use one of the ids listed in the app inventory, or say the app does "
                        + "not offer it.",
                    displayCommand: "run_adapter_action(\(actionID))")
            }
            guard AppAccessPolicy.allows(
                .adapter, at: AppAccessPolicy.level(for: adapter.bundleId))
            else {
                return AgentToolResult(
                    success: false,
                    output: "\(adapter.appName) has not granted action control.",
                    displayCommand: "run_adapter_action(\(actionID))")
            }
            let (ok, output) = await AppAdapterManager.shared.execute(
                action,
                context: AXContextReader.shared.current,
                targetBundleId: adapter.bundleId,
                query: arguments["reason"] as? String ?? "Requested in chat")
            return AgentToolResult(
                success: ok,
                output: output.isEmpty
                    ? (ok ? "Done — \(action.name)." : "Couldn't run \(action.name).")
                    : output,
                displayCommand: "run_adapter_action(\(action.name))")
        })

        register(AgentTool(
            name: "run_mcp_tool",
            description: "Call one of the scoped app's linked MCP tools to READ its data — "
                + "notes, events, reminders, issues. Reads only: a tool that writes is "
                + "refused here and must go through a capability with its own approval.",
            properties: [
                "server": [
                    "type": "string",
                    "description": "Server name as listed in this conversation's MCP section.",
                ],
                "tool": ["type": "string", "description": "The tool name on that server."],
                "arguments": [
                    "type": "object",
                    "description": "Arguments for the tool. Pass {} when it takes none.",
                ],
            ],
            required: ["server", "tool"]
        ) { arguments, context in
            let server = (arguments["server"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let tool = (arguments["tool"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tool.isEmpty else {
                return AgentToolResult(
                    success: false,
                    output: "run_mcp_tool needs 'server' and 'tool'.",
                    displayCommand: "run_mcp_tool")
            }
            guard let bundleID = Self.scopedBundleID(for: context.chatScope) else {
                return AgentToolResult(
                    success: false,
                    output: "This conversation is not scoped to an app, so it has no linked "
                        + "MCP servers. Use find_capability instead.",
                    displayCommand: "run_mcp_tool(\(tool))")
            }
            guard AppAccessPolicy.allows(.mcp, at: AppAccessPolicy.level(for: bundleID)) else {
                return AgentToolResult(
                    success: false,
                    output: "This app has no App Adapter, so its data tools are not available.",
                    displayCommand: "run_mcp_tool(\(tool))")
            }
            // A provider-authored write is not something the user agreed to by linking a
            // server. Mutations go through a deterministic capability with an approval card.
            guard MCPToolSafety.isClearlyReadOnly(name: tool) else {
                return AgentToolResult(
                    success: false,
                    output: "MCP tool \(tool) is write or unknown risk. Use find_capability to "
                        + "find a capability that does this with the user's approval.",
                    displayCommand: "run_mcp_tool(\(tool))")
            }
            let toolArguments = (arguments["arguments"] as? [String: Any]) ?? [:]
            do {
                let output = try await MCPRuntime.shared.callProviderReadOnlyTool(
                    bundleId: bundleID, server: server, tool: tool, arguments: toolArguments)
                return AgentToolResult(
                    success: true, output: output,
                    displayCommand: "\(tool) via \(server.isEmpty ? "MCP" : server)")
            } catch {
                return AgentToolResult(
                    success: false,
                    output: "MCP tool \(tool) failed: \(error.localizedDescription)",
                    displayCommand: "\(tool) via \(server.isEmpty ? "MCP" : server)")
            }
        })

        register(AgentTool(
            name: "run_menu_command",
            description: "Click a menu command in a Mac app — app: \"Disk Utility\", path: "
                + "\"Disk Utility > About Disk Utility\". Use for apps whose menus DoraX has "
                + "cached but which have no adapter. The path must match a real cached menu "
                + "item — it is checked against the cache and live-verified in the app before "
                + "clicking, and a path that does not exist is refused. Before a screen-driving "
                + "command runs, DoraX shows the user a plan for launching/activating the app, "
                + "clicking the exact item, and verifying the result.",
            properties: [
                "app": ["type": "string", "description": "The app's name."],
                "path": [
                    "type": "string",
                    "description": "Menu path, e.g. \"View > Show Sidebar\", or just the "
                        + "item's title.",
                ],
            ],
            required: ["app", "path"]
        ) { arguments, _ in
                let appName = (arguments["app"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Accepts the array form as well as the string. The description used to
                // show the path as ["Disk Utility", "About Disk Utility"], so the model sent
                // an array, the string cast returned nil, and the tool answered that it
                // needed a path it had just been given — then the model went off and ran
                // `open -b` instead. A tool that only accepts one shape of an argument it
                // documents in another shape is a trap of its own making.
                let rawPath: String
                if let text = arguments["path"] as? String {
                    rawPath = text.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if let parts = arguments["path"] as? [String] {
                    rawPath = parts.joined(separator: " > ")
                } else {
                    rawPath = ""
                }
                guard !appName.isEmpty, !rawPath.isEmpty else {
                    return AgentToolResult(
                        success: false,
                        output: "run_menu_command needs 'app' and 'path'.",
                        displayCommand: "run_menu_command")
                }
                let path = rawPath
                    .components(separatedBy: CharacterSet(charactersIn: ">›→"))
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }

                // A window operation is done directly, not by clicking a menu. VS Code has
                // no cached "Window ▸ Minimize", so asking to minimise it failed and the
                // model offered to close the window instead — while the app has minimised
                // windows natively all along.
                let windowOutcome: AgentToolResult? = await MainActor.run {
                    guard let command = WindowManagementService.shared.command(forMenuPath: path),
                        let app = runningApplication(named: appName)
                    else { return nil }
                    let ok = WindowManagementService.shared.execute(command, sourceApp: app)
                    let name = app.localizedName ?? appName
                    return AgentToolResult(
                        success: ok,
                        output: ok
                            ? "\(command.title) applied to \(name)."
                            : "Could not \(command.title.lowercased()) \(name) — it may have "
                                + "no window open.",
                        displayCommand: "window(\(name): \(command.title))")
                }
                if let windowOutcome { return windowOutcome }

                let lookup = await MainActor.run {
                    GeneralAIActionResolver.shared.menuCommandCandidate(
                        appName: appName, path: path)
                }
                let candidate: DoraXActionCandidate
                switch lookup {
                case .ready(let found):
                    candidate = found
                case .disabled(let found, let resolvedName):
                    return AgentToolResult(
                        success: false,
                        output: "\(resolvedName) has \"\(found)\", but it is greyed out right "
                            + "now — the app will not accept it in its current state. Say that "
                            + "plainly; do not click something else instead.",
                        displayCommand: "run_menu_command(\(appName): \(rawPath))")
                case .missing(let resolvedName, let nearest):
                    let alternatives = nearest.isEmpty
                        ? ""
                        : " Closest cached commands: " + nearest.joined(separator: ", ") + "."
                    return AgentToolResult(
                        success: false,
                        output: "No cached menu item \"\(rawPath)\" in \(resolvedName)."
                            + alternatives
                            + " Ask for one of those, or say the app does not offer it — do "
                            + "not guess another path.",
                        displayCommand: "run_menu_command(\(appName): \(rawPath))")
                }
                // Authority is asked here as everywhere else: menus are permitted at
                // menu-only, private state is not.
                let allowed = await MainActor.run {
                    AppAccessPolicy.allows(
                        .verifiedMenu,
                        at: AppAccessPolicy.level(for: candidate.bundleID ?? ""))
                }
                guard allowed else {
                    return AgentToolResult(
                        success: false,
                        output: "\(appName) has not granted menu control.",
                        displayCommand: "run_menu_command(\(appName))")
                }
                let outcome = await GeneralAIActionExecutor.shared.execute(
                    candidate, approval: .ask)
                guard outcome.success else {
                    return AgentToolResult(
                        success: false,
                        output: outcome.message,
                        displayCommand: "run_menu_command(\(appName): \(rawPath))")
                }
                // Read back what the click did to the app's windows, and hand the model the
                // reading rather than the click. Told only that a click was sent, it went
                // looking for its own evidence, checked a guessed path, and announced the
                // app was not installed while its About window stood open on screen.
                let verification = await GeneralAIActionExecutor.shared.verify(candidate)
                var output = outcome.message
                // The reading, when there is one. Both verified and contradicted are typed
                // read-backs — one saw it land, the other saw it not land — and both settle
                // the question for the rest of the turn. Asking "do not look for further
                // evidence" did not stop the model looking; recording the reading does.
                var reading: String?
                switch verification {
                case .verified(let observed):
                    reading = observed ?? "The outcome was observed."
                    output += " " + (reading ?? "")
                        + " This is the result — do not look for further evidence."
                case .contradicted(let evidence):
                    // Proof it did not land. The model must not treat this as "unclear" and
                    // go hunting for a second opinion — the reading is the second opinion.
                    reading = "It did not take effect: " + evidence
                    output += " " + (reading ?? "")
                        + " This is the result — do not look for further evidence."
                case .unverified(let reason):
                    output += " " + reason
                case .notApplicable:
                    output += " Nothing observable changed in \(appName)'s windows, which is "
                        + "normal for a command of this kind. Report what was clicked, not "
                        + "whether it worked."
                }
                var menuResult = AgentToolResult(
                    success: true,
                    output: output,
                    displayCommand: "run_menu_command(\(appName): \(rawPath))")
                menuResult.verifiedByReadBack = reading
                return menuResult
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

            // The thread's boundary, enforced where it is crossed rather than only where it
            // is listed. find_capability no longer offers another app's capabilities, but a
            // model that saw one in an earlier turn — or guessed the id — must not be able
            // to reach it by asking directly.
            let scopedBundleID = Self.scopedBundleID(for: context.chatScope)
            let allowedElsewhere = Set(context.grantedApps.values.map { $0.lowercased() })
            if let scopedBundleID,
                let owner = CapabilityRegistry.shared.capability(id: capabilityID)?.appBundleID,
                !owner.isEmpty,
                owner.caseInsensitiveCompare(scopedBundleID) != .orderedSame,
                !allowedElsewhere.contains(owner.lowercased())
            {
                return AgentToolResult(
                    success: false,
                    output: Self.outOfScopeMessage(
                        capabilityID: capabilityID, owner: owner,
                        scopedBundleID: scopedBundleID),
                    displayCommand: "run_capability(\(capabilityID)) — out of scope")
            }

            // An id that is not a registered capability is usually an app adapter's action
            // id: the scope prompt lists those for `adapter_call`, and a model asked to
            // "run this" reaches for the tool named run_capability. Both are DoraX routes
            // to the same action, so run it rather than reporting a failure the user can
            // do nothing about.
            if CapabilityRegistry.shared.capability(id: capabilityID) == nil,
                let adapter = AppAdapterManager.shared.adapters.first(where: { candidate in
                    guard candidate.actions.contains(where: { $0.id == capabilityID })
                    else { return false }
                    guard let scopedBundleID else { return true }
                    return candidate.bundleId.caseInsensitiveCompare(scopedBundleID)
                        == .orderedSame
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

            // A question is not a licence to write. Authority and risk were both checked
            // here and intent never was, so "what's in my trash bin" reached the Empty Trash
            // capability: allowed, high risk, approved on a card, and the wrong action.
            // Emptying the trash does answer "is it empty" — afterwards, and permanently.
            if isWrite, !context.userRequest.isEmpty,
                GeneralAIActionResolver.shared.asksOnly(context.userRequest)
            {
                return AgentToolResult(
                    success: false,
                    output: "Refused: the user asked a question and \(capabilityID) changes "
                        + "state. Answer from what you can read, or say you have no way to "
                        + "read it. Do not run this to find out.",
                    displayCommand: "run_capability(\(capabilityID)) refused")
            }

            if isWrite, RecentCapabilityWrites.alreadyRan(capabilityID, input: input) {
                return AgentToolResult(
                    success: true,
                    output: "Already done a moment ago with exactly these inputs — not "
                        + "repeated. Continue; do not call this again.",
                    displayCommand: "run_capability(\(capabilityID))")
            }

            // Keys the schema does not declare are not passed through in silence.
            //
            // Asked to remind at 5pm the model called reminders.create with `date`, and the
            // field is `dueDate`. The unknown key was dropped, the reminder was created with
            // no due date, and every check afterwards told the truth about a different
            // thing: the read-back found it by title and verified, reminders.today found
            // nothing due today, and the answer to the user was that the reminder had not
            // been created. It had. It simply had no date, because nothing objected.
            if let capability,
                let complaint = Self.undeclaredInputComplaint(
                    capabilityID: capabilityID, capability: capability, input: input)
            {
                return AgentToolResult(
                    success: false, output: complaint,
                    displayCommand: "run_capability(\(capabilityID)) rejected")
            }

            let plan = AIActionPlan(
                capability: capabilityID, input: input, explanation: explanation)
            do {
                let result = try await AIExecutionEngine.shared.executeWithApproval(
                    plan, context: context.userContext, chatScope: context.chatScope,
                    userRequest: context.userRequest)
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
                var reading: String?
                if result.success {
                    switch await GeneralAIActionExecutor.shared.verifyCapability(
                        id: capabilityID, inputValues: input)
                    {
                    case .verified(let refined):
                        // The menu path learned this and this one did not: a model told only
                        // that something succeeded goes looking for its own proof. Here it
                        // created the reminder, EventKit confirmed it, and the model then
                        // grepped ~/Library/Reminders for the title, found nothing, and told
                        // the user the reminder had not been created.
                        reading = refined ?? output
                        output = (refined ?? output)
                            + " Verified by reading it back. This is the result — do not "
                            + "look for further evidence."
                    case .contradicted(let evidence):
                        // Read back and disproved. Distinct from the case below because the
                        // model can act on it: there is nothing to re-check, only to redo.
                        succeeded = false
                        reading = "It did not take effect: \(evidence)"
                        output = "\(output)\n\nIt did not take effect: \(evidence)"
                    case .unverified(let fallback):
                        // The command ran and the result could not be found. Saying so is
                        // the whole point; reporting success here is how a chat claims to
                        // have created something that is not there.
                        succeeded = false
                        output = "\(output)\n\nCouldn't confirm it: \(fallback)"
                    case .notApplicable:
                        break
                    }
                }
                var capabilityResult = AgentToolResult(
                    success: succeeded,
                    output: output,
                    displayCommand: "run_capability(\(capabilityID))")
                capabilityResult.verifiedByReadBack = reading
                return capabilityResult
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
            guard let rows = MessagesChatDBReader.recent(
                limit: limit, contact: contactFilter)
            else {
                return AgentToolResult(
                    success: false,
                    output: "Messages could not be read. Grant Context-Dock Full Disk Access in System Settings > Privacy & Security > Full Disk Access. No UI was opened.",
                    displayCommand: "get_messages_conversations")
            }
            let output = rows.isEmpty
                ? "No recent Messages conversations matched the request."
                : MessagesChatDBReader.formatted(rows)
            return AgentToolResult(
                success: true, output: output, displayCommand: "get_messages_conversations")
        })

        register(AgentTool(
            name: "search_messages",
            description: "Search local Messages read-only for a contact, keyword, or phrase. "
                + "Does not open or control the Messages app.",
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
            guard let rows = MessagesChatDBReader.search(query) else {
                return AgentToolResult(
                    success: false,
                    output: "Messages could not be read. Grant Context-Dock Full Disk Access in System Settings > Privacy & Security > Full Disk Access. No UI was opened.",
                    displayCommand: "search_messages(\(query))")
            }
            let output = rows.isEmpty
                ? "No Messages matched \(query)."
                : MessagesChatDBReader.formatted(rows)
            return AgentToolResult(
                success: true,
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


/// Where an app named by a guessed path actually lives, if it is installed at all.
///
/// Asked to confirm it had opened Journal's About window, the model checked
/// /Applications/Journal.app, found nothing, and told the user Journal was not installed —
/// with the About window open on screen in front of them. Journal ships in
/// /System/Applications, and no amount of care in the model fixes a check that answers a
/// different question than the one it was asked. The question is whether the app is
/// installed; the answer is not "is it in the one directory guessed for it".
///
/// Returns nil for anything that is not an app bundle, so ordinary file checks are
/// untouched — this only intervenes where the path names a `.app`.
private func installedAppSummary(at path: String) -> String? {
    guard path.hasSuffix(".app") else { return nil }
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: path) { return nil }

    let name = (path as NSString).lastPathComponent
    guard !name.isEmpty else { return nil }
    let directories = [
        "/Applications", "/System/Applications", "/System/Applications/Utilities",
        "/Applications/Utilities", NSHomeDirectory() + "/Applications",
    ]
    for directory in directories {
        let candidate = directory + "/" + name
        guard candidate != path, fileManager.fileExists(atPath: candidate) else { continue }
        return "\(name) is installed — at \(candidate), not \(path)."
    }
    // Running is proof of installed, wherever it lives.
    let stem = name.replacingOccurrences(of: ".app", with: "")
    if let running = NSRunningApplication.runningApplications(withBundleIdentifier: stem).first
        ?? NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName ?? "").caseInsensitiveCompare(stem) == .orderedSame
        }), let url = running.bundleURL {
        return "\(name) is installed and running — at \(url.path), not \(path)."
    }
    return nil
}
