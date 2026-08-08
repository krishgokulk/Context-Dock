// AppScopedChatService.swift
// Context-Dock
//
// One request path for a conversation scoped to an app or a CLI tool, wherever it is
// being held — the dock's frontmost/scoped chat or the chat window's thread.
//
// The window used to ask the provider with `sendMessage` and no grounding at all, so the
// same question answered well in the dock and badly in the window. The difference was
// never the surface: it was that the dock assembled the app's adapters, cached menu
// commands, MCP tools and linked CLIs into the prompt, and gave the model tools to run,
// while the window sent the bare question. That assembly lives here now.

import AppKit
import Foundation
import OSLog

@MainActor
enum AppScopedChatService {

    /// Stage markers for a scoped send. A stall in this path is invisible from the UI —
    /// the thread just says "Thinking…" — so each stage is logged and readable with
    /// `log show --predicate 'subsystem == "com.krishgokul.ContextDock"'`.
    private static let log = Logger(
        subsystem: "com.krishgokul.ContextDock", category: "AppScopedChat")

    struct Answer {
        let text: String
        /// What actually ran, for the receipt chips — derived from execution, never from
        /// words in the question.
        let toolChips: [String]
        /// Set when the question is about an app this chat may not read. The surface shows
        /// it as a one-tap "Enable <app> for this chat" button.
        var enableApp: EnableAppRequest? = nil
        /// Set when several routes could carry out the request and they differ in
        /// consequence. The surface shows them as pick-one buttons.
        var routeChoices: [ActionChoice] = []
        /// Raw output of a route that ran, for the Console panel.
        var consoleOutput: String? = nil
    }

    /// Routes offered for the last question, by choice id, so a pick can be executed
    /// without re-resolving (and without the resolution having drifted in between).
    private(set) static var pendingRoutes: [String: ChatRoute] = [:]

    /// Runs a route the user picked, then has the model phrase the result. The output is
    /// returned verbatim as well, because a receipt the user can read beats a summary they
    /// have to trust.
    static func runChosenRoute(
        _ choiceID: String, query: String, history: [ChatMessage]
    ) async -> Answer {
        guard let route = pendingRoutes[choiceID] else {
            return Answer(text: "That route is no longer available.", toolChips: [])
        }
        ChatRoutePreferenceStore.remember(
            route.kind, bundleId: route.bundleId, query: query)
        return await execute(route: route, query: query, history: history)
    }

    private static func execute(
        route: ChatRoute, query: String, history: [ChatMessage]
    ) async -> Answer {
        // A skill is instructions, not a command: it is carried out by answering with the
        // user's own workflow foregrounded, in the scope it was written for.
        if route.kind == .skill {
            let instructions = SkillStore.shared.skills(for: route.bundleId)
                .first { $0.id == route.payload }
                .map { "## Skill: \($0.name)\n\($0.instructions)" } ?? ""
            ChatConsoleLog.shared.append(
                .tool, title: "skill · \(route.title)", output: instructions,
                success: !instructions.isEmpty,
                scope: .app(bundleId: route.bundleId))
            let answer = try? await send(
                scope: .app(bundleId: route.bundleId),
                appName: route.appName,
                query: query,
                history: history,
                skillOverride: instructions)
            return answer
                ?? Answer(text: "Couldn't apply \(route.title).", toolChips: [])
        }

        log.notice("route: \(route.kind.rawValue, privacy: .public) \(route.title, privacy: .public)")
        let routeScope = GeneralChatScope.app(bundleId: route.bundleId)
        let rowID = ChatConsoleLog.shared.begin(.route, title: route.title, scope: routeScope)
        let result = await ChatRouteResolver.run(route, query: query)
        ChatConsoleLog.shared.finish(
            rowID,
            output: result.output.isEmpty
                ? (result.success ? "(no output)" : "(failed, no output)") : result.output,
            success: result.success,
            scope: routeScope)

        let settings = AppSettings.shared
        let provider = settings.selectedAIProvider
        let rawKey = provider.requiresAPIKey ? settings.getAPIKey(for: provider) : ""
        // Verification, not narration. An action that changed something is checked by
        // reading the app back, so the answer reports what is true rather than what was
        // attempted.
        var verification: String?
        if result.success, !route.isReadOnly {
            try? await Task.sleep(nanoseconds: 400_000_000)  // let the app settle
            verification = ContextResolver
                .resolve(scope: routeScope, appName: route.appName)
                .promptBlock()
            if let verification {
                ChatConsoleLog.shared.append(
                    .note,
                    title: "verified \(route.appName) state",
                    output: verification,
                    success: true,
                    scope: routeScope)
            }
        }

        let phrased: String
        if !result.success {
            // Say what happened rather than handing the model an empty result to narrate.
            // A denied command answered as "the current page information is unavailable"
            // told the user nothing about the denial that caused it.
            let reason = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            phrased = reason.isEmpty
                ? "`\(route.title)` didn't run."
                : "`\(route.title)` didn't run — \(reason)"
        } else if result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            phrased = verification.map { "Done — \(route.title).\n\n\($0)" }
                ?? "Done — \(route.title)."
        } else {
            // The model turns output into an answer; it never invents one, because the
            // output is right there beside it in the Console.
            phrased =
                (try? await AIProviderService.shared.sendMessage(
                    "Ran `\(route.title)` for \(route.appName). Output:\n\n"
                        + result.output.prefix(6_000)
                        + (verification.map { "\n\nState afterwards:\n\($0)" } ?? "")
                        + "\n\nAnswer the user's question from this output only: \(query)",
                    context: .appFocused(name: route.appName, bundleID: route.bundleId),
                    provider: provider,
                    apiKey: rawKey.isEmpty ? nil : rawKey,
                    conversationHistory: history,
                    surfaceScoped: true))
                .map(ChatAnswerSanitizer.clean)
                ?? result.output
        }
        return Answer(
            text: phrased,
            toolChips: ["\(route.kind.rawValue) · \(route.title)"],
            consoleOutput: result.output.isEmpty ? nil : result.output)
    }

    /// Adds a plural form of every word alongside the original, so a query written in the
    /// singular still matches an app whose name is plural.
    private static func pluralised(_ query: String) -> String {
        query
            .split(separator: " ")
            .map { word -> String in
                let text = String(word)
                guard text.count > 3, !text.hasSuffix("s") else { return text }
                return "\(text) \(text)s"
            }
            .joined(separator: " ")
    }

    /// The app named in a question that this chat has no access to, if any.
    ///
    /// Selection is the access boundary: General Chat reads only the apps the user chose,
    /// so a question about an app outside that set is answered by asking, not by reaching
    /// into it. The dock has always done this; the window went straight to the model, which
    /// then tried tools it had no grant for and reported a failure the user could not act on.
    static func appNeedingAccess(
        query: String, scope: GeneralChatScope, attachedAppNames: [String]
    ) -> EnableAppRequest? {
        guard case .general = scope else { return nil }
        // "do i have any reminder today" names Reminders, but the resolver matches whole
        // words against app names, so the singular missed and the question fell through to
        // a model with no access and no explanation. Try the plural too.
        let named =
            GeneralAIActionResolver.shared.namedInstalledApp(in: query)
            ?? GeneralAIActionResolver.shared.namedInstalledApp(in: pluralised(query))
        guard let named else { return nil }
        // Match on the name first. Resolving an attached name to a bundle id depends on
        // the app running or on a warmed installed-apps cache, and when neither held, an
        // app the user had just enabled looked unattached — so the gate asked again, and
        // again, with the Enable button doing nothing each time.
        if attachedAppNames.contains(where: {
            $0.caseInsensitiveCompare(named.name) == .orderedSame
        }) { return nil }

        let attachedBundleIDs = Set(
            attachedAppNames.compactMap { name -> String? in
                NSWorkspace.shared.runningApplications
                    .first { $0.localizedName == name }?.bundleIdentifier
                    ?? InstalledApplicationsCatalog.cachedInstalledApps()
                    .first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.bundleId
            }.map { $0.lowercased() })
        guard !attachedBundleIDs.contains(named.bundleId.lowercased()) else { return nil }
        return EnableAppRequest(name: named.name, bundleId: named.bundleId, query: query)
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

    // MARK: - Shared context blocks

    /// Today's date and time, in the model's prompt. A chat that cannot resolve "today"
    /// answers calendar and reminder questions against nothing.
    static func dateTimeBlock() -> String {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        let localDateTime = formatter.string(from: now)
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = .current
        let isoDateTime = isoFormatter.string(from: now)

        return """
            CURRENT DATE & TIME:
            - Local: \(localDateTime)
            - ISO 8601: \(isoDateTime)
            - Time Zone: \(TimeZone.current.identifier)
            Use this exact date/time for relative time references like today, yesterday, tomorrow, recent, and this week.
            """
    }

    /// What the app has open right now, read from its own accessibility element rather
    /// than from whichever app the last global snapshot belongs to.
    nonisolated static func liveWindowFacts(bundleID: String) -> String? {
        guard let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first,
            running.processIdentifier > 0
        else { return nil }

        let appElement = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 1.0)

        func string(_ element: AXUIElement, _ attribute: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
            else { return nil }
            if let text = value as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return nil
        }

        var lines: [String] = []

        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &focused) == .success,
            let window = focused as! AXUIElement?
        {
            if let title = string(window, kAXTitleAttribute as String) {
                lines.append("Front window title: \(title)")
            }
            if let document = string(window, kAXDocumentAttribute as String) {
                lines.append("Open document: \(URL(string: document)?.path ?? document)")
            }
        }

        var windowsValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
            let windows = windowsValue as? [AXUIElement], !windows.isEmpty
        {
            let titles = windows.prefix(8).compactMap { string($0, kAXTitleAttribute as String) }
            if titles.count > 1 {
                lines.append("Open windows (\(windows.count)): " + titles.joined(separator: ", "))
            }
        }

        guard !lines.isEmpty else { return nil }
        return "Live window state (read just now, factual):\n" + lines.joined(separator: "\n")
    }

    /// The page a browser scope is currently on. "What page am I on?" is answerable from
    /// the browser itself; without this the window had the app's capability list and no
    /// idea what was open in it, so it offered to reload a page it could not name.
    static func browserPageFacts(bundleID: String) -> String? {
        guard ScopedAppPromptBuilder.isBrowserBundle(bundleID) else { return nil }
        let detector = ContextDetector.shared
        switch bundleID {
        case "com.apple.Safari":
            if let page = detector.getSafariPageContextForAI() {
                return "Current page (read just now, factual):\n\(page)"
            }
            if let page = detector.getSafariContext() {
                return "Current page (read just now, factual):\nTitle: \(page.title)\nURL: \(page.url)"
            }
        case "com.google.Chrome":
            if let page = detector.getChromeContext() {
                return "Current page (read just now, factual):\nTitle: \(page.title)\nURL: \(page.url)"
            }
        case "company.thebrowser.Browser":
            if let page = detector.getArcContext() {
                return "Current page (read just now, factual):\nTitle: \(page.title)\nURL: \(page.url)"
            }
        default:
            break
        }
        return nil
    }

    /// Recent history for a browser scope, and an honest account of where it came from.
    ///
    /// The library reads Safari's History.db directly, which needs Full Disk Access. Without
    /// it the read returns nothing and the answer became "no visits in that time range" —
    /// which is false, and unfixable by the user because nothing said what was wrong. The
    /// app's own History menu is already cached, so it stands in when the database cannot
    /// be read.
    static func browserHistoryFacts(bundleID: String, appName: String) -> String? {
        guard ScopedAppPromptBuilder.isBrowserBundle(bundleID) else { return nil }

        let menuItems = AppMenuCapabilityCache.shared.menuItems(
            bundleIdentifier: bundleID, appName: appName, query: "History", maxResults: 40)
        let historyEntries = menuItems
            .filter { $0.isLeaf && $0.path.first == "History" }
            .map { $0.path.last ?? "" }
            .filter { title in
                !title.isEmpty
                    && !["Show Personal History", "Back", "Forward", "Home", "Clear History…",
                         "Reopen Last Closed Window", "Reopen All Windows from Last Session",
                         "Return to Search Results"].contains(title)
            }

        var lines: [String] = []
        if !historyEntries.isEmpty {
            let age = AppMenuCapabilityCache.shared.snapshotAge(bundleIdentifier: bundleID)
            let readWhen = age.map { "read \(Int($0 / 60)) min ago" } ?? "from the menu cache"
            lines.append("## \(appName) — History menu (\(readWhen), factual)")
            lines.append(
                "These are the entries in \(appName)'s own History menu. They are real visits, "
                + "in most-recent-first order, though the menu carries no timestamps.")
            lines += historyEntries.prefix(25).map { "- \($0)" }
        }

        // Say when the fuller source is unavailable, so an incomplete answer is not
        // mistaken for an empty history.
        if bundleID == "com.apple.Safari" {
            let dbPath = NSHomeDirectory() + "/Library/Safari/History.db"
            if !FileManager.default.isReadableFile(atPath: dbPath) {
                lines.append(
                    "Safari's full history database is not readable — DoraX needs Full Disk "
                    + "Access in System Settings → Privacy & Security to read dated history. "
                    + "Say that plainly if the user asks about a date range; do not report "
                    + "an empty history.")
            }
        }

        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: - Request

    /// Asks the provider about an app or CLI scope with the grounding above, and lets it
    /// run what it finds. Commands still go through TerminalCommandExecutor, so approval
    /// behaves exactly as it does in the dock — a different window is not a reason to
    /// lower a gate.
    static func send(
        scope: GeneralChatScope,
        appName: String,
        query: String,
        history: [ChatMessage],
        attachments: [URL] = [],
        extraAppNames: [String] = [],
        /// A skill the user chose for this request. Present means the route decision is
        /// already made, so the picker is skipped rather than asked again.
        skillOverride: String? = nil
    ) async throws -> Answer {
        let settings = AppSettings.shared
        let provider = settings.selectedAIProvider
        let rawKey = provider.requiresAPIKey ? settings.getAPIKey(for: provider) : ""
        let apiKey: String? = rawKey.isEmpty ? nil : rawKey

        log.notice("send start scope=\(scope.storageKey, privacy: .public) provider=\(provider.rawValue, privacy: .public)")

        // Ask before reaching. This also runs before any tool or capability work, so a
        // question about an app outside the chat's scope can never stall on a tool it was
        // never allowed to use.
        if let request = appNeedingAccess(
            query: query, scope: scope, attachedAppNames: extraAppNames)
        {
            log.notice("stage: access gate — \(request.bundleId, privacy: .public)")
            return Answer(
                text:
                    "**\(request.name)** isn't in this chat's scope yet. General Chat only reads "
                    + "the apps you choose, so you stay in control — enable it below to let me "
                    + "answer about \(request.name).",
                toolChips: [],
                enableApp: request)
        }
        // A request that spans apps gets a plan rather than a route. Candidates are
        // resolved across every app this chat may touch, so the ordering the model does is
        // ordering of real capabilities — not an improvisation it then narrates.
        if ChatRouteResolver.isActionRequest(query) {
            var crossAppRoutes: [ChatRoute] = []
            var scopeApps: [(String, String)] = []
            if case .app(let bundleId) = scope { scopeApps.append((bundleId, appName)) }
            for name in extraAppNames {
                let bundleId =
                    NSWorkspace.shared.runningApplications
                    .first { $0.localizedName == name }?.bundleIdentifier
                    ?? InstalledApplicationsCatalog.cachedInstalledApps()
                    .first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.bundleId
                if let bundleId { scopeApps.append((bundleId, name)) }
            }
            if scopeApps.count > 1 {
                for (bundleId, name) in scopeApps {
                    crossAppRoutes += await ChatRouteResolver.routes(
                        for: query, bundleId: bundleId, appName: name)
                }
                if crossAppRoutes.count > 1,
                    let plan = await ChatPlanRunner.plan(
                        query: query, routes: crossAppRoutes,
                        provider: provider, apiKey: apiKey)
                {
                    log.notice("stage: plan of \(plan.steps.count, privacy: .public) steps")
                    let results = await ChatPlanRunner.run(plan, query: query)
                    let receipt = ChatPlanRunner.receipt(plan, results: results)
                    let allSucceeded = results.allSatisfy(\.success)
                        && results.count == plan.steps.count
                    return Answer(
                        text: (allSucceeded ? "\(plan.summary)\n\n" : "")
                            + receipt
                            + (allSucceeded
                                ? ""
                                : "\n\nNothing after the failed step was attempted."),
                        toolChips: results.map { "\($0.step.route.kind.rawValue) · \($0.step.route.title)" })
                }
            }
        }

        // Which routes could actually carry this out, resolved before the model is asked
        // anything. Asking the user which to use is only worth it when they differ in
        // consequence — that check is in the resolver.
        if case .app(let bundleId) = scope, skillOverride == nil {
            let routes = await ChatRouteResolver.routes(
                for: query, bundleId: bundleId, appName: appName)
            if ChatRouteResolver.shouldAsk(routes: routes, bundleId: bundleId, query: query) {
                pendingRoutes = Dictionary(
                    uniqueKeysWithValues: routes.map { ($0.id, $0) })
                log.notice("stage: asking which route (\(routes.count, privacy: .public))")
                return Answer(
                    text:
                        "\(appName) can do that more than one way. Which should I use?",
                    toolChips: [],
                    routeChoices: routes.map(\.asActionChoice))
            }
            // Already answered for this app and this kind of request: take that route
            // without asking again.
            if let preferred = ChatRoutePreferenceStore.preferredKind(
                bundleId: bundleId, query: query),
                let route = routes.first(where: { $0.kind == preferred })
            {
                return await execute(route: route, query: query, history: history)
            }
            // Deterministic before probabilistic: a read the app can answer itself beats
            // sending the question to a model with a catalogue and hoping it picks well.
            if let route = ChatRouteResolver.unattendedRoute(routes) {
                log.notice("stage: unattended route \(route.kind.rawValue, privacy: .public)")
                return await execute(route: route, query: query, history: history)
            }
        }

        if case .cli(let command) = scope {
            let routes = ChatRouteResolver.cliRoutes(for: query, command: command)
            if ChatRouteResolver.shouldAsk(
                routes: routes, bundleId: "cli://\(command)", query: query)
            {
                pendingRoutes = Dictionary(uniqueKeysWithValues: routes.map { ($0.id, $0) })
                log.notice("stage: asking which invocation (\(routes.count, privacy: .public))")
                return Answer(
                    text: "There's more than one \(command) command for that. Which should I run?",
                    toolChips: [],
                    routeChoices: routes.map(\.asActionChoice))
            }
            // A single read-only invocation is just the answer: run it and report.
            if routes.count == 1, let route = routes.first, route.isReadOnly {
                return await execute(route: route, query: query, history: history)
            }
        }

        var sections: [String] = [dateTimeBlock()]
        var context: UserContext = .none
        /// The machine as it was before this turn ran anything, kept so a tool's claim can
        /// be checked against what actually changed.
        var contextBefore: ResolvedContext?

        switch scope {
        case .app(let bundleId):
            context = .appFocused(name: appName, bundleID: bundleId)
            sections.append(
                """
                This conversation is scoped to \(appName) (\(bundleId)). Answer about that app, \
                using the verified context and capabilities below. If a detail is not in the \
                supplied context, say DoraX could not read it — never answer from generic \
                product knowledge and never claim you lack access to an app listed here.
                """)
            // Resolved once, with its gaps recorded: an answer that could not know
            // something now says which slot was empty instead of inventing a value.
            let resolved = ContextResolver.resolve(scope: scope, appName: appName)
            contextBefore = resolved
            let block = resolved.promptBlock()
            if !block.isEmpty { sections.append(block) }
            log.notice("context \(resolved.summary, privacy: .public)")
            if let history = browserHistoryFacts(bundleID: bundleId, appName: appName) {
                sections.append(history)
            }
            // The same block the dock builds for its scoped chat — adapter actions, menu
            // commands, MCP, API, Shortcuts, skills, CLI, and the tool-choice order.
            let capabilities = ScopedAppPromptBuilder.appIdentityBlock(
                bundleId: bundleId, appName: appName, query: query)
            if !capabilities.isEmpty { sections.append(capabilities) }
            // The app's enabled skills, in full. The identity block only counts them, and
            // a Calendar chat that is told "2 skills active" without their instructions
            // behaves differently from the dock's, which reads them.
            // A chosen skill replaces the full set: the user said which workflow applies,
            // and stacking the others behind it would dilute the instruction they picked.
            let skills = skillOverride ?? SkillStore.shared.instructionsBlock(for: bundleId)
            if !skills.isEmpty { sections.append(skills) }
            // The app's live MCP tools, in the prose protocol the loop understands, so a
            // Reminders thread can read reminders instead of describing how to.
            log.notice("stage: mcp block")
            let mcpBlock = await withTimeout(seconds: 6, fallback: "") {
                await MCPRuntime.shared.toolPromptBlock(forBundleId: bundleId)
            }
            if !mcpBlock.isEmpty { sections.append(mcpBlock) }

        case .cli(let command):
            let resolved = ContextResolver.resolve(scope: scope, appName: command)
            let resolvedBlock = resolved.promptBlock()
            if !resolvedBlock.isEmpty { sections.append(resolvedBlock) }
            log.notice("context \(resolved.summary, privacy: .public)")
            let tool = ScopedAppPromptBuilder.appIdentityBlock(
                bundleId: "cli://\(command)", appName: command, query: query)
            if !tool.isEmpty { sections.append(tool) }

        case .general:
            // Unscoped chat is not ungrounded chat: it still answers about the user's
            // machine, so it gets the same capability catalogue the dock's General Chat
            // builds. Without it the model was handed a CLI protocol by the provider's
            // package matcher and nothing that could run it.
            sections.append(
                """
                You are DoraX's assistant on the user's Mac. Use the capabilities listed \
                below to answer from real data rather than from memory. Never print a tool \
                call as text — call it, then answer in plain language.
                """)
        }

        // A combined chat is scoped to several apps; each one is grounded the same way.
        for name in extraAppNames {
            let bundleId =
                NSWorkspace.shared.runningApplications
                .first { $0.localizedName == name }?.bundleIdentifier
                ?? InstalledApplicationsCatalog.cachedInstalledApps()
                .first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.bundleId
            guard let bundleId else { continue }
            let block = ScopedAppPromptBuilder.appIdentityBlock(
                bundleId: bundleId, appName: name, query: query, compact: true)
            if !block.isEmpty { sections.append(block) }
            if let facts = liveWindowFacts(bundleID: bundleId) { sections.append(facts) }
        }

        // Real Calendar / Reminders / Notes / Contacts data when the question is about
        // them — the dock's "Live app data" read. Without it the model has the app's
        // capability list and none of its contents, which is why the window could only
        // explain how to look rather than answer.
        log.notice("stage: live apple data")
        let liveAppleData = await withTimeout(seconds: 8, fallback: "") {
            await AppleLiveDataContext.appleAppsAndWeatherContext(for: query)
        }
        if !liveAppleData.isEmpty { sections.append(liveAppleData) }

        // Registered capabilities, MCP tools and skills — the same block General Chat uses.
        // A CLI thread is one executable. The cross-app catalogue is noise there — and
        // building it means walking every linked MCP server, which is where these turns
        // were dying: a scope that needs none of it was paying for all of it.
        let needsCrossAppCatalogue: Bool = {
            if case .cli = scope { return false }
            return true
        }()

        log.notice("stage: capability hub (\(needsCrossAppCatalogue ? "yes" : "skipped", privacy: .public))")
        let hubBlock = !needsCrossAppCatalogue ? "" : await withTimeout(seconds: 8, fallback: "") {
            await GeneralChatCapabilityHub.shared.capabilityPromptBlock(
                compact: provider == .onDevice,
                query: query,
                scope: .general,
                characterBudget: AIContextBudget.characterBudget(for: provider))
        }
        if !hubBlock.isEmpty { sections.append(hubBlock) }

        let systemPrompt = sections.joined(separator: "\n\n")
        log.notice("stage: prompt ready (\(systemPrompt.count, privacy: .public) chars)")

        // Apple Intelligence has no function-calling API, so it takes the plain path.
        guard provider.supportsNativeTools else {
            let raw = try await AIProviderService.shared.sendMessage(
                query,
                context: context,
                provider: provider,
                apiKey: apiKey,
                conversationHistory: history,
                additionalContextPrompt: systemPrompt,
                attachments: attachments.map(AIAttachment.inferred(from:)),
                // This surface supplies its own capability catalogue; letting the provider
                // also match a CLI package teaches a [TERMINAL_COMMAND: …] protocol that
                // nothing here executes, and the directive ends up printed at the user.
                surfaceScoped: true
            )
            let text = ChatAnswerSanitizer.clean(raw)
            return Answer(
                text: text,
                toolChips: liveAppleData.isEmpty ? [] : ["Live app data · just now"])
        }

        let executor: (String, String, Bool) async -> (Bool, String) = {
            command, purpose, needsApproval in
            // The row is opened before the command runs and closed when it returns — that is
            // what tells the user a slow tool is working rather than dead. Done inside the
            // executor rather than here, so the dock's commands land on the same record.
            await TerminalCommandExecutor.shared.run(
                command, purpose: purpose, modelRequiresApproval: needsApproval,
                consoleScope: scope)
        }

        log.notice("stage: provider sendWithTools")
        var (text, executed) = try await AIProviderService.shared.sendWithTools(
            query,
            context: context,
            provider: provider,
            apiKey: apiKey,
            conversationHistory: history,
            commandExecutor: executor,
            additionalSystemPrompt: systemPrompt,
            imageAttachments: attachments
        )
        log.notice("stage: answer received (\(text.count, privacy: .public) chars, \(executed.count, privacy: .public) commands)")

        // Verification for the tool loop. Anything that was not clearly read-only gets the
        // scope read back and compared: a tool that reports success while nothing on the
        // machine moved is the failure mode worth catching, and it cannot be caught by
        // reading the model's own summary of itself.
        if let contextBefore,
            case .app = scope,
            executed.contains(where: { !MCPToolSafety.isClearlyReadOnly(name: $0.command) })
        {
            try? await Task.sleep(nanoseconds: 400_000_000)
            let after = ContextResolver.resolve(scope: scope, appName: appName)
            let changes = after.changes(since: contextBefore)
            ChatConsoleLog.shared.append(
                .note,
                title: "verified \(appName) state",
                output: changes.isEmpty
                    ? "No observable change." : changes.joined(separator: "\n"),
                success: !changes.isEmpty,
                scope: scope)
            if changes.isEmpty {
                text +=
                    "\n\n_Nothing observable changed in \(appName) — if you expected it to, "
                    + "the action may not have taken effect._"
            }
        }

        // The model sometimes writes its tool call out as text instead of calling it. The
        // dock recovers by running it; the window used to render the JSON. One recovery
        // round only — a model that keeps narrating tool calls is not going to stop.
        if let call = ChatAnswerSanitizer.terminalCall(in: text) {
            log.notice("stage: recovering prose terminal_call")
            let result = await TerminalCommandExecutor.shared.run(
                call.command, purpose: call.purpose, modelRequiresApproval: false)
            if result.success {
                let followUp = try await AIProviderService.shared.sendMessage(
                    "Command output:\n\n\(result.output.prefix(6_000))\n\nAnswer the original "
                        + "question from this output: \(query)",
                    context: context,
                    provider: provider,
                    apiKey: apiKey,
                    conversationHistory: history,
                    surfaceScoped: true
                )
                text = followUp
                executed.append(
                    AIProviderService.ExecutedCommand(
                        command: call.command, output: result.output, success: true))
            }
        }
        text = ChatAnswerSanitizer.clean(text)

        // Everything the model ran during this turn, on the record with its real output.
        // The chips say a tool ran; the console says what it produced, which is the part
        // a user can check.
        // Tool calls the loop made without going through our executor — capabilities, MCP,
        // registry tools. Shell commands are already on the record, live, from the executor
        // above, so they are not written twice.
        let alreadyLogged = Set(
            ChatConsoleLog.shared.entries(for: scope).map(\.title))
        for command in executed where !alreadyLogged.contains(command.command) {
            ChatConsoleLog.shared.append(
                .tool,
                title: command.command,
                output: command.output,
                success: command.success,
                scope: scope)
        }

        var chips = executed.map(\.command)
        if !liveAppleData.isEmpty { chips.insert("Live app data · just now", at: 0) }
        return Answer(text: text, toolChips: chips)
    }
}
