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

@MainActor
enum AppScopedChatService {

    struct Answer {
        let text: String
        /// What actually ran, for the receipt chips — derived from execution, never from
        /// words in the question.
        let toolChips: [String]
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

        case .cli(let command):
            let tool = ScopedAppPromptBuilder.appIdentityBlock(
                bundleId: "cli://\(command)", appName: command, query: query)
            if !tool.isEmpty { sections.append(tool) }

        case .general:
            break
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

        // Registered capabilities, MCP tools and skills — the same block General Chat uses.
        let hubBlock = await GeneralChatCapabilityHub.shared.capabilityPromptBlock(
            compact: provider == .onDevice,
            query: query,
            scope: .general,
            characterBudget: AIContextBudget.characterBudget(for: provider))
        if !hubBlock.isEmpty { sections.append(hubBlock) }

        let systemPrompt = sections.joined(separator: "\n\n")

        // Apple Intelligence has no function-calling API, so it takes the plain path.
        guard provider.supportsNativeTools else {
            let text = try await AIProviderService.shared.sendMessage(
                query,
                context: context,
                provider: provider,
                apiKey: apiKey,
                conversationHistory: history,
                additionalContextPrompt: systemPrompt,
                attachments: attachments.map(AIAttachment.inferred(from:))
            )
            return Answer(text: text, toolChips: [])
        }

        let executor: (String, String, Bool) async -> (Bool, String) = {
            command, purpose, needsApproval in
            await TerminalCommandExecutor.shared.run(
                command, purpose: purpose, modelRequiresApproval: needsApproval)
        }

        let (text, executed) = try await AIProviderService.shared.sendWithTools(
            query,
            context: context,
            provider: provider,
            apiKey: apiKey,
            conversationHistory: history,
            commandExecutor: executor,
            additionalSystemPrompt: systemPrompt,
            imageAttachments: attachments
        )
        return Answer(text: text, toolChips: executed.map(\.command))
    }
}
