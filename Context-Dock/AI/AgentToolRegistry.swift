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

    /// The thread this turn belongs to. Carries the folder a capability may not reach
    /// outside of, and where a report it produces should be filed. Without it, every
    /// capability called through the tool loop ran unscoped — the boundary the folder
    /// threads promise existed only on the prose-recovery path.
    var chatScope: GeneralChatScope? = nil

    init(
        commandExecutor: @escaping (String, String, Bool) async -> (Bool, String, Int32),
        userContext: UserContext = .none,
        attachments: [URL] = [],
        chatScope: GeneralChatScope? = nil
    ) {
        self.commandExecutor = commandExecutor
        self.userContext = userContext
        self.attachments = attachments
        self.chatScope = chatScope
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

        switch verb {
        case "mkdir":
            return "Use run_capability with finder.newFolder for folders in the user's own "
                + "folders — it previews the destination for approval and confirms the "
                + "folder afterwards. Fields: destination (absolute parent path), name."
        case "rm", "rmdir", "unlink":
            return "Use run_capability with finder.trash instead of rm for the user's own "
                + "files — it is recoverable from the Trash and confirms the file is gone. "
                + "Field: path."
        case "mv":
            // The case that failed in the wild: mkdir was refused, the model did not read
            // the refusal, and two chained mv commands ran at folders that did not exist.
            return "Use run_capability with finder.moveFiles to move the user's files — it "
                + "acts on the selection or a named path, asks first, and reads the result "
                + "back. Field: destination (absolute folder path). To tidy a whole folder "
                + "into subfolders by kind or by month, use finder.organize instead: it "
                + "creates the folders and moves everything in one approved step, so there "
                + "is no half-done state when one command fails."
        case "cp", "ditto":
            return "Use run_capability with finder.copyFiles to copy the user's files — it "
                + "asks first and confirms afterwards. Field: destination (absolute folder "
                + "path)."
        case "touch":
            return "Creating empty files in the user's folders is not something the shell "
                + "is allowed to do here. If the intent is a folder, use finder.newFolder."
        default:
            return nil
        }
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
            let verified = verification.map { "\n\n\($0)" }
                ?? "\n\n(Not verified: this command's effect cannot be read back. Say what "
                    + "you ran, not that it worked.)"
            return AgentToolResult(
                success: success && !(verification?.hasPrefix("NOT applied") ?? false),
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
                + "cannot run commands.",
            properties: [
                "kind": [
                    "type": "string",
                    "enum": [
                        "file_exists", "file_does_not_exist", "file_contains", "file_equals",
                    ],
                    "description": "The exact read-only verification to perform",
                ],
                "path": ["type": "string", "description": "Absolute path to verify"],
                "expected_text": [
                    "type": "string",
                    "description": "Required only for file_contains",
                ],
            ],
            required: ["kind", "path"]
        ) { arguments, _ in
            guard let kind = arguments["kind"] as? String,
                  let rawPath = arguments["path"] as? String,
                  rawPath.hasPrefix("/"),
                  !rawPath.lowercased().hasPrefix("/path/to/")
            else {
                return AgentToolResult(
                    success: false,
                    output: "Verification requires a supported kind and a real absolute path; placeholder paths are not evidence.",
                    displayCommand: "verify_outcome(invalid)")
            }

            let path = NSString(string: rawPath).standardizingPath
            let fileManager = FileManager.default
            let passed: Bool
            let observation: String
            switch kind {
            case "file_exists":
                passed = fileManager.fileExists(atPath: path)
                observation = passed ? "File exists at \(path)." : "No file exists at \(path)."
            case "file_does_not_exist":
                passed = !fileManager.fileExists(atPath: path)
                observation = passed ? "No file exists at \(path)." : "A file still exists at \(path)."
            case "file_contains":
                guard let expected = arguments["expected_text"] as? String else {
                    return AgentToolResult(
                        success: false,
                        output: "file_contains requires expected_text.",
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
        ) { arguments, _ in
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
            let matches = await MainActor.run { () -> [AICapability] in
                let all = CapabilityRegistry.shared.all
                guard !terms.isEmpty else { return [] }
                return all
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

            // Word search found nothing. Before telling the model this Mac cannot do the
            // thing — the answer that produced "you have no browsing history" — let the
            // on-device model read the request against what exists. Only here, only when
            // the deterministic path has already failed.
            var fallbackMatches: [AICapability] = []
            if matches.isEmpty, adapterLines.isEmpty {
                let all = await MainActor.run { CapabilityRegistry.shared.all }
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
                            Set(CapabilityRegistry.shared.all.compactMap {
                                $0.id.split(separator: ".").first.map(String.init)
                            }).sorted().joined(separator: ", ")
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
                    plan, context: context.userContext, chatScope: context.chatScope)
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
