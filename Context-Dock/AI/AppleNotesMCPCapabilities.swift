import Foundation

// First-party Apple Notes MCP capabilities registered in CapabilityRegistry.
// Risk levels:
//   notes.search          → .low   (metadata only, no approval)
//   notes.link_related    → .low   (metadata only, no approval)
//   notes.read            → .low   (approval handled inside executor; persistent read skips UI)
//   notes.extract_tasks   → .low   (read + AI extract — approval inside executor)
//   notes.summarize       → .low   (read + AI — cloud approval inside executor)
//   notes.create          → .medium (AIExecutionEngine requests approval before running executor)
//   notes.append          → .medium
//   notes.update          → .medium
//   notes.export          → .medium
//   notes.delete          → .high  (hard-blocked if delete not enabled; approval via engine)
//
// Register by calling AppleNotesMCPCapabilities.register(in:) from CapabilityRegistry.registerBuiltIns()
// when noteMCPEnabled is true, OR from a settings observer when the toggle is flipped on.

@MainActor
enum AppleNotesMCPCapabilities {

    static func register(in registry: CapabilityRegistry) {
        registerSearch(registry)
        registerRead(registry)
        registerCreate(registry)
        registerAppend(registry)
        registerUpdate(registry)
        registerExtractTasks(registry)
        registerLinkRelated(registry)
        registerSummarize(registry)
        registerExport(registry)
        registerDelete(registry)
    }

    // MARK: - notes.search

    private static func registerSearch(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "notes.search",
                title: "Search Apple Notes",
                appBundleID: "com.apple.Notes",
                inputSchema: .init(fields: [
                    .init(name: "query", description: "Search query matching note title, body snippet, or folder", required: true),
                    .init(name: "maxResults", description: "Maximum notes to return (default 10)", required: false),
                ]),
                riskLevel: .low
            ) { request in
                guard let query = request.input["query"], !query.isEmpty else {
                    throw AICapabilityError.missingInput("query")
                }
                guard AppSettings.shared.noteMCPEnabled else {
                    throw AppleNotesError.notEnabled
                }
                let max = Int(request.input["maxResults"] ?? "10") ?? 10
                let results = try await AppleNotesMCPServer.shared.search(query: query, maxResults: max)
                if results.isEmpty {
                    return .init(success: true, output: "No notes found matching '\(query)'.")
                }
                let body = results.map { n in
                    "ID: \(n.id)\nTitle: \(n.title)\nFolder: \(n.folder)\nModified: \(n.modifiedDate)\nSnippet: \(n.snippet)"
                }.joined(separator: "\n---\n")
                return .init(success: true, output: "Found \(results.count) note(s):\n\n\(body)")
            }
        )
    }

    // MARK: - notes.read

    private static func registerRead(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "notes.read",
                title: "Read Apple Note",
                appBundleID: "com.apple.Notes",
                inputSchema: .init(fields: [
                    .init(name: "noteID", description: "Note ID from notes.search result", required: true),
                ]),
                riskLevel: .low  // approval handled inside executor based on persistent-read setting
            ) { request in
                guard let noteID = request.input["noteID"], !noteID.isEmpty else {
                    throw AICapabilityError.missingInput("noteID")
                }
                guard AppSettings.shared.noteMCPEnabled else {
                    throw AppleNotesError.notEnabled
                }
                // Per-call approval unless persistent full-read is enabled
                if !AppSettings.shared.noteMCPAllowPersistentFullRead {
                    let plan = AIActionPlan(
                        capability: "notes.read",
                        input: request.input,
                        explanation: "Read full content of note \(noteID)"
                    )
                    guard let cap = CapabilityRegistry.shared.capability(id: "notes.read") else {
                        throw AICapabilityError.unknownCapability("notes.read")
                    }
                    let approved = await AICapabilityApprovalCenter.shared.requestApproval(
                        plan: plan, capability: cap, context: request.context
                    )
                    guard approved else {
                        AppleNotesMCPAuditLogger.shared.record(
                            toolName: "notes.read", noteIDs: [noteID],
                            riskLevel: .medium, approvalStatus: .denied
                        )
                        throw AICapabilityError.approvalRequired("Read Note")
                    }
                }
                let note = try await AppleNotesMCPServer.shared.readNote(id: noteID, providerName: "local")
                let bodyText = AppleNotesExecutionService.shared.stripHTML(note.body)
                return .init(
                    success: true,
                    output: "Title: \(note.title)\nFolder: \(note.folder)\nModified: \(note.modified)\n\nContent:\n\(bodyText)"
                )
            }
        )
    }

    // MARK: - notes.create

    private static func registerCreate(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "notes.create",
                title: "Create Apple Note",
                appBundleID: "com.apple.Notes",
                inputSchema: .init(fields: [
                    .init(name: "title", description: "Note title", required: true),
                    .init(name: "body", description: "Note body content", required: true),
                    .init(name: "folder", description: "Target folder name (optional)", required: false),
                ]),
                riskLevel: .medium  // AIExecutionEngine shows preview + approval before calling executor
            ) { request in
                guard let title = request.input["title"], !title.isEmpty else {
                    throw AICapabilityError.missingInput("title")
                }
                guard let body = request.input["body"] else {
                    throw AICapabilityError.missingInput("body")
                }
                guard AppSettings.shared.noteMCPEnabled else {
                    throw AppleNotesError.notEnabled
                }
                let folder = request.input["folder"].flatMap { $0.isEmpty ? nil : $0 }
                let newID = try await AppleNotesMCPServer.shared.createNote(
                    title: title, body: body, folder: folder, providerName: "local"
                )
                return .init(success: true, output: "Created note '\(title)' with ID: \(newID)")
            }
        )
    }

    // MARK: - notes.append

    private static func registerAppend(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "notes.append",
                title: "Append to Apple Note",
                appBundleID: "com.apple.Notes",
                inputSchema: .init(fields: [
                    .init(name: "noteID", description: "Note ID from notes.search result", required: true),
                    .init(name: "text", description: "Text to append to the note", required: true),
                ]),
                riskLevel: .medium
            ) { request in
                guard let noteID = request.input["noteID"], !noteID.isEmpty else {
                    throw AICapabilityError.missingInput("noteID")
                }
                guard let text = request.input["text"], !text.isEmpty else {
                    throw AICapabilityError.missingInput("text")
                }
                guard AppSettings.shared.noteMCPEnabled else {
                    throw AppleNotesError.notEnabled
                }
                try await AppleNotesMCPServer.shared.appendToNote(id: noteID, text: text, providerName: "local")
                return .init(success: true, output: "Appended text to note \(noteID).")
            }
        )
    }

    // MARK: - notes.update

    private static func registerUpdate(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "notes.update",
                title: "Update Apple Note",
                appBundleID: "com.apple.Notes",
                inputSchema: .init(fields: [
                    .init(name: "noteID", description: "Note ID from notes.search result", required: true),
                    .init(name: "title", description: "New title (leave empty to keep existing)", required: false),
                    .init(name: "body", description: "New body content (leave empty to keep existing)", required: false),
                ]),
                riskLevel: .medium
            ) { request in
                guard let noteID = request.input["noteID"], !noteID.isEmpty else {
                    throw AICapabilityError.missingInput("noteID")
                }
                guard AppSettings.shared.noteMCPEnabled else {
                    throw AppleNotesError.notEnabled
                }
                let title = request.input["title"].flatMap { $0.isEmpty ? nil : $0 }
                let body = request.input["body"].flatMap { $0.isEmpty ? nil : $0 }
                guard title != nil || body != nil else {
                    return .init(success: false, output: "Provide 'title' or 'body' (or both) to update.")
                }
                try await AppleNotesMCPServer.shared.updateNote(
                    id: noteID, title: title, body: body, providerName: "local"
                )
                return .init(success: true, output: "Updated note \(noteID).")
            }
        )
    }

    // MARK: - notes.extract_tasks

    private static func registerExtractTasks(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "notes.extract_tasks",
                title: "Extract Tasks from Apple Note",
                appBundleID: "com.apple.Notes",
                inputSchema: .init(fields: [
                    .init(name: "noteID", description: "Note ID from notes.search result", required: true),
                ]),
                riskLevel: .low  // read-only; approval gated inside executor
            ) { request in
                guard let noteID = request.input["noteID"], !noteID.isEmpty else {
                    throw AICapabilityError.missingInput("noteID")
                }
                guard AppSettings.shared.noteMCPEnabled else {
                    throw AppleNotesError.notEnabled
                }
                // Full body read requires approval
                if !AppSettings.shared.noteMCPAllowPersistentFullRead {
                    let plan = AIActionPlan(
                        capability: "notes.extract_tasks",
                        input: request.input,
                        explanation: "Read note \(noteID) to extract tasks"
                    )
                    guard let cap = CapabilityRegistry.shared.capability(id: "notes.extract_tasks") else {
                        throw AICapabilityError.unknownCapability("notes.extract_tasks")
                    }
                    let approved = await AICapabilityApprovalCenter.shared.requestApproval(
                        plan: plan, capability: cap, context: request.context
                    )
                    guard approved else {
                        AppleNotesMCPAuditLogger.shared.record(
                            toolName: "notes.extract_tasks", noteIDs: [noteID],
                            riskLevel: .medium, approvalStatus: .denied
                        )
                        throw AICapabilityError.approvalRequired("Read Note for Task Extraction")
                    }
                }
                let note = try await AppleNotesExecutionService.shared.readNote(id: noteID)
                let bodyText = AppleNotesExecutionService.shared.stripHTML(note.body)
                let aiRequest = AIRequest(
                    text: "Extract all actionable tasks and TODOs from this note. Return as a numbered list only. Do not add commentary.",
                    context: .none,
                    source: .contextDock,
                    additionalContextPrompt: "Note '\(note.title)':\n\(bodyText)"
                )
                let tasks = try await AIProviderRouter.shared.send(aiRequest)
                AppleNotesMCPAuditLogger.shared.record(
                    toolName: "notes.extract_tasks", noteIDs: [noteID],
                    riskLevel: .low, approvalStatus: .approved
                )
                return .init(
                    success: true,
                    output: "Tasks from '\(note.title)':\n\n\(tasks)\n\n(Read-only extraction — no Reminders created.)"
                )
            }
        )
    }

    // MARK: - notes.link_related

    private static func registerLinkRelated(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "notes.link_related",
                title: "Find Related Apple Notes",
                appBundleID: "com.apple.Notes",
                inputSchema: .init(fields: [
                    .init(name: "noteID", description: "Note ID to find related notes for", required: true),
                    .init(name: "maxResults", description: "Maximum related notes (default 5)", required: false),
                ]),
                riskLevel: .low
            ) { request in
                guard let noteID = request.input["noteID"], !noteID.isEmpty else {
                    throw AICapabilityError.missingInput("noteID")
                }
                guard AppSettings.shared.noteMCPEnabled else {
                    throw AppleNotesError.notEnabled
                }
                let max = Int(request.input["maxResults"] ?? "5") ?? 5
                guard let target = await AppleNotesMetadataIndex.shared.note(id: noteID) else {
                    return .init(
                        success: false,
                        output: "Note \(noteID) not in metadata index. Run notes.search first."
                    )
                }
                // Keyword search over cached metadata only — no body reads
                let keywords = target.title
                    .split(separator: " ")
                    .filter { $0.count > 3 }
                    .map(String.init)
                var candidates: [NoteMetadata] = []
                for kw in keywords.prefix(4) {
                    let hits = await AppleNotesMetadataIndex.shared.search(query: kw, maxResults: max * 2)
                    candidates.append(contentsOf: hits.filter { $0.id != noteID })
                }
                let unique = Dictionary(grouping: candidates, by: \.id)
                    .values
                    .compactMap(\.first)
                    .sorted { $0.modifiedDate > $1.modifiedDate }
                    .prefix(max)
                AppleNotesMCPAuditLogger.shared.record(
                    toolName: "notes.link_related",
                    noteIDs: [noteID] + unique.map(\.id),
                    riskLevel: .low,
                    approvalStatus: .notRequired
                )
                if unique.isEmpty {
                    return .init(success: true, output: "No related notes found for '\(target.title)'.")
                }
                let formatted = unique.map {
                    "ID: \($0.id)\nTitle: \($0.title)\nFolder: \($0.folder)"
                }.joined(separator: "\n---\n")
                return .init(
                    success: true,
                    output: "Related notes for '\(target.title)':\n\n\(formatted)"
                )
            }
        )
    }

    // MARK: - notes.summarize

    private static func registerSummarize(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "notes.summarize",
                title: "Summarize Apple Note",
                appBundleID: "com.apple.Notes",
                inputSchema: .init(fields: [
                    .init(name: "noteID", description: "Note ID from notes.search result", required: true),
                ]),
                riskLevel: .low  // read approval inside executor; cloud approval also inside
            ) { request in
                guard let noteID = request.input["noteID"], !noteID.isEmpty else {
                    throw AICapabilityError.missingInput("noteID")
                }
                guard AppSettings.shared.noteMCPEnabled else {
                    throw AppleNotesError.notEnabled
                }
                let settings = AppSettings.shared
                // Determine effective AI provider
                let preferLocal = settings.noteMCPPreferLocalAI
                let providerOverride: AIProvider? = preferLocal ? .onDevice : nil
                let effectiveProvider = providerOverride ?? settings.selectedAIProvider
                // Cloud AI requires explicit approval if cloud approval setting is on
                if !AISafetyPolicy.shared.isLocal(effectiveProvider) && settings.noteMCPRequireCloudApproval {
                    let approved = await AIPrivacyApprovalCenter.shared.request(
                        provider: effectiveProvider,
                        context: .none
                    )
                    guard approved else {
                        AppleNotesMCPAuditLogger.shared.record(
                            toolName: "notes.summarize", noteIDs: [noteID],
                            riskLevel: .medium, approvalStatus: .denied,
                            providerName: effectiveProvider.rawValue
                        )
                        throw AICapabilityError.approvalRequired("Cloud AI send with note content")
                    }
                }
                // Read note (with per-call approval if persistent read not enabled)
                if !settings.noteMCPAllowPersistentFullRead {
                    let plan = AIActionPlan(
                        capability: "notes.summarize",
                        input: request.input,
                        explanation: "Read note \(noteID) to summarize"
                    )
                    guard let cap = CapabilityRegistry.shared.capability(id: "notes.summarize") else {
                        throw AICapabilityError.unknownCapability("notes.summarize")
                    }
                    let approved = await AICapabilityApprovalCenter.shared.requestApproval(
                        plan: plan, capability: cap, context: request.context
                    )
                    guard approved else {
                        AppleNotesMCPAuditLogger.shared.record(
                            toolName: "notes.summarize", noteIDs: [noteID],
                            riskLevel: .medium, approvalStatus: .denied
                        )
                        throw AICapabilityError.approvalRequired("Read Note for Summarization")
                    }
                }
                let note = try await AppleNotesExecutionService.shared.readNote(id: noteID)
                let bodyText = AppleNotesExecutionService.shared.stripHTML(note.body)
                let summaryRequest = AIRequest(
                    text: "Summarize this note concisely in 3–5 sentences.",
                    context: .none,
                    source: .contextDock,
                    additionalContextPrompt: "Note '\(note.title)':\n\(String(bodyText.prefix(4_000)))"
                )
                let summary = try await AIProviderRouter.shared.send(summaryRequest, provider: providerOverride)
                AppleNotesMCPAuditLogger.shared.record(
                    toolName: "notes.summarize", noteIDs: [noteID],
                    riskLevel: .medium, approvalStatus: .approved,
                    providerName: effectiveProvider.rawValue
                )
                return .init(success: true, output: "Summary of '\(note.title)':\n\n\(summary)")
            }
        )
    }

    // MARK: - notes.export

    private static func registerExport(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "notes.export",
                title: "Export Apple Note to Markdown",
                appBundleID: "com.apple.Notes",
                inputSchema: .init(fields: [
                    .init(name: "noteID", description: "Note ID from notes.search result", required: true),
                    .init(
                        name: "savePath",
                        description: "Optional file path to save (e.g. ~/Desktop/note.md)",
                        required: false
                    ),
                ]),
                riskLevel: .medium  // requires approval via AIExecutionEngine
            ) { request in
                guard let noteID = request.input["noteID"], !noteID.isEmpty else {
                    throw AICapabilityError.missingInput("noteID")
                }
                guard AppSettings.shared.noteMCPEnabled else {
                    throw AppleNotesError.notEnabled
                }
                let note = try await AppleNotesMCPServer.shared.readNote(id: noteID, providerName: "local")
                let markdown = htmlToMarkdown(note.body, title: note.title)
                AppleNotesMCPAuditLogger.shared.record(
                    toolName: "notes.export", noteIDs: [noteID],
                    riskLevel: .medium, approvalStatus: .approved
                )
                if let savePath = request.input["savePath"], !savePath.isEmpty {
                    let expanded = (savePath as NSString).expandingTildeInPath
                    try markdown.write(toFile: expanded, atomically: true, encoding: .utf8)
                    return .init(success: true, output: "Exported '\(note.title)' to \(savePath)")
                }
                return .init(success: true, output: "# \(note.title)\n\n\(markdown)")
            }
        )
    }

    // MARK: - notes.delete

    private static func registerDelete(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "notes.delete",
                title: "Delete Apple Note",
                appBundleID: "com.apple.Notes",
                inputSchema: .init(fields: [
                    .init(name: "noteID", description: "Note ID to permanently delete", required: true),
                ]),
                riskLevel: .high  // AIExecutionEngine will request approval; executor also checks allow-delete gate
            ) { request in
                guard let noteID = request.input["noteID"], !noteID.isEmpty else {
                    throw AICapabilityError.missingInput("noteID")
                }
                guard AppSettings.shared.noteMCPEnabled else {
                    throw AppleNotesError.notEnabled
                }
                // Hard gate: delete must be explicitly enabled
                guard AppSettings.shared.noteMCPAllowDelete else {
                    AppleNotesMCPAuditLogger.shared.record(
                        toolName: "notes.delete", noteIDs: [noteID],
                        riskLevel: .critical, approvalStatus: .denied
                    )
                    throw AICapabilityError.blocked(
                        "Note deletion is disabled. Enable it in Settings › Apple Notes › Advanced › Allow Delete Tools."
                    )
                }
                try await AppleNotesMCPServer.shared.deleteNote(id: noteID, providerName: "local")
                return .init(success: true, output: "Deleted note \(noteID) permanently.")
            }
        )
    }

    // MARK: - HTML → Markdown conversion

    private static func htmlToMarkdown(_ html: String, title: String) -> String {
        var md = html
        let replacements: [(String, String)] = [
            ("<br/>", "\n"), ("<br />", "\n"), ("<br>", "\n"),
            ("</p>", "\n"), ("<p>", ""),
            ("</h1>", "\n"), ("<h1>", "# "),
            ("</h2>", "\n"), ("<h2>", "## "),
            ("</h3>", "\n"), ("<h3>", "### "),
            ("</strong>", "**"), ("<strong>", "**"),
            ("</b>", "**"), ("<b>", "**"),
            ("</em>", "_"), ("<em>", "_"),
            ("</i>", "_"), ("<i>", "_"),
            ("</li>", ""), ("<li>", "- "),
            ("</ul>", "\n"), ("<ul>", ""),
            ("</ol>", "\n"), ("<ol>", ""),
        ]
        for (from, to) in replacements {
            md = md.replacingOccurrences(of: from, with: to, options: .caseInsensitive)
        }
        md = md.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return md.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
