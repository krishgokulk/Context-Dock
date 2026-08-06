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
        guard let named = GeneralAIActionResolver.shared.namedInstalledApp(in: query)
        else { return nil }
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

    /// Every context read below can block: an MCP server spawns and handshakes, EventKit
    /// waits on a database, a capability discovery walks the disk. One of them stalling
    /// must cost a section of the prompt, never the answer — a spinner with no end is the
    /// worst outcome of the three.
    static func withTimeout<T: Sendable>(
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
        extraAppNames: [String] = []
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
        var sections: [String] = [dateTimeBlock()]
        var context: UserContext = .none

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
            if let facts = liveWindowFacts(bundleID: bundleId) { sections.append(facts) }
            // The same block the dock builds for its scoped chat — adapter actions, menu
            // commands, MCP, API, Shortcuts, skills, CLI, and the tool-choice order.
            let capabilities = ScopedAppPromptBuilder.appIdentityBlock(
                bundleId: bundleId, appName: appName, query: query)
            if !capabilities.isEmpty { sections.append(capabilities) }
            // The app's enabled skills, in full. The identity block only counts them, and
            // a Calendar chat that is told "2 skills active" without their instructions
            // behaves differently from the dock's, which reads them.
            let skills = SkillStore.shared.instructionsBlock(for: bundleId)
            if !skills.isEmpty { sections.append(skills) }
            // The app's live MCP tools, in the prose protocol the loop understands, so a
            // Reminders thread can read reminders instead of describing how to.
            log.notice("stage: mcp block")
            let mcpBlock = await withTimeout(seconds: 6, fallback: "") {
                await MCPRuntime.shared.toolPromptBlock(forBundleId: bundleId)
            }
            if !mcpBlock.isEmpty { sections.append(mcpBlock) }

        case .cli(let command):
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
        log.notice("stage: capability hub")
        let hubBlock = await withTimeout(seconds: 8, fallback: "") {
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
            await TerminalCommandExecutor.shared.run(
                command, purpose: purpose, modelRequiresApproval: needsApproval)
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

        var chips = executed.map(\.command)
        if !liveAppleData.isEmpty { chips.insert("Live app data · just now", at: 0) }
        return Answer(text: text, toolChips: chips)
    }
}
