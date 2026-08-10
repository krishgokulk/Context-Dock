// GeneralChatCapabilityHub.swift
// Cross-app capability access for General Chat mode.
//
// Context Dock chat is scoped to one app's MCP tools and adapters. General Chat had no
// tool access at all, so "how many notes do I have?" answered "I don't have access".
// This hub exposes EVERY enabled app adapter's MCP tools plus the saved app-scoped chat
// histories to the general chat tool loop, so the model can pick the right app's tools
// itself — the same way Claude/Codex reference tools.

import AppKit
import Foundation
import OSLog

@MainActor
final class GeneralChatCapabilityHub {
    static let shared = GeneralChatCapabilityHub()

    private var cachedBlock: String?
    private var cachedAt: Date = .distantPast
    /// Identifies what the cached block was built *from*, not just which adapters are
    /// enabled. The MCP section narrows to the app a question names, so a block built for
    /// "what's in my Notes?" lists Notes tools and nothing else — serving that to the next
    /// question tells the model the user's other apps have no tools at all.
    private var cachedKey = ""
    private let cacheTTL: TimeInterval = 300
    private let chatPanelKeyPrefix = "dock_app_"

    private init() {}

    /// Stage markers: the block is assembled from half a dozen sources, several of which
    /// do synchronous work, and a stall inside it is invisible from outside.
    private static let log = Logger(
        subsystem: "com.krishgokul.ContextDock", category: "CapabilityHub")

    func invalidate() {
        cachedBlock = nil
        cachedAt = .distantPast
        cachedKey = ""
    }

    /// Runs `operation` on a detached task and gives up on it after `seconds`.
    ///
    /// Detached and nonisolated on purpose. When this helper was a method on a @MainActor
    /// type, both the work and the timer inherited that isolation, so the timer could not
    /// be scheduled while the work held the actor — the cap never fired, and a stalled MCP
    /// handshake took the whole turn down with it.
    nonisolated static func withTimeout<T: Sendable>(
        seconds: Double,
        fallback: T,
        operation: @escaping @Sendable () async -> T
    ) async -> T {
        await withTaskGroup(of: T.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return fallback
            }
            let first = await group.next() ?? fallback
            group.cancelAll()
            return first
        }
    }

    // MARK: - Prompt block

    /// System-prompt section listing all app tools General Chat may call.
    /// Cached for 5 minutes — connecting to every linked MCP server per message is too slow.
    /// `compact` trims descriptions and tool counts for small-context providers (on-device).
    func capabilityPromptBlock(
        compact: Bool = false,
        query: String = "",
        scope: AIConversationScope = .general,
        characterBudget: Int = 12_000
    ) async -> String {
        // Discovery reaches into the MCP actor for cached tools. Bounded, because "cached"
        // only means it opens no connection — it still queues behind whatever that actor is
        // doing, and waiting on it is not worth an unanswerable chat.
        Self.log.notice("hub: discovery")
        let discovery = await Self.withTimeout(
            seconds: 5,
            fallback: CapabilityDiscoveryResult(
                scope: scope, query: query, candidates: [], generatedAt: Date())
        ) {
            await CapabilityDiscoveryService.shared.discover(query: query, scope: scope)
        }
        let discoveryLines = discovery.promptLines
        // Built-ins are cheap (in-memory registry) and toggle live — never cache them,
        // so a flipped toggle shows up on the very next message.
        Self.log.notice("hub: builtins")
        let builtinLines = builtInCapabilityLines()
        let enabledAdapters = AppAdapterManager.shared.adapters.filter(\.isEnabled)
        let allowlistFingerprint = enabledAdapters
            .map { "\($0.bundleId):\($0.actions.count):\($0.contextReaders.count)" }
            .sorted()
            .joined(separator: "|")

        // Which adapters the MCP section will cover. A question that names an app is
        // answered with that app's tools alone; a question that names none fans out to
        // every enabled adapter. Decided here rather than inside the loop below, because
        // the answer is part of the cache identity — two questions naming different apps
        // must not share a block.
        let normalizedQuery = query.lowercased()
        let explicitlyNamed = enabledAdapters.filter {
            normalizedQuery.contains($0.appName.lowercased())
                || normalizedQuery.contains($0.bundleId.lowercased())
        }
        let adapters = explicitlyNamed.isEmpty ? enabledAdapters : explicitlyNamed
        let cacheKey =
            allowlistFingerprint + "##"
            + adapters.map(\.bundleId).sorted().joined(separator: ",")
        // Retrieved evidence for THIS question, not just an inventory of what exists.
        // The inventory says which apps are installed; this says which cached menu command,
        // history entry, recent document or indexed file actually matches what was asked —
        // and that grounding is what stops the model answering app questions from memory.
        // Ranked best-first, capped per source, and appended last so it sits closest to the
        // question in the prompt.
        Self.log.notice("hub: evidence")
        let evidenceLines = await Self.withTimeout(seconds: 5, fallback: [String]()) {
            await GeneralChatLocalEvidence.promptLines(query: query)
        }
        Self.log.notice("hub: inventory")
        let inventoryLines = appInventoryLines()
            + discoveryLines
            + targetedSkillLines(query: query, scope: scope)
            + evidenceLines
        if let cachedBlock,
            cachedKey == cacheKey,
            Date().timeIntervalSince(cachedAt) < cacheTTL
        {
            let block = withInventory(
                cacheFreshnessLine() + "\n" + joinedBlock(cachedBlock, builtinLines: builtinLines),
                inventoryLines: inventoryLines
            )
            return AIContextBudget.fitReference(
                compact ? compacted(block) : block, budget: characterBudget)
        }

        Self.log.notice("hub: mcp servers")
        // Per-server caps do not bound the loop: three unreachable servers cost three
        // timeouts in series, which is how a turn spent two and a half minutes here.
        let mcpDeadline = Date().addingTimeInterval(10)
        var mcpLines: [String] = []
        // Apps exposing a query-style tool (search/find/list/get/query/read). These are the
        // fan-out / "which app?" targets for broad discovery questions that name no app.
        var searchableApps: [(name: String, bundleId: String, tools: [String])] = []
        let searchVerbs = ["search", "find", "list", "query", "get", "read", "lookup", "fetch"]
        for adapter in adapters {
            guard Date() < mcpDeadline else {
                Self.log.notice("hub: mcp budget spent, skipping the rest")
                break
            }
            guard !MCPServerManager.shared.servers(forBundleId: adapter.bundleId).isEmpty else {
                continue
            }
            // Bounded: `tools(forBundleId:)` may spawn a server process and wait on its
            // handshake. One server that never answers used to hold the whole chat at
            // "Looking for MCP and app tools…" with no way out. A server that is too slow
            // to answer is treated as a server with no tools.
            Self.log.notice("hub: asking \(adapter.appName, privacy: .public)")
            let tools = await Self.withTimeout(
                seconds: 6,
                fallback: [(server: String, serverId: UUID, tool: MCPTool)]()
            ) {
                await MCPRuntime.shared.tools(forBundleId: adapter.bundleId)
            }
            guard !tools.isEmpty else { continue }
            mcpLines.append("### \(adapter.appName) (\(adapter.bundleId))")
            for entry in tools.prefix(16) {
                let desc = entry.tool.description.isEmpty
                    ? "" : " — \(String(entry.tool.description.prefix(140)))"
                mcpLines.append("- server \"\(entry.server)\", tool \"\(entry.tool.name)\"\(desc)")
            }
            let queryTools = tools
                .map(\.tool.name)
                .filter { name in
                    let lower = name.lowercased()
                    return searchVerbs.contains { lower.contains($0) }
                }
            if !queryTools.isEmpty {
                searchableApps.append(
                    (adapter.appName, adapter.bundleId, Array(queryTools.prefix(4))))
            }
        }

        Self.log.notice("hub: saved chats")
        Self.log.notice("hub: mcp loop done")
        let historyApps = savedChatApps()
        let historyLines = historyApps.map { "- \($0.appName) (\($0.bundleId))" }

        guard !mcpLines.isEmpty || !historyLines.isEmpty || !builtinLines.isEmpty
            || !inventoryLines.isEmpty
        else {
            cachedBlock = ""
            cachedAt = Date()
            cachedKey = cacheKey
            return ""
        }

        var lines: [String] = [
            "## App Tools (available in General Chat)",
            "You CAN access the user's installed apps through the tools below — even in",
            "General Chat. When the user asks about one of these apps, call its tool instead",
            "of saying you lack access. Never claim you cannot access an app listed here.",
            "",
            "To call an app's MCP tool, reply with ONLY one line of JSON and nothing else:",
            "{\"mcp_call\": {\"app\": \"<bundleId>\", \"server\": \"<server>\", \"tool\": \"<tool>\", \"arguments\": { … }}}",
            "",
            "To read the user's saved conversation history with an app (past app-scoped chats",
            "in this launcher), reply with ONLY:",
            "{\"app_chat_history\": {\"app\": \"<bundleId or app name>\"}}",
            "",
            "After the tool result returns, answer the user's actual question in plain language.",
            "If the user asks \"how many\", count the items in the result.",
            "",
            "Planning rules:",
            "- Prefer real DoraX routes over generic advice: app adapter/native actions, built-in capabilities, MCP tools, API/Shortcuts, native share, cached app menus, then CLI fallback, then launch/activate.",
            // Deliberately "when one FITS", not "when one EXISTS". The stronger phrasing was
            // enforced in code for a while: run_command was refused whenever the scoped app
            // had any adapter action at all, so "what is the recent commit I did?" was
            // rejected in favour of ~40 scraped VS Code menu items, none of which can show a
            // git log. Preferring a native route is right; refusing the shell when no native
            // route answers the question is not.
            "- Prefer an adapter/native capability, MCP tool, API connection, Shortcut or verified menu route when one FITS the request. When none of them can actually answer it, use run_command — that is what it is for, and saying you have no access is wrong when a shell command would work.",
            "- If a request names or implies an app, check the installed/running/app-adapter/menu inventory below before answering.",
            "- If execution is needed, explain the route and let DoraX approval run it; do not pretend the task is complete before approval/executor success.",
            "- Never ask for Accessibility, Vision, current-page, or app-context permission in chat text. DoraX presents native approval UI before verified context is supplied. If context is absent, state which detail was unavailable.",
            "- If the user asks to share/send to an app, use native macOS sharing or the app adapter route; do not invent a manual copy/paste workflow.",
            // The original rule ended "NEVER suggest grep / the working directory / shell —
            // you are DoraX, not a coding agent." The intent is right: "where did I save Y"
            // should search the user's apps, not grep a directory that has nothing to do
            // with the question. But as an absolute it also forbade the shell for questions
            // only the shell can answer, which is how a git question became "I don't have
            // access". Keep the priority, drop the prohibition.
            "- DISCOVERY queries that name NO app (\"do any of my apps have X\", \"where did I save Y\", \"any links stored anywhere\"): NEVER answer that you lack access. Search the user's apps first — call the query tool of each relevant app under \"Searchable apps\" below and combine the results — because that is where their content lives, not in whatever directory happens to be current. If several apps could match and fanning out is too broad, ask which of those specific apps to search (name them). Fall back to run_command only when the question is genuinely about the file system or a repository.",
        ]
        if !searchableApps.isEmpty {
            lines.append("")
            lines.append("Searchable apps (call these query tools to answer discovery questions):")
            for app in searchableApps.prefix(20) {
                lines.append(
                    "- \(app.name) (\(app.bundleId)): \(app.tools.joined(separator: ", "))")
            }
        }
        if !mcpLines.isEmpty {
            lines.append("")
            lines.append("Apps with live MCP tools:")
            lines.append(contentsOf: mcpLines)
        }
        if !historyLines.isEmpty {
            lines.append("")
            lines.append("Apps with saved chat history (readable via app_chat_history):")
            lines.append(contentsOf: historyLines)
        }

        let block = lines.joined(separator: "\n")
        cachedBlock = block
        cachedAt = Date()
        cachedKey = cacheKey
        let full = withInventory(
            cacheFreshnessLine() + "\n" + joinedBlock(block, builtinLines: builtinLines),
            inventoryLines: inventoryLines
        )
        return AIContextBudget.fitReference(
            compact ? compacted(full) : full, budget: characterBudget)
    }

    /// Lines describing enabled built-in capabilities (Notes/Calendar/Contacts/Reminders/
    /// GitHub) — callable with server "builtin" through the same mcp_call JSON. Also
    /// names the DISABLED families so the model suggests enabling them instead of
    /// claiming it has no access.
    private func builtInCapabilityLines() -> [String] {
        let families: [(prefix: String, name: String, flag: String)] = [
            ("notes.", "Apple Notes", "noteMCPEnabled"),
            ("calendar.", "Calendar", "calendarMCPEnabled"),
            ("contacts.", "Contacts", "contactsMCPEnabled"),
            ("reminders.", "Reminders", "remindersMCPEnabled"),
            ("messages.", "Messages", "messagesMCPEnabled"),
            ("github.", "GitHub (gh CLI)", "githubMCPEnabled"),
        ]
        // Advertise every registered capability, not a hand-maintained subset.
        //
        // This used to filter to the six `families` prefixes above, which meant a capability
        // could be registered, executable through this very hub, and still invisible to the
        // model. git.status / git.log / git.diff / git.branches were the clearest case:
        // fully wired, dispatchable by id, and never mentioned — so "what is the recent
        // commit I did?" was answered with "no information available" by a model that had
        // the tool all along and no way to know it.
        //
        // `families` is kept, but only for the DISABLED-integrations notice below, which is
        // genuinely about user-facing toggles. What the model is allowed to know about is
        // now derived from the registry, so registering a capability is all it takes to make
        // it callable.
        //
        // The app-bundle check stays: a capability belonging to an app with no installed
        // adapter cannot run, and advertising it would invite a call that must fail.
        let caps = CapabilityRegistry.shared.all.filter { cap in
            guard let bundleID = cap.appBundleID else { return true }
            return AppAdapterManager.shared.adapter(for: bundleID) != nil
        }
        let disabledNames = families
            .filter { family in !caps.contains { $0.id.hasPrefix(family.prefix) } }
            .map(\.name)

        var lines: [String] = []
        if !caps.isEmpty {
            lines.append("")
            lines.append("Built-in tools (call with server \"builtin\", no app needed):")
            lines.append(
                "These tools mean you are NOT limited to the local file system or shell — "
                + "never claim you cannot access an app whose tools are listed here.")
            for cap in caps {
                let fields = cap.inputSchema.fields
                    .map { "\($0.name)\($0.required ? "" : "?")" }
                    .joined(separator: ", ")
                lines.append("- tool \"\(cap.id)\": \(cap.title) | input: [\(fields)]")
            }
        }
        if !disabledNames.isEmpty {
            lines.append("")
            lines.append(
                "Built-in integrations currently DISABLED: \(disabledNames.joined(separator: ", ")). "
                + "When the user asks about these apps, do NOT say you lack access — tell them to "
                + "flip the built-in toggle in Settings → App Adapters → that app → Tools tab.")
        }
        return lines
    }

    private func appInventoryLines() -> [String] {
        let installed = InstalledApplicationsCatalog.cachedInstalledApps()
        let runningBundleIds = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let frontmostBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let adapters = AppAdapterManager.shared.adapters.filter(\.isEnabled)
        let adapterByBundle = Dictionary(uniqueKeysWithValues: adapters.map { ($0.bundleId, $0) })
        let menuSummaries = AppMenuCapabilityCache.shared.summaries()
        let menuSummaryByBundle = Dictionary(uniqueKeysWithValues: menuSummaries.map {
            ($0.bundleIdentifier, $0)
        })
        let skills = SkillStore.shared.skills.filter(\.isEnabled)
        let skillCounts = Dictionary(grouping: skills, by: \.adapterBundleId).mapValues(\.count)
        let mcpCounts = Dictionary(grouping: MCPServerManager.shared.servers.flatMap { server in
            server.bundleIds.map { (bundleId: $0, server: server) }
        }, by: \.bundleId).mapValues(\.count)

        // Inventory is broader than authority: running/frontmost apps and cached menus help
        // General AI understand what the user means and which DoraX routes exist. An enabled
        // App Adapter remains the hard gate for app reads and execution.
        var importantBundleIds = Set<String>()
        importantBundleIds.formUnion(runningBundleIds)
        importantBundleIds.formUnion(adapterByBundle.keys)
        importantBundleIds.formUnion(menuSummaryByBundle.keys)
        importantBundleIds.formUnion(skillCounts.keys)
        if let frontmostBundleId { importantBundleIds.insert(frontmostBundleId) }

        let installedByBundle = Dictionary(uniqueKeysWithValues: installed.map { ($0.bundleId, $0) })
        let ordered = importantBundleIds.compactMap { bundleId -> (name: String, bundleId: String)? in
            if let entry = installedByBundle[bundleId] { return (entry.name, bundleId) }
            if let adapter = adapterByBundle[bundleId] { return (adapter.appName, bundleId) }
            if let summary = menuSummaryByBundle[bundleId] { return (summary.appName, bundleId) }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                return (FileManager.default.displayName(atPath: url.path)
                    .replacingOccurrences(of: ".app", with: ""), bundleId)
            }
            return nil
        }
        .sorted {
            if $0.bundleId == frontmostBundleId { return true }
            if $1.bundleId == frontmostBundleId { return false }
            let lhsRunning = runningBundleIds.contains($0.bundleId)
            let rhsRunning = runningBundleIds.contains($1.bundleId)
            if lhsRunning != rhsRunning { return lhsRunning }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        let mediaInfo = MediaInfoProvider.shared.getNowPlayingSourceInfo()
        let mediaBundleId = mediaInfo.bundleID
        let mediaDisplayName = MediaPlayerObserver.shared.appName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let observerMediaApp = MediaPlayerObserver.shared.appName
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var lines: [String] = [
            "- App access is allowlisted by enabled App Adapters: \(adapterByBundle.count) app(s) available.",
            "- Inventory entries without an enabled adapter are awareness-only: never read their private data or execute their routes; explain that the app must be added in Settings → App Adapters.",
            "- AX/Vision inspection is available only for allowlisted apps and only after user approval unless content was explicitly attached.",
        ]
        if let frontmostBundleId,
           let frontmost = ordered.first(where: { $0.bundleId == frontmostBundleId }) {
            let access = adapterByBundle[frontmostBundleId] == nil
                ? "awareness only; not added to App Adapters"
                : "available through App Adapters"
            lines.append("- Frontmost app now: \(frontmost.name) (\(frontmost.bundleId)); \(access).")
        }

        lines.append("Running app status snapshot:")
        for app in ordered.prefix(28) {
            var bits: [String] = []
            if app.bundleId == frontmostBundleId { bits.append("frontmost") }
            if runningBundleIds.contains(app.bundleId) { bits.append("running") }
            if adapterByBundle[app.bundleId] == nil {
                bits.append("awareness only — not added to App Adapters")
            }
            if let adapter = adapterByBundle[app.bundleId] {
                let actions = adapter.visibleActions.count
                bits.append("\(actions) adapter action\(actions == 1 ? "" : "s")")
                let readers = adapter.contextReaders.count
                if readers > 0 {
                    bits.append("\(readers) adapter reader\(readers == 1 ? "" : "s")")
                }
            }
            if let count = mcpCounts[app.bundleId], count > 0 {
                bits.append("\(count) MCP server\(count == 1 ? "" : "s")")
            }
            if let count = skillCounts[app.bundleId], count > 0 {
                bits.append("\(count) skill\(count == 1 ? "" : "s")")
            }
            if let summary = menuSummaryByBundle[app.bundleId] {
                bits.append("\(summary.recordCount) cached menu command\(summary.recordCount == 1 ? "" : "s")")
            }
            if app.bundleId == mediaBundleId
                || (!mediaDisplayName.isEmpty
                    && mediaDisplayName.localizedCaseInsensitiveContains(app.name))
                || (!observerMediaApp.isEmpty
                    && app.name.localizedCaseInsensitiveContains(observerMediaApp)) {
                let title = (mediaInfo.title ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    bits.append("media \(mediaInfo.playbackRate > 0 ? "playing" : "paused"): \(title)")
                } else {
                    bits.append("media source")
                }
            }
            if runningBundleIds.contains(app.bundleId) {
                bits.append("AX/Vision available with approval")
            }
            guard !bits.isEmpty else { continue }
            lines.append("- \(app.name) (\(app.bundleId)): \(bits.joined(separator: "; ")).")
        }
        return lines
    }

    /// Skills are executable guidance only for the app explicitly named by the user. Never
    /// dump every imported skill into the system-wide prompt: that creates cross-app prompt
    /// bleed and lets an unrelated adapter steer a selection-only conversation.
    private func targetedSkillLines(query: String, scope: AIConversationScope) -> [String] {
        let normalized = query.lowercased()
        let targets = AppAdapterManager.shared.adapters.filter {
            $0.isEnabled && (normalized.contains($0.appName.lowercased())
                || normalized.contains($0.bundleId.lowercased()))
        }
        guard !targets.isEmpty else { return [] }
        let heading: String
        if case .selection = scope {
            heading = "Selection-safe targeted app skills (instructions only; transform only explicit selected payload; never read app state or grant tool permission):"
        } else {
            heading = "Targeted app skills (instructions only; never grant tool permission):"
        }
        var lines = [heading]
        for adapter in targets.prefix(3) {
            let block = SkillStore.shared.instructionsBlock(for: adapter.bundleId)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !block.isEmpty else { continue }
            lines.append("<app-skill bundle=\"\(adapter.bundleId)\">")
            lines.append(String(block.prefix(4_000)))
            lines.append("</app-skill>")
        }
        return lines.count == 1 ? [] : lines
    }

    private func cacheFreshnessLine() -> String {
        let age = max(0, Date().timeIntervalSince(cachedAt))
        if cachedAt == .distantPast || age < 1 {
            return "Capability cache freshness: fresh now; live toggles and built-ins are read every message."
        }
        let remaining = max(0, cacheTTL - age)
        return "Capability cache freshness: \(Int(age))s old; refreshes in \(Int(remaining))s; live toggles and built-ins are read every message."
    }

    private func joinedBlock(_ base: String, builtinLines: [String]) -> String {
        if builtinLines.isEmpty { return base }
        if base.isEmpty {
            let header = [
                "## App Tools (available in General Chat)",
                "To call a tool, reply with ONLY one line of JSON and nothing else:",
                "{\"mcp_call\": {\"server\": \"builtin\", \"tool\": \"<tool>\", \"arguments\": { … }}}",
                "After the tool result returns, answer the user's question in plain language.",
                "Use DoraX app/menu/share/adapter capabilities when the user names or implies an app.",
            ]
            return (header + builtinLines).joined(separator: "\n")
        }
        return base + "\n" + builtinLines.joined(separator: "\n")
    }

    private func withInventory(_ base: String, inventoryLines: [String]) -> String {
        guard !inventoryLines.isEmpty else { return base }
        let inventoryBlock = ([
            "## Running App Status Snapshot",
        ] + inventoryLines).joined(separator: "\n")
        guard !base.isEmpty else {
            return inventoryBlock
        }
        return inventoryBlock + "\n\n" + base
    }

    private func compacted(_ block: String) -> String {
        // On-device models have a small context window — keep the catalog lean.
        String(block.prefix(3_000))
    }

    // MARK: - Execution

    struct ToolCallResult {
        let handled: Bool
        let success: Bool
        let output: String
        /// Human-readable chip label, e.g. "search_items via Artifacts"
        let label: String
    }

    /// Dispatch a tool command the model emitted through the tool loop.
    /// Returns handled=false when the command is not an app tool call (caller falls back
    /// to the terminal bridge or treats the text as the final answer).
    func execute(_ command: String, scope: AIConversationScope) async -> ToolCallResult {
        guard let invocation = AITypedInvocationResolver.invocation(from: command) else {
            return ToolCallResult(handled: false, success: false, output: "", label: "")
        }

        switch invocation.kind {
        case .mcp:
            let tool = invocation.capabilityID
            let server = invocation.arguments["server"] ?? ""
            let arguments = decodeInvocationArguments(invocation)
            let appRef = invocation.arguments["bundleId"] ?? invocation.arguments["bundleID"] ?? ""
            // Built-in capability ids (notes.search, calendar.today, …) win over MCP
            // server tools — there is no overlap in practice.
            if CapabilityRegistry.shared.capability(id: tool) != nil {
                if let appBundleID = CapabilityRegistry.shared.capability(id: tool)?.appBundleID,
                    AppAdapterManager.shared.adapter(for: appBundleID) == nil
                {
                    return ToolCallResult(
                        handled: true, success: false,
                        output: "That app isn’t added to App Adapters, so General AI cannot use \(tool).",
                        label: "\(tool) blocked")
                }
                let input = arguments.mapValues { value in String(describing: value) }
                let plan = AIActionPlan(
                    capability: tool, input: input, explanation: "Requested from AI chat")
                do {
                    try CapabilityAuthorizationGate.validatePlan(plan, scope: scope)
                } catch {
                    return ToolCallResult(
                        handled: true, success: false,
                        output: error.localizedDescription,
                        label: "\(tool) blocked")
                }
                let result = await AIExecutionEngine.shared.executeUnifiedWithApproval(
                    plan, context: .none)
                return ToolCallResult(
                    handled: true,
                    success: result.success,
                    output: result.success
                        ? result.output + "\n\nVerification: \(result.verification.displayName)."
                        : "Tool \(tool) failed: \(result.error ?? "Unknown error")",
                    label: "\(tool) via built-in")
            }
            guard let bundleId = resolveBundleId(appRef: appRef, serverName: server) else {
                return ToolCallResult(
                    handled: true, success: false,
                    output: "No app adapter matches \"\(appRef)\" / server \"\(server)\".",
                    label: tool)
            }
            var resolvedArguments = invocation.arguments
            resolvedArguments["bundleId"] = bundleId
            let resolvedInvocation = AITypedInvocation(
                kind: invocation.kind,
                capabilityID: invocation.capabilityID,
                arguments: resolvedArguments,
                requiresApproval: invocation.requiresApproval
            )
            do {
                try CapabilityAuthorizationGate.validateInvocation(resolvedInvocation, scope: scope)
            } catch {
                return ToolCallResult(
                    handled: true, success: false,
                    output: error.localizedDescription,
                    label: "\(tool) blocked")
            }
            guard MCPToolSafety.isClearlyReadOnly(name: tool) else {
                return ToolCallResult(
                    handled: true, success: false,
                    output: "MCP tool \(tool) is classified as write/unknown risk. Provider-authored MCP mutations require a deterministic app capability with user approval.",
                    label: "\(tool) blocked")
            }
            let label = "\(tool) via \(displayName(forBundleId: bundleId))"
            do {
                let result = try await MCPRuntime.shared.callProviderReadOnlyTool(
                    bundleId: bundleId, server: server, tool: tool, arguments: arguments)
                return ToolCallResult(handled: true, success: true, output: result, label: label)
            } catch {
                return ToolCallResult(
                    handled: true, success: false,
                    output: "MCP tool \(tool) failed: \(error.localizedDescription)",
                    label: label)
            }

        case .capability where invocation.capabilityID == "app.chatHistory.read":
            let appRef = invocation.arguments["bundleId"] ?? invocation.arguments["bundleID"] ?? ""
            let bundleId = resolveChatHistoryBundleId(appRef: appRef) ?? appRef
            var resolvedArguments = invocation.arguments
            resolvedArguments["bundleId"] = bundleId
            let resolvedInvocation = AITypedInvocation(
                kind: invocation.kind,
                capabilityID: invocation.capabilityID,
                arguments: resolvedArguments,
                requiresApproval: invocation.requiresApproval
            )
            do {
                try CapabilityAuthorizationGate.validateInvocation(resolvedInvocation, scope: scope)
            } catch {
                return ToolCallResult(
                    handled: true, success: false,
                    output: error.localizedDescription,
                    label: "chat history blocked")
            }
            return ToolCallResult(
                handled: true, success: true,
                output: chatHistoryText(for: bundleId),
                label: "chat history: \(displayName(forBundleId: bundleId))")

        case .capability:
            let plan = AIActionPlan(
                capability: invocation.capabilityID,
                input: invocation.arguments,
                explanation: "Requested from AI chat"
            )
            do {
                try CapabilityAuthorizationGate.validateInvocation(invocation, scope: scope)
                try CapabilityAuthorizationGate.validatePlan(plan, scope: scope)
            } catch {
                return ToolCallResult(
                    handled: true, success: false,
                    output: error.localizedDescription,
                    label: "\(invocation.capabilityID) blocked")
            }
            let result = await AIExecutionEngine.shared.executeUnifiedWithApproval(plan, context: .none)
            return ToolCallResult(
                handled: true,
                success: result.success,
                output: result.success
                    ? result.output + "\n\nVerification: \(result.verification.displayName)."
                    : "\(invocation.capabilityID) failed: \(result.error ?? "Unknown error")",
                label: invocation.capabilityID)

        case .adapterAction:
            let actionId = invocation.arguments["actionId"] ?? ""
            let bundleId = invocation.arguments["bundleId"] ?? invocation.arguments["bundleID"] ?? ""
            guard !bundleId.isEmpty,
                let adapter = AppAdapterManager.shared.adapter(for: bundleId),
                let action = adapter.actions.first(where: { $0.id == actionId })
            else {
                return ToolCallResult(
                    handled: true, success: false,
                    output: "No adapter action '\(actionId)' is installed for that app. "
                        + "Add it in Settings → App Adapters.",
                    label: "adapter blocked")
            }
            let (ok, out) = await AppAdapterManager.shared.execute(
                action, context: AXContextReader.shared.current,
                targetBundleId: bundleId, query: invocation.arguments["query"] ?? "")
            return ToolCallResult(
                handled: true, success: ok,
                output: out.isEmpty ? "Ran \(action.name)" : out,
                label: "\(action.name) via adapter")

        case .menuAction:
            let path = (invocation.arguments["path"] ?? "")
                .components(separatedBy: "\u{1F}")
                .filter { !$0.isEmpty }
            let bundleId = invocation.arguments["bundleId"]
                ?? invocation.arguments["bundleID"]
                ?? AXContextReader.shared.current.bundleId
            guard !path.isEmpty, !bundleId.isEmpty else {
                return ToolCallResult(
                    handled: true, success: false,
                    output: "No menu path or app given for the menu command.",
                    label: "menu blocked")
            }
            let (ok, out) = await AppAdapterManager.shared.runMenuPath(
                path, targetBundleId: bundleId,
                appName: AXContextReader.shared.current.appName)
            return ToolCallResult(
                handled: true, success: ok,
                output: out.isEmpty ? "Ran \(path.joined(separator: " ▸ "))" : out,
                label: "\(path.joined(separator: " ▸ ")) via menu")

        case .terminal:
            let plan = AIActionPlan(
                capability: "terminal.runCommand",
                input: invocation.arguments,
                explanation: "Requested from AI chat"
            )
            do {
                try CapabilityAuthorizationGate.validateInvocation(invocation, scope: scope)
                try CapabilityAuthorizationGate.validatePlan(plan, scope: scope)
            } catch {
                return ToolCallResult(
                    handled: true, success: false,
                    output: error.localizedDescription,
                    label: "terminal blocked")
            }
            let result = await AIExecutionEngine.shared.executeUnifiedWithApproval(plan, context: .none)
            return ToolCallResult(
                handled: true,
                success: result.success,
                output: result.success
                    ? result.output + "\n\nVerification: \(result.verification.displayName)."
                    : "Terminal command failed: \(result.error ?? "Unknown error")",
                label: "Terminal")

        case .share:
            do {
                try CapabilityAuthorizationGate.validateInvocation(invocation, scope: scope)
            } catch {
                return ToolCallResult(
                    handled: true, success: false,
                    output: error.localizedDescription,
                    label: "share blocked")
            }
            return ToolCallResult(
                handled: false, success: false, output: "", label: "")
        }
    }

    // MARK: - Chat history

    private struct SavedChatApp {
        let bundleId: String
        let appName: String
    }

    private func savedChatApps() -> [SavedChatApp] {
        AppPanelChatStore.shared.allPanelKeys()
            .filter { $0.hasPrefix(chatPanelKeyPrefix) }
            .map { String($0.dropFirst(chatPanelKeyPrefix.count)) }
            .filter { AppAdapterManager.shared.adapter(for: $0) != nil }
            .map { SavedChatApp(bundleId: $0, appName: displayName(forBundleId: $0)) }
    }

    private func chatHistoryText(for appRef: String) -> String {
        guard let bundleId = resolveChatHistoryBundleId(appRef: appRef) else {
            return "No saved chat history found for \"\(appRef)\"."
        }
        guard AppAdapterManager.shared.adapter(for: bundleId) != nil else {
            return "That app isn’t added to App Adapters, so General AI cannot read its saved app chat."
        }
        let messages = AppPanelChatStore.shared.load(for: chatPanelKeyPrefix + bundleId)
        guard !messages.isEmpty else {
            return "No saved chat history found for \(displayName(forBundleId: bundleId))."
        }
        let lines = messages.suffix(30).map { msg -> String in
            let role: String
            switch msg.role {
            case .user: role = "user"
            case .tool: role = "tool"
            default: role = "assistant"
            }
            return "\(role): \(String(msg.content.prefix(400)))"
        }
        return "Saved chat history with \(displayName(forBundleId: bundleId)) "
            + "(last \(lines.count) messages):\n" + lines.joined(separator: "\n")
    }

    // MARK: - Resolution helpers

    private func resolveBundleId(appRef: String, serverName: String) -> String? {
        let ref = appRef.trimmingCharacters(in: .whitespacesAndNewlines)
        let adapters = AppAdapterManager.shared.adapters.filter { $0.isEnabled }
        if !ref.isEmpty {
            if let exact = adapters.first(where: {
                $0.bundleId.caseInsensitiveCompare(ref) == .orderedSame
            }) { return exact.bundleId }
            if let byName = adapters.first(where: {
                $0.appName.caseInsensitiveCompare(ref) == .orderedSame
            }) { return byName.bundleId }
            // Singular/plural + partial-name tolerance ("artifact" → "Artifacts")
            let lowerRef = ref.lowercased()
            if let loose = adapters.first(where: {
                let name = $0.appName.lowercased()
                return name.contains(lowerRef) || lowerRef.contains(name)
                    || name.hasPrefix(lowerRef) || lowerRef.hasPrefix(name)
            }) { return loose.bundleId }
            // Bundle id the model produced but no adapter exists — still try it directly
            // if any MCP server is linked to it.
            if !MCPServerManager.shared.servers(forBundleId: ref).isEmpty { return ref }
        }
        // Fall back: the adapter whose linked servers contain the named server.
        if !serverName.isEmpty {
            for adapter in adapters {
                let servers = MCPServerManager.shared.servers(forBundleId: adapter.bundleId)
                if servers.contains(where: { $0.name.caseInsensitiveCompare(serverName) == .orderedSame }) {
                    return adapter.bundleId
                }
            }
        }
        return nil
    }

    private func resolveChatHistoryBundleId(appRef: String) -> String? {
        let ref = appRef.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !ref.isEmpty else { return nil }
        let saved = savedChatApps()
        if let exact = saved.first(where: { $0.bundleId.lowercased() == ref }) {
            return exact.bundleId
        }
        if let byName = saved.first(where: { $0.appName.lowercased() == ref }) {
            return byName.bundleId
        }
        // Loose match: "notes" → com.apple.Notes
        return saved.first(where: {
            $0.appName.lowercased().contains(ref) || $0.bundleId.lowercased().contains(ref)
        })?.bundleId
    }

    private func displayName(forBundleId bundleId: String) -> String {
        if let adapter = AppAdapterManager.shared.adapters.first(where: {
            $0.bundleId.caseInsensitiveCompare(bundleId) == .orderedSame
        }) { return adapter.appName }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        return bundleId.components(separatedBy: ".").last ?? bundleId
    }

    private func decodeInvocationArguments(_ invocation: AITypedInvocation) -> [String: Any] {
        guard let json = invocation.arguments["argumentsJSON"],
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }
}
