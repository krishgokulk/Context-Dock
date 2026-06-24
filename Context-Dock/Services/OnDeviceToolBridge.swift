// OnDeviceToolBridge.swift
// Context-Dock
//
// Exposes AppAdapter actions as FoundationModels `Tool` conforming types so
// on-device Apple Intelligence can execute them directly during generation.
//
// Architecture:
//   AdapterActionTool  — wraps a single AdapterAction (menubar, script, URL, shortcut)
//   ShellCommandTool   — lets the model run arbitrary shell commands with AX context
//   ListAdaptersTool   — lets the model discover what actions are available for an app
//   OnDeviceToolSession — builds a LanguageModelSession with the right tools attached
//                         and runs a multi-turn tool loop, returning the final text.

#if canImport(FoundationModels)
import FoundationModels
import AppKit
import Foundation
import Vision
import CoreGraphics
import ScreenCaptureKit
import Contacts

// MARK: - AdapterActionTool

/// Wraps one AdapterAction as a FoundationModels Tool.
/// The model can call it by the action's id, and receives the execution output.
@available(macOS 26.0, *)
struct AdapterActionTool: Tool {

    let name: String
    let description: String

    // The underlying action + the bundle ID it belongs to
    private let action: AdapterAction
    private let bundleId: String
    private let axContext: AXContext

    init(action: AdapterAction, bundleId: String, axContext: AXContext) {
        // Tool names must be identifier-safe (alphanumeric + underscore)
        self.name = action.id
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        self.description = action.description.isEmpty ? action.name : action.description
        self.action = action
        self.bundleId = bundleId
        self.axContext = axContext
    }

    // No parameters — adapter actions are fully self-contained.
    // The model decides WHICH action to call; the action knows what to do.
    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        let (success, output) = await AppAdapterManager.shared.execute(
            action,
            context: axContext,
            targetBundleId: bundleId,
            query: ""
        )
        return success
            ? (output.isEmpty ? "✅ \(action.name) completed." : output)
            : "❌ \(action.name) failed: \(output)"
    }
}

// MARK: - ShellCommandTool

/// Lets the model run a shell command and receive stdout back.
/// Gated behind the same approval flow used for cloud AI tool calls.
@available(macOS 26.0, *)
struct ShellCommandTool: Tool {
    let name = "run_shell_command"
    let description = "Run a shell command on the user's Mac with the normal approval flow and return the output. Use for file operations, searching, git commands, and CLI tools."

    init(axContext: AXContext) {}

    @Generable
    struct Arguments {
        @Guide(description: "The bash command to run. Keep it safe and non-destructive unless the user explicitly asked.")
        var command: String
    }

    func call(arguments: Arguments) async throws -> String {
        let command = arguments.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return "❌ No shell command provided." }

        let (success, output) = await TerminalAIBridge.shared.processAICommand(
            command,
            purpose: "On-device AI shell command"
        )
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if success {
            return trimmedOutput.isEmpty ? "✅ Command completed." : trimmedOutput
        }
        return trimmedOutput.isEmpty ? "❌ Command failed." : "❌ \(trimmedOutput)"
    }
}

@available(macOS 26.0, *)
struct SpawnWorkerTool: Tool {
    let name = "spawn_worker"
    let description = "Launch a long-running or interactive terminal command in the current live terminal and return a worker ID immediately."

    @Generable
    struct Arguments {
        @Guide(description: "The command to launch.")
        var command: String

        @Guide(description: "Short purpose text describing why the command is being launched.")
        var purpose: String

        init() {
            self.command = ""
            self.purpose = "On-device AI worker"
        }
    }

    func call(arguments: Arguments) async throws -> String {
        let command = arguments.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return "❌ No worker command provided." }

        let purpose = arguments.purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        let workerID = await TerminalAIBridge.shared.spawnWorker(
            command: command,
            purpose: purpose.isEmpty ? "On-device AI worker" : purpose
        )
        return "✅ Worker started: \(workerID)"
    }
}

@available(macOS 26.0, *)
struct SendKeysTool: Tool {
    let name = "send_keys"
    let description = "Send raw keystrokes to the active live terminal session after spawn_worker launches a TUI app."

    @Generable
    struct Arguments {
        @Guide(description: "Keys to send. Supports plain text, \\r for Enter, \\u{1B} for Esc, \\u{03} for Ctrl-C, and ANSI arrow sequences.")
        var keys: String

        init() {
            self.keys = ""
        }
    }

    func call(arguments: Arguments) async throws -> String {
        let keys = arguments.keys
        guard !keys.isEmpty else { return "❌ No keys provided." }
        return await TerminalAIBridge.shared.sendKeys(keys)
    }
}

// MARK: - ListAdaptersTool

/// Lets the model discover what adapter actions are available for the current app.
@available(macOS 26.0, *)
struct ListAdaptersTool: Tool {
    let name = "list_available_actions"
    let description = "List all actions available for the current frontmost app. Call this if you're unsure what you can do."

    private let bundleId: String

    init(bundleId: String) { self.bundleId = bundleId }

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        let actions = await MainActor.run {
            AppAdapterManager.shared.actions(for: bundleId)
        }
        if actions.isEmpty {
            return "No adapter actions registered for this app. Use run_shell_command for custom operations."
        }
        let list = actions.map { "• \($0.id): \($0.name) — \($0.description)" }.joined(separator: "\n")
        return "Available actions:\n\(list)"
    }
}

// MARK: - Universal App Menu Tools

@available(macOS 26.0, *)
struct ListAppMenuActionsTool: Tool {
    let name = "list_app_menu_actions"
    let description = "List executable menu commands for the current scoped app. Use this before executing an app menu action if you are unsure of the exact path."

    private let bundleId: String
    private let appName: String
    private let processIdentifier: pid_t

    init(bundleId: String, appName: String, processIdentifier: pid_t) {
        self.bundleId = bundleId
        self.appName = appName
        self.processIdentifier = processIdentifier
    }

    @Generable
    struct Arguments {
        @Guide(description: "Optional filter text to narrow relevant menu actions, for example archive, reply, search, bookmarks, or export.")
        var query: String

        init() {
            self.query = ""
        }
    }

    private func rankedMenuItems(_ items: [AXMenuItem], query: String, maxResults: Int) -> [AXMenuItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let executableItems = items.filter { item in
            item.children.isEmpty && !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        guard !trimmedQuery.isEmpty else {
            return Array(
                executableItems.sorted {
                    if $0.isEnabled != $1.isEnabled { return $0.isEnabled && !$1.isEnabled }
                    if $0.path.count != $1.path.count { return $0.path.count < $1.path.count }
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                .prefix(maxResults)
            )
        }

        let matches = executableItems.filter { item in
            item.title.lowercased().contains(trimmedQuery)
                || item.path.contains { $0.lowercased().contains(trimmedQuery) }
        }

        return Array(
            matches.sorted {
                if $0.isEnabled != $1.isEnabled { return $0.isEnabled && !$1.isEnabled }
                let aPrefix = $0.title.lowercased().hasPrefix(trimmedQuery) ? 0 : 1
                let bPrefix = $1.title.lowercased().hasPrefix(trimmedQuery) ? 0 : 1
                if aPrefix != bPrefix { return aPrefix < bPrefix }
                if $0.path.count != $1.path.count { return $0.path.count < $1.path.count }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            .prefix(maxResults)
        )
    }

    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            if let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == bundleId && !$0.isTerminated
            }) {
                let liveItems = AXMenuReader.shared.refreshAllMenuItems(for: app.processIdentifier, maxDepth: 6)
                if !liveItems.isEmpty {
                    AppMenuCapabilityCache.shared.store(items: liveItems, for: app)
                    let rankedItems = rankedMenuItems(
                        liveItems,
                        query: arguments.query,
                        maxResults: 24
                    )
                    if !rankedItems.isEmpty {
                        let lines = rankedItems.map { item in
                            let shortcut = item.shortcutDisplay.map { " [\($0)]" } ?? ""
                            let availability = item.isEnabled ? "" : " (disabled)"
                            return "- \(item.path.joined(separator: " > "))\(shortcut)\(availability)"
                        }
                        return "\(appName) actions:\n" + lines.joined(separator: "\n")
                    }
                }
            }

            let items = AppMenuCapabilityCache.shared.menuItems(
                bundleIdentifier: bundleId,
                appName: appName,
                processIdentifier: processIdentifier,
                query: arguments.query,
                maxResults: 24
            )

            guard !items.isEmpty else { return "No executable menu actions found for \(appName)." }

            let lines = items.map { item in
                let shortcut = item.shortcutDisplay.map { " [\($0)]" } ?? ""
                let availability = item.isEnabled ? "" : " (disabled)"
                return "- \(item.path.joined(separator: " > "))\(shortcut)\(availability)"
            }
            return "\(appName) actions:\n" + lines.joined(separator: "\n")
        }
    }
}

@available(macOS 26.0, *)
private func normalizedMenuTokenText(_ text: String) -> String {
    text
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        .lowercased()
        .replacingOccurrences(of: "…", with: "")
        .replacingOccurrences(of: "...", with: "")
        .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

@available(macOS 26.0, *)
private func normalizedMenuPath(_ path: [String]) -> [String] {
    path.map(normalizedMenuTokenText)
}

@available(macOS 26.0, *)
private func menuIntentTokens(_ text: String) -> Set<String> {
    let stopWords: Set<String> = [
        "a", "an", "and", "app", "application", "do", "for", "in", "it", "me", "my",
        "of", "on", "please", "that", "the", "this", "to", "with"
    ]
    let aliases: [String: [String]] = [
        "bin": ["trash"],
        "delete": ["remove", "trash"],
        "find": ["search"],
        "fullscreen": ["full", "screen"],
        "minimise": ["minimize", "miniaturize"],
        "new": ["create", "add"],
        "prefs": ["preferences", "settings"],
        "preference": ["settings"],
        "preferences": ["settings"],
        "quit": ["exit"],
        "remove": ["delete"],
        "search": ["find"],
        "settings": ["preferences"],
        "trash": ["bin", "delete"]
    ]
    var tokens = Set(
        normalizedMenuTokenText(text)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count > 1 && !stopWords.contains($0) }
    )
    for token in Array(tokens) {
        for alias in aliases[token, default: []] {
            tokens.insert(alias)
        }
    }
    return tokens
}

@available(macOS 26.0, *)
private func menuCandidates(
    bundleId: String,
    appName: String,
    processIdentifier: pid_t,
    query: String,
    maxResults: Int = 80
) -> [AXMenuItem] {
    let runningApp = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == bundleId && !$0.isTerminated
    })
    if let runningApp {
        let live = AXMenuReader.shared.cachedAllMenuItems(
            for: runningApp.processIdentifier,
            maxDepth: 6
        )
        if !live.isEmpty {
            AppMenuCapabilityCache.shared.store(items: live, for: runningApp)
        }
    }

    let cached = AppMenuCapabilityCache.shared.menuItems(
        bundleIdentifier: bundleId,
        appName: appName,
        processIdentifier: processIdentifier,
        query: query,
        maxResults: maxResults
    )

    let live = runningApp.map {
        AXMenuReader.shared.cachedAllMenuItems(for: $0.processIdentifier, maxDepth: 6)
    } ?? []

    var seen = Set<String>()
    return (cached + live).filter { item in
        guard item.children.isEmpty,
              !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        let key = normalizedMenuPath(item.path).joined(separator: ">")
        return seen.insert(key).inserted
    }
}

@available(macOS 26.0, *)
private func bestMenuMatch(
    intent: String,
    bundleId: String,
    appName: String,
    processIdentifier: pid_t
) -> AXMenuItem? {
    let intentTokens = menuIntentTokens(intent)
    guard !intentTokens.isEmpty else { return nil }
    let normalizedIntent = normalizedMenuTokenText(intent)

    let candidates = menuCandidates(
        bundleId: bundleId,
        appName: appName,
        processIdentifier: processIdentifier,
        query: normalizedIntent,
        maxResults: 120
    )

    let scored = candidates.compactMap { item -> (AXMenuItem, Double)? in
        let title = normalizedMenuTokenText(item.title)
        let pathText = normalizedMenuTokenText(item.path.joined(separator: " "))
        let pathTokens = menuIntentTokens(pathText)
        let overlap = intentTokens.intersection(pathTokens).count
        guard overlap > 0 || title.contains(normalizedIntent) || normalizedIntent.contains(title)
        else { return nil }

        var score = Double(overlap) * 12
        if title == normalizedIntent { score += 80 }
        if title.hasPrefix(normalizedIntent) || normalizedIntent.hasPrefix(title) { score += 32 }
        if title.contains(normalizedIntent) || normalizedIntent.contains(title) { score += 22 }
        if item.isEnabled { score += 8 } else { score -= 20 }
        score -= Double(max(0, item.path.count - 2)) * 1.5
        return (item, score)
    }
    .sorted {
        if $0.1 != $1.1 { return $0.1 > $1.1 }
        if $0.0.isEnabled != $1.0.isEnabled { return $0.0.isEnabled && !$1.0.isEnabled }
        return $0.0.path.count < $1.0.path.count
    }

    guard let best = scored.first, best.1 >= 12 else { return nil }
    return best.0
}

@available(macOS 26.0, *)
private func menuSuggestions(
    intent: String,
    bundleId: String,
    appName: String,
    processIdentifier: pid_t
) -> [String] {
    let tokens = menuIntentTokens(intent)
    return menuCandidates(
        bundleId: bundleId,
        appName: appName,
        processIdentifier: processIdentifier,
        query: intent,
        maxResults: 40
    )
    .map { item -> (String, Int) in
        let count = tokens.intersection(menuIntentTokens(item.path.joined(separator: " "))).count
        let availability = item.isEnabled ? "" : " (disabled)"
        return ("- \(item.path.joined(separator: " > "))\(availability)", count)
    }
    .filter { $0.1 > 0 }
    .sorted { $0.1 > $1.1 }
    .prefix(5)
    .map(\.0)
}

@available(macOS 26.0, *)
struct ExecuteAppMenuPathTool: Tool {
    let name = "execute_app_menu_path"
    let description = "Execute an exact menu path from the current scoped app's known menu catalog. Only call this with a path returned by list_app_menu_actions or execute_app_menu_intent."

    private let bundleId: String
    private let appName: String

    init(bundleId: String, appName: String) {
        self.bundleId = bundleId
        self.appName = appName
    }

    @Generable
    struct Arguments {
        @Guide(description: "Exact menu path components in order, for example [\"Message\", \"Archive\"] or [\"Edit\", \"Find\", \"Mailbox Search\"].")
        var path: [String]
    }

    func call(arguments: Arguments) async throws -> String {
        let trimmedPath = arguments.path
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmedPath.isEmpty else { return "❌ No app menu path provided." }

        guard let targetApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleId && !$0.isTerminated
        }) else {
            return "❌ \(appName) is not running."
        }

        let validation = await MainActor.run { () -> AXMenuItem? in
            AppMenuCapabilityCache.shared.menuItems(
                bundleIdentifier: bundleId,
                appName: appName,
                processIdentifier: targetApp.processIdentifier,
                query: trimmedPath.last ?? "",
                maxResults: 60
            )
            .first { normalizedMenuPath($0.path) == normalizedMenuPath(trimmedPath) }
        }

        guard let validation else {
            return "❌ \(appName) doesn't currently expose that menu path: \(trimmedPath.joined(separator: " > "))."
        }

        guard validation.isEnabled else {
            return "⚠️ \(appName) menu is currently disabled: \(trimmedPath.joined(separator: " > ")). Change the app state and try again."
        }

        await MainActor.run {
            AXActionResolver.shared.execute(menuPath: trimmedPath, in: targetApp)
        }
        return "✅ Requested \(appName) menu: \(trimmedPath.joined(separator: " > "))"
    }
}

@available(macOS 26.0, *)
struct ExecuteAppMenuIntentTool: Tool {
    let name = "execute_app_menu_intent"
    let description = "Map a natural-language app command to the best matching menu path in the current scoped app, then execute it through the unified AX action resolver. Use this for app UI requests like export, find, archive, format, sort, view, window, tab, or settings commands."

    private let bundleId: String
    private let appName: String
    private let processIdentifier: pid_t

    init(bundleId: String, appName: String, processIdentifier: pid_t) {
        self.bundleId = bundleId
        self.appName = appName
        self.processIdentifier = processIdentifier
    }

    @Generable
    struct Arguments {
        @Guide(description: "The user's natural language intent, for example \"export as pdf\", \"open recent project\", \"show downloads\", or \"new reminder list\".")
        var intent: String

        init() {
            self.intent = ""
        }
    }

    func call(arguments: Arguments) async throws -> String {
        let intent = arguments.intent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !intent.isEmpty else { return "❌ No app menu intent provided." }

        guard let targetApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleId && !$0.isTerminated
        }) else {
            return "❌ \(appName) is not running."
        }

        let match = await MainActor.run {
            bestMenuMatch(
                intent: intent,
                bundleId: bundleId,
                appName: appName,
                processIdentifier: processIdentifier != 0 ? processIdentifier : targetApp.processIdentifier
            )
        }

        guard let match else {
            let suggestions = await MainActor.run {
                menuSuggestions(
                    intent: intent,
                    bundleId: bundleId,
                    appName: appName,
                    processIdentifier: targetApp.processIdentifier
                )
            }
            if suggestions.isEmpty {
                return "❌ I couldn't map \"\(intent)\" to an available \(appName) menu action."
            }
            return "❌ I couldn't confidently execute \"\(intent)\". Closest \(appName) menu actions:\n" + suggestions.joined(separator: "\n")
        }

        guard match.isEnabled else {
            return "⚠️ \(appName) menu is currently disabled: \(match.path.joined(separator: " > "))."
        }

        await MainActor.run {
            AXActionResolver.shared.execute(menuPath: match.path, in: targetApp)
        }
        return "✅ Mapped \"\(intent)\" to \(appName) menu: \(match.path.joined(separator: " > "))"
    }
}

// MARK: - Mail Tools

@available(macOS 26.0, *)
struct SearchMailTool: Tool {
    let name = "search_mail"
    let description = "Open Mail's native Mailbox Search UI and search for a query. Supports token kinds: generic, sender, subject, attachment, date."

    @Generable
    struct Arguments {
        @Guide(description: "The text to search for in Mail.")
        var query: String

        @Guide(description: "Optional token kind: generic, sender, subject, attachment, date.")
        var tokenKind: String

        init() {
            self.query = ""
            self.tokenKind = "generic"
        }
    }

    func call(arguments: Arguments) async throws -> String {
        let tokenKind = MailAutomationSearchTokenKind(rawValue: arguments.tokenKind.lowercased()) ?? .generic
        return await MailAutomation.openMailboxSearch(query: arguments.query, tokenKind: tokenKind)
    }
}

@available(macOS 26.0, *)
struct GetMailMailboxSnapshotTool: Tool {
    let name = "get_mail_mailbox_snapshot"
    let description = "Read a recent snapshot of the currently selected mailbox in Mail. Supports sender, subject, unread, and today/yesterday filters."

    @Generable
    struct Arguments {
        @Guide(description: "Optional sender filter substring.")
        var senderContains: String

        @Guide(description: "Optional subject filter substring.")
        var subjectContains: String

        @Guide(description: "Whether to limit results to unread messages.")
        var unreadOnly: Bool

        @Guide(description: "Optional relative day filter: today, yesterday, or empty.")
        var relativeDay: String

        @Guide(description: "Maximum number of matching messages to return.")
        var limit: Int

        init() {
            self.senderContains = ""
            self.subjectContains = ""
            self.unreadOnly = false
            self.relativeDay = ""
            self.limit = 20
        }
    }

    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            MailAutomation.mailboxSnapshot(
                senderContains: arguments.senderContains,
                subjectContains: arguments.subjectContains,
                unreadOnly: arguments.unreadOnly,
                relativeDay: arguments.relativeDay,
                limit: arguments.limit
            )
        }
    }
}

@available(macOS 26.0, *)
struct ResolveMetadataTool: Tool {
    let name = "resolve_metadata"
    let description = "Resolve a fuzzy person, organization, sender, or event reference into metadata from Contacts, Mail, or Calendar. Use this when the user mentions a name but not the exact email address, phone number, or event details."

    @Generable
    struct Arguments {
        @Guide(description: "The fuzzy reference to resolve, for example Uber, John, or design review.")
        var query: String

        @Guide(description: "Optional source domain: auto, contacts, mail, or calendar.")
        var domain: String

        @Guide(description: "Maximum number of matches to return.")
        var maxResults: Int

        init() {
            self.query = ""
            self.domain = "auto"
            self.maxResults = 5
        }
    }

    func call(arguments: Arguments) async throws -> String {
        await MetadataResolver.resolveJSONString(
            query: arguments.query,
            domain: arguments.domain,
            maxResults: arguments.maxResults
        )
    }
}

// MARK: - Messages Tools

@available(macOS 26.0, *)
struct SearchMessagesTool: Tool {
    let name = "search_messages"
    let description = "Open Messages and search for a contact, keyword, or phrase using the search UI."

    @Generable
    struct Arguments {
        @Guide(description: "The text, contact name, or keyword to search for in Messages.")
        var query: String

        init() { self.query = "" }
    }

    func call(arguments: Arguments) async throws -> String {
        await MessagesAutomation.openSearch(query: arguments.query)
    }
}

@available(macOS 26.0, *)
struct GetMessagesConversationSnapshotTool: Tool {
    let name = "get_messages_conversations"
    let description = "List recent Messages conversations. Optionally filter by contact name or handle."

    @Generable
    struct Arguments {
        @Guide(description: "Optional contact name or phone/email filter substring.")
        var contactFilter: String

        @Guide(description: "Maximum number of conversations to return.")
        var limit: Int

        init() {
            self.contactFilter = ""
            self.limit = 15
        }
    }

    func call(arguments: Arguments) async throws -> String {
        MessagesAutomation.conversationSnapshot(
            contactFilter: arguments.contactFilter,
            limit: arguments.limit
        )
    }
}

@available(macOS 26.0, *)
struct ComposeMessageTool: Tool {
    let name = "compose_message"
    let description = "Open a Messages compose window for a recipient. Does NOT send automatically — the user reviews and sends."

    @Generable
    struct Arguments {
        @Guide(description: "Recipient phone number, email address, or contact name.")
        var recipient: String

        @Guide(description: "Optional draft message body to pre-fill.")
        var body: String

        init() {
            self.recipient = ""
            self.body = ""
        }
    }

    func call(arguments: Arguments) async throws -> String {
        await MessagesAutomation.composeMessage(to: arguments.recipient, body: arguments.body)
    }
}

// MARK: - CLIAdapterTool

/// Wraps a CLI tool adapter action as a parameterized Tool.
/// Unlike AdapterActionTool (which has no parameters), this lets the model
/// supply subcommands and flags so it can actually query the CLI and get output.
@available(macOS 26.0, *)
struct CLIAdapterTool: Tool {
    let name: String
    let description: String
    private let cliCommand: String

    init(action: AdapterAction) {
        let raw = (action.cliToolCommand ?? action.name)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedCmd = raw.isEmpty ? action.name : raw
        self.cliCommand = resolvedCmd
        let safeName = resolvedCmd
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ".", with: "_")
        self.name = "run_\(safeName)"
        let base = action.description.isEmpty ? action.name : action.description
        var desc = "Run `\(resolvedCmd)` CLI tool. \(base). Pass any subcommands, flags, or arguments."
        if let pkg = TerminalPackageManager.shared.packages.first(where: {
            $0.command.caseInsensitiveCompare(resolvedCmd) == .orderedSame
        }), let help = pkg.helpTextForPrompt {
            desc += "\n\nUsage reference:\n\(String(help.prefix(600)))"
        }
        self.description = desc
    }

    @Generable
    struct Arguments {
        @Guide(description: "Subcommand and flags to pass, e.g. 'status', 'list --json', 'up --exit-node=xxx'. Leave empty to run the bare command.")
        var args: String

        init() { self.args = "" }
    }

    func call(arguments: Arguments) async throws -> String {
        let args = arguments.args.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullCommand = args.isEmpty ? cliCommand : "\(cliCommand) \(args)"
        let (success, output) = await TerminalAIBridge.shared.processAICommand(
            fullCommand,
            purpose: "\(cliCommand) CLI"
        )
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return success ? (trimmed.isEmpty ? "✅ \(cliCommand) completed with no output." : trimmed)
                       : "❌ \(cliCommand) failed: \(trimmed)"
    }
}

// MARK: - OCRTool

/// Extracts text from an image file using Vision OCR.
@available(macOS 26.0, *)
struct OCRTool: Tool {
    let name = "read_text_from_image"
    let description = "Extract all text from an image file using on-device OCR. Use when the user shares a screenshot, photo, or document image and wants the text read out."

    @Generable
    struct Arguments {
        @Guide(description: "Absolute file path to the image (PNG, JPEG, HEIC, TIFF, etc.).")
        var imagePath: String

        init() { self.imagePath = "" }
    }

    func call(arguments: Arguments) async throws -> String {
        let path = arguments.imagePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return "❌ No image path provided." }
        let url = URL(fileURLWithPath: path)
        guard let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return "❌ Could not load image at \(path)" }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        let lines = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? "No text found in the image." : lines.joined(separator: "\n")
    }
}

// Note: BarcodeReaderTool is provided as a built-in by FoundationModels (Apple Intelligence).
// No custom implementation needed — use BarcodeReaderTool() directly in LanguageModelSession tools.

// MARK: - ScreenCaptureTool

/// Captures the current screen and returns OCR-extracted text from it.
@available(macOS 26.0, *)
struct ScreenCaptureTool: Tool {
    let name = "capture_screen_text"
    let description = "Take a screenshot of the current screen and extract all visible text using OCR. Use when the user asks what is on screen, to read a UI element, or to analyze visible content."

    @Generable
    struct Arguments {
        init() {}
    }

    func call(arguments: Arguments) async throws -> String {
        let shareableContent = try await SCShareableContent.current
        guard let display = shareableContent.displays.first else {
            return "❌ No display available for screen capture."
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        let lines = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { return "No text visible on screen." }
        return "Screen text:\n" + lines.joined(separator: "\n")
    }
}

// MARK: - OnDeviceToolSession

/// Builds a LanguageModelSession with all available tools for the current context,
/// runs a multi-turn tool loop, and returns the final assistant response.
@available(macOS 26.0, *)
@MainActor
final class OnDeviceToolSession {

    static let shared = OnDeviceToolSession()
    private init() {}

    // Returns CLI tool summary lines to append to the system prompt so the model
    // knows which CLIs are available and can call run_<tool> with the right subcommands.
    private func cliInstructions(for bundleId: String) -> String {
        let cliActions = AppAdapterManager.shared.actions(for: bundleId)
            .filter { $0.type == .cliTool }
        guard !cliActions.isEmpty else { return "" }
        var lines = "\n\n## CLI TOOLS IN SCOPE\n"
        lines += "The following CLI tools are attached. Call run_<toolname> with subcommands and flags.\n"
        lines += "ALWAYS execute the tool and return the real output — never guess or fabricate results.\n"
        for action in cliActions {
            let cmd = (action.cliToolCommand ?? action.name)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let desc = action.description.isEmpty ? action.name : action.description
            lines += "- **\(cmd)**: \(desc)\n"
        }
        return lines
    }

    private func appMenuInstructions(for bundleId: String, axContext: AXContext) -> String {
        guard !bundleId.hasPrefix("cli://") else { return "" }
        let appName = axContext.appName.isEmpty
            ? (NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == bundleId && !$0.isTerminated
            })?.localizedName ?? bundleId)
            : axContext.appName

        let items = AppMenuCapabilityCache.shared.menuItems(
            bundleIdentifier: bundleId,
            appName: appName,
            processIdentifier: axContext.pid,
            query: "",
            maxResults: 36
        )

        let menuLines = items.prefix(24).map { item in
            let shortcut = item.shortcutDisplay.map { " [\($0)]" } ?? ""
            let disabled = item.isEnabled ? "" : " (disabled)"
            return "- \(item.path.joined(separator: " > "))\(shortcut)\(disabled)"
        }.joined(separator: "\n")

        var prompt = """


        ## APP MENU ACTION RULES
        The user is scoped to \(appName). For app UI commands, map the natural-language request to this app's known menu catalog and execute a tool. Do not invent AppleScript or describe clicks.
        - Prefer execute_app_menu_intent(intent:) for natural-language app menu requests.
        - Use list_app_menu_actions(query:) when you need to inspect available paths.
        - Use execute_app_menu_path(path:) only with an exact path from the menu catalog.
        - If the best matching menu is disabled, say what state/selection is needed instead of trying random alternatives.
        - After executing, summarize the exact menu path used in one short sentence.
        """

        if !menuLines.isEmpty {
            prompt += "\n\nKnown \(appName) menu actions:\n\(menuLines)"
        }
        return prompt
    }

    /// Returns the CLI command name for cli:// adapter bundle IDs (e.g. "yt-dlp").
    private func cliAdapterCommand(for bundleId: String) -> String? {
        guard bundleId.hasPrefix("cli://") else { return nil }
        let cmd = String(bundleId.dropFirst("cli://".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cmd.isEmpty ? nil : cmd
    }

    private func tools(
        for bundleId: String,
        axContext: AXContext
    ) -> [any Tool] {
        // For cli:// adapter scopes, only expose shell tool — no app menu / AX tools needed.
        if let cliCmd = cliAdapterCommand(for: bundleId) {
            _ = cliCmd  // used in system prompt, not needed here
            return [
                ShellCommandTool(axContext: axContext),
                SpawnWorkerTool(),
            ]
        }

        let resolvedAppName =
            axContext.appName.isEmpty
            ? (NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == bundleId && !$0.isTerminated
            })?.localizedName ?? bundleId)
            : axContext.appName
        let resolvedPID: pid_t =
            axContext.bundleId == bundleId && axContext.pid != 0
            ? axContext.pid
            : (NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == bundleId && !$0.isTerminated
            })?.processIdentifier ?? 0)

        var baseTools: [any Tool] = [
            ListAppMenuActionsTool(
                bundleId: bundleId,
                appName: resolvedAppName,
                processIdentifier: resolvedPID
            ),
            ExecuteAppMenuIntentTool(
                bundleId: bundleId,
                appName: resolvedAppName,
                processIdentifier: resolvedPID
            ),
            ExecuteAppMenuPathTool(
                bundleId: bundleId,
                appName: resolvedAppName
            ),
            ResolveMetadataTool(),
            ShellCommandTool(axContext: axContext),
            SpawnWorkerTool(),
            SendKeysTool(),
            // Vision tools
            OCRTool(),
            ScreenCaptureTool(),
            // EventKit — available in all app contexts and global chat
            GetCalendarEventsTool(),
            AddCalendarEventTool(),
            GetRemindersTool(),
            AddReminderTool(),
            SearchContactsTool(),
            SearchPhotosTool(),
            SearchNotesTool(),
            CreateNoteTool(),
        ]

        if bundleId == "com.apple.mail" {
            baseTools.append(SearchMailTool())
            baseTools.append(GetMailMailboxSnapshotTool())
        }

        if bundleId == "com.apple.MobileSMS" {
            baseTools.append(SearchMessagesTool())
            baseTools.append(GetMessagesConversationSnapshotTool())
            baseTools.append(ComposeMessageTool())
        }

        let adapterActions = AppAdapterManager.shared.actions(for: bundleId)
        var adapterTools: [any Tool] = adapterActions.map { action in
            // CLI tool actions get a parameterized tool so the model can pass subcommands/flags.
            // All other action types use the self-contained AdapterActionTool.
            if action.type == .cliTool {
                return CLIAdapterTool(action: action) as any Tool
            }
            return AdapterActionTool(action: action, bundleId: bundleId, axContext: axContext) as any Tool
        }
        adapterTools.append(ListAdaptersTool(bundleId: bundleId))

        return baseTools + adapterTools
    }

    /// Builds a focused system prompt for cli:// adapter scopes.
    private func cliScopeSystemPrompt(command: String) -> String {
        let pkg = TerminalPackageManager.shared.packages
            .first(where: { $0.command.caseInsensitiveCompare(command) == .orderedSame })
        var prompt = """
            You are a CLI assistant for '\(command)'. \
            Only answer questions about '\(command)' and generate '\(command)' commands. \
            Always use run_shell_command to run '\(command)' commands and return the real output — \
            never guess or fabricate results. Always ask for approval before running destructive commands.
            """
        if let helpSnippet = pkg?.helpTextForPrompt {
            prompt += "\n\n## \(command) --help\n\(helpSnippet)"
        } else if let subs = pkg?.subcommands, !subs.isEmpty {
            prompt += "\n\nAvailable subcommands: \(subs.joined(separator: ", "))"
        }
        return prompt
    }

    /// Run a query through on-device AI.
    /// Structured extraction queries (links, action items, data) bypass the tool loop
    /// and use @Generable typed output for reliable structured results.
    /// All other queries use the tool-based session with adapter actions + shell access.
    func respond(
        to message: String,
        systemPrompt: String,
        bundleId: String,
        axContext: AXContext
    ) async throws -> String {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw NSError(domain: "OnDeviceToolBridge", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Apple Intelligence is not available. Enable it in System Settings > Apple Intelligence."])
        }

        // For cli:// scopes, replace system prompt with a focused CLI prompt
        let fullPrompt: String
        if let cliCmd = cliAdapterCommand(for: bundleId) {
            fullPrompt = cliScopeSystemPrompt(command: cliCmd)
        } else {
            fullPrompt = systemPrompt
                + appMenuInstructions(for: bundleId, axContext: axContext)
                + cliInstructions(for: bundleId)
        }

        // Regular tool-based response: adapter actions + shell + discovery
        let session = LanguageModelSession(tools: tools(for: bundleId, axContext: axContext), instructions: fullPrompt)
        let response = try await session.respond(to: message)
        let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

        // If the model ran tools silently without producing text, ask it to summarize the result.
        if content.isEmpty {
            let summary = try? await session.respond(
                to: "Summarize what you just did and the result in one to two sentences."
            )
            let summaryText = summary?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return summaryText.isEmpty ? "Done." : summaryText
        }
        return content
    }

    /// Streaming version — delivers partial tokens via onPartial callback.
    /// Structured extraction queries run non-streaming (result delivered via onComplete at once).
    /// `imageURLs`: optional image attachments — OCR text is prepended to the prompt for on-device multimodal context.
    func stream(
        to message: String,
        imageURLs: [URL] = [],
        systemPrompt: String,
        bundleId: String,
        axContext: AXContext,
        onPartial: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) {
        Task {
            do {
                let model = SystemLanguageModel.default
                guard case .available = model.availability else {
                    onError("Apple Intelligence not available.")
                    return
                }

                // For cli:// scopes, replace system prompt with a focused CLI prompt
                let fullPrompt: String
                if let cliCmd = self.cliAdapterCommand(for: bundleId) {
                    fullPrompt = self.cliScopeSystemPrompt(command: cliCmd)
                } else {
                    fullPrompt = self.systemPrompt(
                        systemPrompt,
                        appendingMenuAndCLIFor: bundleId,
                        axContext: axContext
                    )
                }

                // Dynamic Profile: use tools-capable session for complex queries,
                // bare session for pure chat to reduce latency.
                let looksLikeToolQuery = Self.looksLikeToolQuery(message) || !imageURLs.isEmpty
                let session: LanguageModelSession
                if looksLikeToolQuery {
                    session = LanguageModelSession(
                        tools: self.tools(for: bundleId, axContext: axContext),
                        instructions: fullPrompt
                    )
                } else {
                    session = LanguageModelSession(instructions: fullPrompt)
                }

                // Images: OCR-extract text and prepend to message for context
                var finalMessage = message
                if !imageURLs.isEmpty {
                    let ocrLines: [String] = imageURLs.compactMap { url -> CGImage? in
                        NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    }.flatMap { cgImage -> [String] in
                        let req = VNRecognizeTextRequest()
                        req.recognitionLevel = .accurate
                        req.usesLanguageCorrection = true
                        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                        try? handler.perform([req])
                        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    }
                    if !ocrLines.isEmpty {
                        finalMessage = "Image content:\n\(ocrLines.joined(separator: "\n"))\n\n\(message)"
                    }
                }

                var lastLength = 0
                var finalContent = ""
                for try await snapshot in session.streamResponse(to: finalMessage, generating: String.self) {
                    let full = snapshot.content
                    let delta = String(full.dropFirst(lastLength))
                    lastLength = full.count
                    finalContent = full
                    if !delta.isEmpty { onPartial(delta) }
                }

                // If the model executed tools but produced no text, request a summary.
                if finalContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let summary = try? await session.respond(
                        to: "Summarize what you just did and the result in one to two sentences."
                    )
                    let summaryText = summary?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    onComplete(summaryText.isEmpty ? "Done." : summaryText)
                } else {
                    onComplete(finalContent)
                }
            } catch {
                onError("Apple Intelligence error: \(error.localizedDescription)")
            }
        }
    }

    // Heuristic: does the message look like it needs tool execution?
    private static func looksLikeToolQuery(_ message: String) -> Bool {
        let lower = message.lowercased()
        let toolKeywords = ["open ", "run ", "execute ", "close ", "quit ",
                            "file ", "folder ", "shell ", "terminal ", "git ",
                            "rename ", "delete ", "copy ", "move ", "create ",
                            "show me ", "find ", "search for ", "list "]
        return toolKeywords.contains { lower.hasPrefix($0) || lower.contains(" \($0)") }
    }

    private func systemPrompt(
        _ base: String,
        appendingMenuAndCLIFor bundleId: String,
        axContext: AXContext
    ) -> String {
        base
            + appMenuInstructions(for: bundleId, axContext: axContext)
            + cliInstructions(for: bundleId)
    }
}

#endif // canImport(FoundationModels)
