import Foundation

/// "find notes with links." in an app that owns a record set (Notes, Mail, Reminders…) is a read
/// of those records, not a GUI command. One predicate, used by every pipeline that plans an
/// app-scoped turn (the Corner's task plan, the source authority, and `AppScopedChatService`
/// behind the MCP and CLI), so the rule cannot drift between them.
///
/// The lane is the one `RequestLane` decides: a sentence about the interface ("find the
/// sidebar") is UI and stays an action, as does any explicit action word ("open", "create"…).
enum ScopedRecordRead {
    /// Words that ask the app to do something rather than to look something up.
    static let actionWords = [
        "create ", "draft ", "reply ", "send ", "delete ", "move ", "rename ", "install ",
        "open ", "play ", "save ", "write ", "add ", "remove ", "update ", "run ", "close ",
        "quit ", "enable ", "disable ", "export ",
        // Switching a setting or pressing a control. "turn on the spelling option" had none of
        // the words above, planned as a read, and was handed no menu or window tool at all.
        "turn on ", "turn off ", "switch on ", "switch off ", "toggle ", "uncheck ", "untick ",
        "click ", "press ",
    ]

    static func hasExplicitAction(_ query: String) -> Bool {
        let lower = query.lowercased()
        return actionWords.contains(where: lower.contains)
    }

    static func matches(query: String, bundleId: String) -> Bool {
        let lower = query.lowercased()
        return ReadOnlyDataDomain(scopeBundleId: bundleId) != nil
            && RequestLane.decide(query) == .data
            && ["find ", "search ", "list "].contains(where: lower.contains)
            && !hasExplicitAction(query)
    }
}

/// A deterministic contract for one app-scoped turn, decided before optional context reads.
struct FrontmostAppTaskPlan: Equatable {
    enum Intent: String { case answer = "answer a question", read = "read app data", act = "perform an app action", workflow = "complete a multi-step task" }
    enum Source: Hashable { case scopedApp, selection, attachments, browserPage, workspace, officialReference, memory }

    let goal: String
    let appName: String
    let bundleId: String
    let intent: Intent
    let sources: Set<Source>
    let allowedToolNames: Set<String>
    let complexity: TaskComplexityRoute
    let agentNeverRules: [String]

    init(goal: String, appName: String, bundleId: String, intent: Intent, sources: Set<Source>,
         allowedToolNames: Set<String>, complexity: TaskComplexityRoute, agentNeverRules: [String] = []) {
        self.goal = goal
        self.appName = appName
        self.bundleId = bundleId
        self.intent = intent
        self.sources = sources
        self.allowedToolNames = allowedToolNames
        self.complexity = complexity
        self.agentNeverRules = agentNeverRules
    }

    func allows(_ source: Source) -> Bool { sources.contains(source) }
    var permitsUIAutomation: Bool { intent == .act || intent == .workflow }

    var promptRule: String {
        let names = sources.map { source -> String in
            switch source {
            case .scopedApp: return "the scoped app and its adapters"
            case .selection: return "the user's selection"
            case .attachments: return "the supplied attachments"
            case .browserPage: return "the current browser page"
            case .workspace: return "the app workspace"
            case .officialReference: return "official app references"
            case .memory: return "relevant local memory"
            }
        }.sorted().joined(separator: ", ")
        var contract = """
            TASK CONTRACT
            Goal: \(goal)
            Target app: \(appName) (\(bundleId))
            Intent: \(intent.rawValue)
            Allowed evidence sources: \(names)
            Do not read, search, mention, or act through an unrelated app or source. Use the \
            minimum allowed tools, stop when evidence supports the goal, and report a missing \
            source plainly instead of substituting another source.
            """
        if !agentNeverRules.isEmpty {
            contract += "\n\nAPP SAFETY RULES (AGENT.md):\n"
                + agentNeverRules.map { "- \($0)" }.joined(separator: "\n")
        }
        return contract
    }

    var initialProgress: [String] {
        ["Understood: \(intent.rawValue)", "Target: \(appName)", "Planned the minimum evidence route"]
    }

    static func make(query: String, bundleId: String, appName: String,
                     hasSelection: Bool = false, hasAttachments: Bool = false,
                     priorConversation: String = "",
                     previousUserRequests: [String] = []) -> Self {
        // Agreeing to an action is not asking a question.
        //
        // Offered "Claude ▸ Check for Updates… Run it?" and answered "sure", the plan read
        // the word "sure", found no action verb in it, and withheld run_menu_command — so the
        // model reported, correctly, that it had no menu tool. The offer was disarmed by its
        // own acceptance. A bare agreement carries the intent of the request it agreed to.
        let intentQuery = ChatRouteRecovery.resolutionQuery(
            current: query, previousUserRequests: previousUserRequests)
        let lower = intentQuery.lowercased()
        let subjectContext = lower + "\n" + priorConversation.lowercased()
        // A records read needs a tool round: the "direct" instruction ("answer without tools")
        // is why the model answered "find notes with links." from the window and told the user
        // to search themselves.
        let routed = TaskComplexityRouter.route(intentQuery)
        let complexity: TaskComplexityRoute =
            routed == .direct && ScopedRecordRead.matches(query: intentQuery, bundleId: bundleId)
            ? .bounded : routed
        // "update the app" was not an action here, which is how agreeing to run Check for
        // Updates still produced a turn with no menu tool. The words a person uses to ask an
        // app to do something are wider than create/draft/send.
        //
        // "launch " is deliberately absent. It matched "which conversations mention the launch
        // date?" — a noun, in a question, granted UI automation. A word that is as often a
        // noun as a verb cannot be read as intent by substring, which is the lesson "trash"
        // already taught this file's neighbours.
        let actionWords = ScopedRecordRead.actionWords
        let readWords = ["find ", "search ", "list ", "show ", "read ", "what ", "which ", "who ", "when ", "how many", "summar", "check "]
        // The window verbs are deliberately not added to `actionWords` above: matched by
        // substring they would read "how do i hide the sidebar?" as a command. They live in
        // ChatRouteResolver.isActionRequest, which already refuses question shapes — a
        // leading what/which/how, a trailing "?" — so asking about a verb stays a question
        // while commanding with one is an action.
        //
        // Without this, "minimise code app after 2min" planned as intent .answer: the turn
        // was handed run_adapter_action AND an inventory naming the saved action, and then
        // told in its own task contract that its job was to answer a question. It described
        // the action instead of calling it, which is exactly what the contract asked for.
        // "find"/"search"/"list" lead the resolver's GUI-verb list, so "find notes with links."
        // planned as an action and the model was handed `operate_app`. In a record-set app they
        // ask for a data read: no UI-lane tools (plan 2a). See `ScopedRecordRead`.
        let readsScopeRecords = ScopedRecordRead.matches(query: intentQuery, bundleId: bundleId)
        // A question is not a command (#357). "How many tabs are open in Safari?" contains the
        // action word "open " as an adjective, planned as an action and was handed
        // run_menu_command. `asksOnly` already knows a question from an instruction ("can you
        // open safari?" stays one), so the substring match only decides for non-questions.
        let asksOnly = GeneralAIActionResolver.shared.asksOnly(intentQuery)
        let hasAction = !asksOnly
            && (actionWords.contains(where: lower.contains)
                || (!readsScopeRecords && ChatRouteResolver.isActionRequest(intentQuery)))
        let hasRead = readWords.contains(where: lower.contains)
        let intent: Intent = complexity == .extended ? .workflow : (hasAction ? .act : (hasRead ? .read : .answer))

        let isBrowser = ScopedAppPromptBuilder.isBrowserBundle(bundleId)
        let pageTerms = ["this page", "current page", "open page", "page is open", "website", "webpage", "active tab", "open tab", "this site", "url", "link on"]
        // read_page reads the browser's *open* page, so it is browser-only and stays that way.
        let needsPage = isBrowser && pageTerms.contains(where: subjectContext.contains)
        // read_url is a different tool that happened to be gated with it: it fetches a URL over
        // the network and, in its own words, "nothing is opened on screen and no browser is
        // touched". Tying it to whether the frontmost app is a browser meant that asking about
        // an app's own website — in that app — had no way to be answered, and the turn fell
        // back to a Help ▸ Website menu click that needed approval.
        let linkTerms = ["website", "web site", "webpage", "web page", "homepage", "home page",
                         "http://", "https://", "www.", ".com", "docs", "documentation",
                         "their site", "official site"]
        let needsLink = needsPage || linkTerms.contains(where: subjectContext.contains)
        let workspaceTerms = ["project", "repository", "repo", "branch", "commit", "working tree", "uncommitted", "build", "source code", "extensions installed"]
        let needsWorkspace = workspaceTerms.contains(where: subjectContext.contains)
        // "website", "homepage" and "site" were absent, so a question about an app's own site
        // did not count as a reference question either — both doors onto the web were shut at
        // once, which is why only a menu click was left.
        let referenceTerms = ["what is this app", "what does this app", "how do i use", "documentation", "docs", "feature", "version", "supports", "website", "web site", "homepage", "home page", "official site"]
        let needsReference = referenceTerms.contains(where: subjectContext.contains)

        var sources: Set<Source> = [.scopedApp]
        if hasSelection { sources.insert(.selection) }
        if hasAttachments { sources.insert(.attachments) }
        if needsPage { sources.insert(.browserPage) }
        if needsWorkspace { sources.insert(.workspace) }
        if needsReference { sources.insert(.officialReference) }
        if !hasRead && !hasAction { sources.insert(.memory) }

        var tools: Set<String> = ["find_capability", "run_capability", "run_adapter_action", "run_mcp_tool", "verify_outcome"]
        let id = bundleId.lowercased()
        if id.contains("imessage") || id.contains("messages") || id.contains("mobilesms") {
            tools.formUnion(["get_messages_conversations", "search_messages", "compose_message", "send_message"])
        }
        if needsPage { tools.insert("read_page") }
        if needsLink { tools.insert("read_url") }
        if hasSelection { tools.insert("read_selection") }
        // Finding a file by name is read-only, so it is offered freely: always in Finder, and in
        // any app when the sentence is about a file. Spotlight is often off; find_files scans.
        let fileTerms = [" file", " pdf", " document", " spreadsheet", " folder", "passport",
                         "invoice", "receipt", "screenshot"]
        if id.contains("finder") || fileTerms.contains(where: { (" " + lower).contains($0) }) {
            tools.insert("find_files")
        }
        // A file to hand back (a csv, a markdown note, a Word document). It is a write and always
        // asks, so it is offered only when the sentence names one of those outputs.
        let outputTerms = ["csv", "markdown", ".md", "docx", "word document", "text file",
                           "spreadsheet", "save it as a file", "output file", "export"]
        if outputTerms.contains(where: { lower.contains($0) }) {
            tools.insert("write_output_file")
        }
        // The user's Shortcuts: offered only when the sentence is about them. Running one asks.
        let shortcutTerms = ["shortcut", "automation", "run my ", "siri"]
        if shortcutTerms.contains(where: { lower.contains($0) }) {
            tools.formUnion(["list_shortcuts", "run_shortcut"])
        }
        if hasAttachments { tools.formUnion(["read_attachment", "read_file"]) }

        // Universal App Pet principle: an app-scoped pet is NEVER starved of its app's
        // control and vision tools by brittle keyword matchers. The model is the brain;
        // Context-Dock is the safe native body. The safety guards (consent store,
        // approval cards, emergency stop HUD, destructive denylist) govern execution.
        if !bundleId.isEmpty {
            tools.formUnion([
                "find_menu_command", "run_menu_command", "send_keys", "window_control",
                "operate_app", "ax_snapshot", "ax_act", "read_app_dictionary", "run_synthesized_script",
            ])
        } else if hasAction {
            tools.formUnion([
                "find_menu_command", "run_menu_command", "send_keys", "window_control",
                "operate_app", "ax_snapshot", "ax_act", "read_app_dictionary", "run_synthesized_script",
            ])
        }

        var agentNeverRules: [String] = []
        if !bundleId.isEmpty {
            tools.formUnion(["read_app_dictionary", "run_synthesized_script"])
            if let profile = AppAgentProfileStore.shared.profile(forBundleID: bundleId, appName: appName) {
                agentNeverRules = profile.never
                if let scripts = profile.tools.scripts, !scripts.isEmpty {
                    tools.insert("run_app_script")
                }
                if let caps = profile.tools.capabilities, !caps.isEmpty {
                    tools.formUnion(["find_capability", "run_capability"])
                }
                if let mcps = profile.tools.mcp, !mcps.isEmpty {
                    tools.insert("run_mcp_tool")
                }
                if let actions = profile.tools.actions, !actions.isEmpty {
                    tools.insert("run_adapter_action")
                }
                if let clis = profile.tools.cli, !clis.isEmpty {
                    tools.insert("run_command")
                }
            }
        }

        return Self(goal: intentQuery.trimmingCharacters(in: .whitespacesAndNewlines), appName: appName,
                    bundleId: bundleId, intent: intent, sources: sources,
                    allowedToolNames: tools, complexity: complexity, agentNeverRules: agentNeverRules)
    }
}
