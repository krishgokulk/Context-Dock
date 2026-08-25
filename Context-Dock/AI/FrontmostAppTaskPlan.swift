import Foundation

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
        return """
            TASK CONTRACT
            Goal: \(goal)
            Target app: \(appName) (\(bundleId))
            Intent: \(intent.rawValue)
            Allowed evidence sources: \(names)
            Do not read, search, mention, or act through an unrelated app or source. Use the \
            minimum allowed tools, stop when evidence supports the goal, and report a missing \
            source plainly instead of substituting another source.
            """
    }

    var initialProgress: [String] {
        ["Understood: \(intent.rawValue)", "Target: \(appName)", "Planned the minimum evidence route"]
    }

    static func make(query: String, bundleId: String, appName: String,
                     hasSelection: Bool = false, hasAttachments: Bool = false,
                     priorConversation: String = "") -> Self {
        let lower = query.lowercased()
        let subjectContext = lower + "\n" + priorConversation.lowercased()
        let complexity = TaskComplexityRouter.route(query)
        let actionWords = ["create ", "draft ", "reply ", "send ", "delete ", "move ", "rename ", "install ", "open ", "play ", "save ", "write ", "add ", "remove "]
        let readWords = ["find ", "search ", "list ", "show ", "read ", "what ", "which ", "who ", "when ", "how many", "summar", "check "]
        let hasAction = actionWords.contains(where: lower.contains)
        let hasRead = readWords.contains(where: lower.contains)
        let intent: Intent = complexity == .extended ? .workflow : (hasAction ? .act : (hasRead ? .read : .answer))

        let isBrowser = ScopedAppPromptBuilder.isBrowserBundle(bundleId)
        let pageTerms = ["this page", "current page", "open page", "page is open", "website", "webpage", "active tab", "open tab", "this site", "url", "link on"]
        let needsPage = isBrowser && pageTerms.contains(where: subjectContext.contains)
        let workspaceTerms = ["project", "repository", "repo", "branch", "commit", "working tree", "uncommitted", "build", "source code", "extensions installed"]
        let needsWorkspace = workspaceTerms.contains(where: subjectContext.contains)
        let referenceTerms = ["what is this app", "what does this app", "how do i use", "documentation", "docs", "feature", "version", "supports"]
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
            tools.formUnion(["get_messages_conversations", "search_messages"])
            if hasAction { tools.insert("compose_message") }
        }
        if needsPage { tools.formUnion(["read_page", "read_url"]) }
        if hasSelection { tools.insert("read_selection") }
        if hasAttachments { tools.formUnion(["read_attachment", "read_file"]) }
        if hasAction { tools.formUnion(["run_menu_command", "send_keys", "window_control"]) }

        return Self(goal: query.trimmingCharacters(in: .whitespacesAndNewlines), appName: appName,
                    bundleId: bundleId, intent: intent, sources: sources,
                    allowedToolNames: tools, complexity: complexity)
    }
}
