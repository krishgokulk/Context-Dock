import AddressBook
import AppIntents
import AppKit
import Contacts
import Foundation
import FoundationModels
import PDFKit
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers
import Vision

private enum GeneralAIChatConversationStore {
    private static let key = "dorax.generalAI.currentConversation.v1"

    private struct StoredAppLaunch: Codable {
        let label: String
        let systemIcon: String
        let bundleId: String
    }

    private struct StoredMessage: Codable {
        let role: String
        let content: String
        let isError: Bool
        let structuredData: String?
        let hasInstallButton: Bool
        let attachments: [String]
        let appLaunches: [StoredAppLaunch]
        let mcpToolsRan: [String]
    }

    static func load() -> [AIChatMessage] {
        guard let data = UserDefaults.standard.data(forKey: key),
            let stored = try? JSONDecoder().decode([StoredMessage].self, from: data)
        else { return [] }

        return stored.map { item in
            AIChatMessage(
                role: role(from: item.role),
                content: item.content,
                isError: item.isError,
                structuredData: item.structuredData,
                hasInstallButton: item.hasInstallButton,
                attachments: item.attachments.map(URL.init(fileURLWithPath:)),
                appLaunches: item.appLaunches.map {
                    AppLaunchAction(
                        label: $0.label,
                        systemIcon: $0.systemIcon,
                        bundleId: $0.bundleId
                    )
                },
                mcpToolsRan: item.mcpToolsRan
            )
        }
    }

    static func save(_ messages: [AIChatMessage]) {
        let stored = messages.map { message in
            StoredMessage(
                role: roleString(message.role),
                content: message.content,
                isError: message.isError,
                structuredData: message.structuredData,
                hasInstallButton: message.hasInstallButton,
                attachments: message.attachments.map(\.path),
                appLaunches: message.appLaunches.map {
                    StoredAppLaunch(
                        label: $0.label,
                        systemIcon: $0.systemIcon,
                        bundleId: $0.bundleId
                    )
                },
                mcpToolsRan: message.mcpToolsRan
            )
        }
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func roleString(_ role: AIChatMessage.ChatRole) -> String {
        switch role {
        case .user: return "user"
        case .assistant: return "assistant"
        case .tool: return "tool"
        case .approval: return "approval"
        }
    }

    private static func role(from raw: String) -> AIChatMessage.ChatRole {
        switch raw {
        case "user": return .user
        case "tool": return .tool
        case "approval": return .approval
        default: return .assistant
        }
    }
}

extension LauncherView {
    var isCLIToolScopeLocked: Bool {
        currentGlobalScopedBundleID?.hasPrefix("cli://") == true
    }

    var shouldShowContextDockChatButton: Bool {
        showContextInDock
            && !showMediaLayer
            && !aiMode.isActive
            && !isCompactSmartScope
            && (l2.chatArmed || l2.showChatPopover || frontmost.bundleID != "com.apple.finder")
    }

    var isContextDockChatConnected: Bool {
        l2.chatArmed || l2.showChatPopover
    }

    /// A frontmost-app chat owns the dock: the conversation is bound to the app it was
    /// started for and must survive app switches, Space switches and focus loss. Only an
    /// explicit exit (Escape, backspace, the `−` chip, Clear) ends it. Menu search — this
    /// property false — keeps following the frontmost app as usual.
    var isContextDockChatLocked: Bool {
        showContextInDock
            && !showMediaLayer
            && !aiMode.isActive
            && !isGlobalContextActive
            && !l2.chatDismissed
            && (l2.chatArmed || l2.showChatPopover || l2.isLoading || !l2.chatMessages.isEmpty)
            // A chat auto-armed only because a query matched no menu item is not a session
            // the user started — it must not pin the dock to an app.
            && !(l2.chatAutoArmedForNoMenuMatch && l2.chatMessages.isEmpty && !l2.isLoading)
    }

    /// Single writer for `AppDelegate.scopeChatSpaceHold`. Every state change that can
    /// start or end a scope / scoped chat routes through here, so the hold can never be
    /// left stale (dock stuck across Spaces) or cleared mid-chat (dock vanishes on click).
    func syncScopeChatSpaceHold() {
        AppDelegate.shared?.scopeChatSpaceHold =
            currentGlobalScopedBundleID != nil || isContextDockChatLocked
    }

    /// Stores the measured intrinsic height of the active chat conversation and re-fits the window
    /// so the sheet exactly matches the content (no clipped messages, no empty box).
    func updateMeasuredChatContentHeight(_ height: CGFloat) {
        let clamped = max(0, height)
        // Ignore the transient ~0 the geometry reader emits while the chat view unmounts
        // (e.g. leaving general chat for Global Context). Resetting to 0 makes a later
        // re-entry size to the 60px floor first, then jump to the real height. The
        // message-count gate in DockHeightResolver still collapses the window on Clear.
        guard clamped > 1 else { return }
        guard abs(measuredChatContentHeight - clamped) > 1 else { return }
        // Animate the chat-area frame with the SAME curve/duration the window resize
        // uses (easeOut 0.18) so the sheet and window grow/shrink as one motion — not a
        // snap-then-resize. The measured value is the messages' intrinsic height, so
        // animating the frame can't feed back into the measurement.
        withAnimation(.easeOut(duration: 0.18)) {
            measuredChatContentHeight = clamped
        }
        requestWindowSizeUpdate(reason: .chatChanged, animated: true)
    }

    var isContextDockChatRoutingLocked: Bool {
        showContextInDock
            && !showMediaLayer
            && !aiMode.isActive
            && (l2.chatArmed || l2.showChatPopover)
            // No-menu fallback inside a Global running-app scope is still an input
            // routing state, not a surface transition. Keep Global Context mounted
            // until Enter submits; remounting the TextField here resurrects stale text.
            && !isGlobalScopedNoMenuChatComposerArmed
    }

    var isGlobalScopedNoMenuChatComposerArmed: Bool {
        isGlobalContextActive
            && currentGlobalScopedChatTarget != nil
            && l2.chatArmed
            && l2.chatAutoArmedForNoMenuMatch
            && !l2.showChatPopover
            && !l2.isLoading
            && l2.chatMessages.isEmpty
    }

    var shouldShowContextDockChatSheet: Bool {
        showContextInDock
            && !showMediaLayer
            && !l2.chatDismissed
            && (l2.showChatPopover || l2.isLoading || !l2.chatMessages.isEmpty)
    }

    var contextDockBrowserBundleIDs: Set<String> {
        [
            "com.apple.Safari",
            "com.google.Chrome",
            "com.brave.Browser",
            "org.chromium.Chromium",
            "com.microsoft.edgemac",
        ]
    }

    var currentContextDockChatScope: (bundleId: String, appName: String) {
        let targetBundle = l2.targetApp?.bundleId.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let targetName = l2.targetApp?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !targetBundle.isEmpty {
            return (targetBundle, targetName.isEmpty ? contextDockChatDraftAppName : targetName)
        }

        let draftBundle = l2.chatDraftBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        let draftName = l2.chatDraftAppName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !draftBundle.isEmpty {
            return (draftBundle, draftName.isEmpty ? contextDockChatDraftAppName : draftName)
        }

        return (frontmost.bundleID, frontmost.name.isEmpty ? "this app" : frontmost.name)
    }

    func isContextDockBrowserBundle(_ bundleId: String) -> Bool {
        let trimmed = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        // Safari Web Apps (YouTube, YT Music, …) are browsers too — they render a
        // web page and expose its URL via AX, so they get full browser-scope context.
        return contextDockBrowserBundleIDs.contains(trimmed)
            || trimmed.hasPrefix("com.apple.Safari.WebApp")
    }

    func sanitizedConversationContextForScope(
        _ context: UserContext,
        scopedBundleId: String,
        scopedAppName: String
    ) -> UserContext {
        guard !scopedBundleId.isEmpty, !isContextDockBrowserBundle(scopedBundleId) else {
            return context
        }
        if case .url = context {
            return .appFocused(
                name: scopedAppName.isEmpty ? contextDockChatDraftAppName : scopedAppName,
                bundleID: scopedBundleId
            )
        }
        return context
    }

    func sanitizedAXContextForScope(_ context: AXContext, scopedBundleId: String) -> AXContext {
        guard !scopedBundleId.isEmpty, !isContextDockBrowserBundle(scopedBundleId) else {
            return context
        }
        var sanitized = context
        sanitized.currentURL = nil
        return sanitized
    }

    func currentScopedConversationContext() -> UserContext {
        let scope = currentContextDockChatScope
        return sanitizedConversationContextForScope(
            effectiveConversationUserContext,
            scopedBundleId: scope.bundleId,
            scopedAppName: scope.appName
        )
    }

    /// Live current-page context block for a browser scope, injected into the L2
    /// context so EVERY provider (HTTP, on-device, Shortcuts) sees the page — its
    /// URL, text and selection — without needing a tool to read it.
    ///
    /// Source priority: the Safari Web Extension payload (richest, reliable URL,
    /// 8 000-char page text, no automation prompt), then the AX snapshot when the
    /// extension is not enabled. Returns "" when not a browser or no data.
    @MainActor
    func browserScopeContextBlock(scopedBundleId: String) -> String {
        let bundle = scopedBundleId.isEmpty ? frontmost.bundleID : scopedBundleId
        guard isContextDockBrowserBundle(bundle) else { return "" }

        var pageTitle = ""
        var pageURL = ""
        var pageText = ""
        var selected = ""

        // 1) Safari Web Extension payload — preferred when fresh.
        if SafariBrowserBridge.shared.isFresh,
            let ext = SafariBrowserBridge.shared.currentContext() {
            pageTitle = ext.title
            pageURL = ext.url
            pageText = ext.pageTextForAI
            selected = ext.selectedText
        }

        // 2) AX snapshot fallback (extension disabled, or other browser).
        if pageText.isEmpty, let browser = AppDelegate.shared?.previousFrontmostApp {
            let pid = browser.processIdentifier
            let liveURL = currentBrowserPageURL()?.absoluteString ?? ""
            var snap = AXWebReader.shared.cachedSnapshot(for: pid)
            if (snap?.text.isEmpty != false || snap?.isStale == true), !liveURL.isEmpty {
                AXWebReader.shared.refresh(pid: pid, currentURL: liveURL)
                snap = AXWebReader.shared.cachedSnapshot(for: pid)
            }
            pageText = snap?.text ?? ""
            if pageURL.isEmpty { pageURL = (snap?.url.isEmpty == false) ? (snap?.url ?? liveURL) : liveURL }
            if pageTitle.isEmpty { pageTitle = snap?.title ?? "" }
        }

        guard !pageText.isEmpty || !pageURL.isEmpty else { return "" }
        let selectedSection = selected.isEmpty
            ? "" : "\nSELECTED TEXT:\n\(String(selected.prefix(1500)))"
        return """
            CURRENT PAGE TITLE: \(pageTitle.isEmpty ? "(unknown)" : pageTitle)
            CURRENT PAGE URL: \(pageURL.isEmpty ? "(unknown)" : pageURL)\(selectedSection)
            \(pageText.isEmpty
                ? "PAGE TEXT: (unavailable — could not read the page)"
                : "PAGE TEXT EXCERPT:\n\(String(pageText.prefix(5000)))")
            """
    }

    /// Identity + integration inventory for the scoped app. ALWAYS injected into
    /// scoped chat so the model knows which app it serves, what the app is, and
    /// every tool it may pick (actions, CLI, MCP, API, shortcuts) — or what to
    /// suggest adding when nothing fits.
    @MainActor
    func scopedAppIdentityBlock(bundleId: String, appName: String) -> String {
        guard !bundleId.isEmpty || !appName.isEmpty else { return "" }

        // What kind of surface is this?
        let surface: String = {
            if bundleId.hasPrefix("com.apple.Safari.WebApp") {
                let host = currentBrowserPageURL()?.host
                    ?? webResearch.pages.last.flatMap { URL(string: $0.url)?.host }
                return "a Safari Web App (the website \(host ?? "it wraps") running as a standalone app)"
            }
            if isContextDockBrowserBundle(bundleId) { return "a web browser" }
            return "a macOS app"
        }()

        var lines: [String] = [
            "## Scoped App: \(appName)\(bundleId.isEmpty ? "" : " (\(bundleId))")",
            "This chat is scoped to \(appName) — \(surface). It is the app the user is",
            "currently using. You DO know which app is open: it is \(appName).",
            "Never claim you cannot see which app is open or ask the user what app they mean.",
        ]
        let windowTitle = (axContext.bundleId == bundleId ? axContext.windowTitle : nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let windowTitle, !windowTitle.isEmpty {
            lines.append("Frontmost window title: \"\(windowTitle)\"")
        }

        // Integration inventory
        let adapter = adapterManager.adapters.first { $0.bundleId == bundleId }
        let actions = adapter?.actions ?? []
        let clis = TerminalPackageManager.shared.packages.filter {
            $0.isEnabled && $0.contextAppBundleIds.contains(bundleId)
        }
        let mcpServers = MCPServerManager.shared.servers(forBundleId: bundleId)
        let apiConns = APIConnectionStore.shared.connections(for: bundleId)
        let shortcuts = actions.filter { $0.type == .shortcut }
        let skillCount = SkillStore.shared.skills(for: bundleId).filter(\.isEnabled).count

        lines.append("")
        lines.append("Integrations linked to \(appName) (pick the best fit for each request):")
        if actions.isEmpty {
            lines.append("- Actions: none")
        } else {
            lines.append(
                "- Actions — RUN one by outputting exactly one JSON line "
                + "{\"adapter_call\":{\"actionId\":\"<id>\"}}. When a request matches an action, "
                + "CALL it immediately — do NOT describe it, do NOT ask \"would you like me to?\". "
                + "Actions marked [approval] pop a native confirmation on their own, so still just "
                + "call them. Available:")
            for a in actions.prefix(30) {
                let flag = (a.requiresApproval || a.isDestructive) ? " [approval]" : ""
                lines.append("    • \(a.id) — \(a.name)\(flag)")
            }
        }
        lines.append(
            clis.isEmpty
                ? "- CLI tools: none linked"
                : "- CLI tools (fallback only; request with typed terminal_call JSON only when no adapter/MCP/API/Shortcut/menu route fits): "
                    + clis.map { "\($0.command)\($0.isInstalled ? "" : " (not installed)")" }
                        .joined(separator: ", "))
        lines.append(
            mcpServers.isEmpty
                ? "- MCP servers: none linked"
                : "- MCP servers: " + mcpServers.map(\.name).joined(separator: ", "))
        if !apiConns.isEmpty {
            lines.append("- API connections: " + apiConns.map(\.name).joined(separator: ", "))
        }
        if !shortcuts.isEmpty {
            lines.append("- macOS Shortcuts: " + shortcuts.compactMap(\.shortcutName).joined(separator: ", "))
        }
        if skillCount > 0 {
            lines.append("- Skills: \(skillCount) active (their instructions follow below)")
        }

        // Verified menu commands — the universal control surface. Any app can be driven
        // through its own menu bar even with zero linked adapters, so this is how the chat
        // DOES things (Minimize, New Tab, Export, Close…) instead of narrating a shortcut.
        if !bundleId.isEmpty {
            let menuItems = AppMenuCapabilityCache.shared.menuItems(
                bundleIdentifier: bundleId, appName: appName, query: "", maxResults: 60)
            let leaves = menuItems.filter { $0.isLeaf && !$0.path.isEmpty }
            if !leaves.isEmpty {
                lines.append(
                    "- Menu commands — RUN one by outputting exactly one JSON line "
                    + "{\"menu_call\":{\"path\":[\"Window\",\"Minimize\"]}} using the FULL path "
                    + "below. When a request maps to a menu command, CALL it immediately — do "
                    + "NOT tell the user which keyboard shortcut to press, do NOT ask permission "
                    + "(destructive commands like Close/Quit/Delete pop their own confirmation). "
                    + "Available menu commands:")
                var seen = Set<String>()
                for item in leaves {
                    let key = item.path.joined(separator: " > ").lowercased()
                    guard seen.insert(key).inserted else { continue }
                    let shortcut = item.shortcutDisplay.map { " (\($0))" } ?? ""
                    lines.append("    • \(item.path.joined(separator: " ▸ "))\(shortcut)")
                    if seen.count >= 50 { break }
                }
            }
        }

        lines.append("")
        lines.append(
            "Tool choice order: adapter/native action → MCP tool → API/Shortcut → verified live app menu → linked CLI fallback → answer from "
            + "the live context. Terminal/CLI is last resort: use it only when this app has no adapter/native/MCP/API/Shortcut/menu route that fits the request. Never generate shell or AppleScript for an operation exposed by the scoped app's linked tools or live menu. If no linked integration or menu can do what the user asks, say what "
            + "IS possible now and suggest linking the right tool in Settings → App Adapters → "
            + "\(appName) (Tools tab: MCP, API, Shortcuts, CLI).")
        if !clis.isEmpty {
            lines.append(
                "CLI fallback rule: only when no adapter/native/MCP/API/Shortcut/menu capability fits, and a linked CLI can print the information the user wants "
                + "(status, list, current state), emit one JSON line exactly as "
                + "{\"terminal_call\":{\"command\":\"<command>\",\"purpose\":\"<reason>\"}} instead of "
                + "asking the user to provide it.")
        }
        return lines.joined(separator: "\n")
    }

    func shouldInjectAppleAppsAndWeatherContext(
        for query: String,
        scopedBundleId: String,
        scopedAppName: String
    ) -> Bool {
        if isGlobalQueryModeActive { return true }

        let bundle = scopedBundleId.lowercased()
        let appName = scopedAppName.lowercased()
        let scopedAppleApps: [(bundle: String, names: [String])] = [
            ("com.apple.ical", ["calendar"]),
            ("com.apple.reminders", ["reminders", "reminder", "todo", "to-do", "to do"]),
            ("com.apple.notes", ["notes", "note"]),
            ("com.apple.mail", ["mail", "email", "inbox"]),
            ("com.apple.photos", ["photos", "photo", "picture", "screenshot"]),
            ("com.apple.mobilesms", ["messages", "message", "imessage"]),
            ("com.apple.addressbook", ["contacts", "contact"]),
            ("com.apple.safari", ["safari", "tab", "tabs"]),
            ("com.apple.music", ["music", "song", "track", "playing"]),
        ]

        for item in scopedAppleApps {
            if bundle == item.bundle || bundle.hasPrefix(item.bundle + ".") {
                return true
            }
            if item.names.contains(where: { appName.contains($0) }) {
                return true
            }
        }

        return false
    }

    func scopedAppHasPreferredNonTerminalRoute(
        bundleId: String,
        appName: String,
        query: String
    ) -> Bool {
        let trimmedBundle = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBundle.isEmpty else { return false }

        if let adapter = AppAdapterManager.shared.adapter(for: trimmedBundle) {
            if !adapter.contextReaders.isEmpty { return true }
            if adapter.actions.contains(where: { action in
                switch action.type {
                case .cliTool, .shell:
                    return false
                default:
                    return true
                }
            }) {
                return true
            }
        }

        if !MCPServerManager.shared.servers(forBundleId: trimmedBundle).isEmpty { return true }
        if !APIConnectionStore.shared.connections(for: trimmedBundle).isEmpty { return true }

        let menuMatches = AppMenuCapabilityCache.shared.menuItems(
            bundleIdentifier: trimmedBundle,
            appName: appName,
            query: query,
            maxResults: 1
        )
        return !menuMatches.isEmpty
    }

    @MainActor
    func scopedChatMissingInternalDataAnswer(
        query: String,
        bundleId: String,
        appName: String
    ) -> String? {
        let q = query.lowercased()
        let app = appName.lowercased()
        let bundle = bundleId.lowercased()
        let isChatGPTCodexScope =
            bundle == "com.openai.codex"
            || app.contains("chatgpt")
            || app.contains("codex")
        guard isChatGPTCodexScope else { return nil }

        let asksScheduleTasks =
            ["scheduled", "schedule", "task", "tasks"].contains(where: q.contains)
            && ["yesterday", "today", "tomorrow", "week", "what"].contains(where: q.contains)
        guard asksScheduleTasks else { return nil }

        let adapter = adapterManager.adapter(for: bundleId)
        let hasReader = adapter?.contextReaders.isEmpty == false
        let hasMCP = !MCPServerManager.shared.servers(forBundleId: bundleId).isEmpty
        let hasRelevantCLI = TerminalPackageManager.shared.packages.contains { package in
            package.isEnabled
                && package.contextAppBundleIds.contains(bundleId)
                && (package.command == "codex" || package.name.lowercased().contains("codex"))
                && (package.helpText?.lowercased().contains("schedule") == true
                    || package.subcommands.contains { $0.lowercased().contains("schedule") })
        }
        guard !hasReader && !hasMCP && !hasRelevantCLI else { return nil }

        let displayName = appName.isEmpty ? "ChatGPT/Codex" : appName
        return """
            I can see this chat is scoped to \(displayName), but DoraX does not have a linked reader, MCP tool, or Codex CLI route that exposes Codex scheduled tasks yet.

            I should not answer this from Calendar. To answer it correctly, allow AX/Vision inspection of the visible Scheduled screen, or add a \(displayName) adapter reader/MCP route for scheduled tasks.
            """
    }

    var shouldShowContextDockAIQueryFallback: Bool {
        guard showContextInDock,
            !isGlobalContextActive,
            !showMediaLayer,
            !aiMode.isActive,
            !isCompactSmartScope,
            !l2.chatArmed,
            !l2.showChatPopover,
            !l2.isLoading,
            lockedFindToken == nil,
            // Finder desktop scope is file search: no matches means "no files found", never
            // an AI escalation.
            !isFinderDesktopOnlyMode
        else { return false }

        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !shouldUseFinderSearchPopover(for: q) else { return false }
        if !finderSemanticResults.isEmpty { return false }
        if shouldWaitForContextDockMenuWarmupBeforeAIFallback { return false }

        let finderSearchPopoverActive = shouldUseFinderSearchPopover(for: q)
        let pillQuery = finderSearchPopoverActive ? "" : q
        let pills = currentVisibleDockPills(for: pillQuery)
        let visible = pills.filter { !$0.isSeparator }
        if visible.isEmpty { return true }
        return visible.allSatisfy(isSearchOnlyDockPill)
    }

    var shouldWaitForContextDockMenuWarmupBeforeAIFallback: Bool {
        guard showContextInDock,
            !isGlobalContextActive,
            !showMediaLayer
        else { return false }

        let bundleId = (l2.targetApp?.bundleId ?? frontmost.bundleID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleId.isEmpty else { return false }
        return warmingMenuBundleIds.contains(bundleId)
    }

    func isSearchOnlyDockPill(_ pill: DockPill) -> Bool {
        let kind = pill.rankingKind.lowercased()
        let name = pill.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return kind == "contentsearch"
            || kind == "semanticintent"
            || pill.id.hasPrefix("content-search:")
            || pill.id.hasPrefix("browser-search:")
            || pill.id.hasPrefix("mail-search-")
            || name.hasPrefix("search ")
    }

    /// Sparkles affordance in the input while typing in Selection Scope. It marks what Enter
    /// does — Ask AI is the first row — rather than appearing only when rows are missing, which
    /// is what made it read as an auto-switch into chat.
    var shouldShowSelectionCompactAIAction: Bool {
        guard hasSelectionScopeSurface,
            !aiMode.isActive,
            !l2.isLoading,
            lockedFindToken == nil
        else { return false }
        return !searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var shouldShowCompactAIActionButton: Bool {
        shouldShowSelectionCompactAIAction || shouldShowContextDockAIQueryFallback
    }

    func runCompactAIActionFromInput() {
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        dismissMediaLayer()
        if shouldShowSelectionCompactAIAction {
            enterSelectionChat(initialQuery: q)
        } else if shouldShowContextDockAIQueryFallback {
            handleL2QuerySkippingMenuRouter(q)
        }
    }

    /// Context Dock: when a typed query matches no real menu command, auto-arm the frontmost
    /// app chat (so the bar reads "Ask <App> — press Enter to send" with just the pin icon)
    /// instead of surfacing a chat-connect icon. Guards against arming mid-resolution.
    /// Retired. A query with no menu match now surfaces an "Ask AI" row in the result sheet;
    /// arming the app chat from underneath the user swapped the whole outer shell mid-typing.
    /// Chat stays explicit — the "+" button, or running that row.
    func autoArmContextDockChatForNoMenuMatch() {}

    /// Global Context inline app scope (right-arrow into a running app, e.g. Tailscale): when
    /// the typed query filters to no real menu command, auto-arm the scoped app's chat — same
    /// "Ask <App> … Enter to send" + pin behavior as Context Dock, so the query goes to AI.
    /// Single combined trigger for both no-menu auto-arm paths, so the launcher body needs
    /// only ONE extra onChange (more chained SubscriptionViews crash SwiftUI here).
    var shouldAutoArmChatForNoMenuMatch: Bool {
        shouldShowContextDockAIQueryFallback || shouldAutoArmGlobalInlineScopeChat
    }

    var shouldAutoArmGlobalInlineScopeChat: Bool {
        guard let target = currentGlobalScopedChatTarget,
            isGlobalContextActive,
            !l2.chatArmed, !l2.showChatPopover, !l2.isLoading,
            lockedSubmenuParent == nil, lockedFindToken == nil,
            !target.bundleId.isEmpty,
            // Finder scope is FILE SEARCH, not a chat surface — having no matches means
            // "no files found", not "ask AI". Never auto-arm chat there.
            target.bundleId != "com.apple.finder",
            !isFinderDesktopOnlyMode
        else { return false }
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isResolvingDockPills(for: q.lowercased()) else { return false }
        let visible = currentVisibleDockPills(for: q).filter { !$0.isSeparator }
        if visible.isEmpty { return true }
        return visible.allSatisfy(isSearchOnlyDockPill)
    }

    /// Retired for the same reason as the Context Dock variant: entering an app scope and typing
    /// something unmatched should not silently become a chat session.
    func autoArmGlobalInlineScopeChatForNoMenuMatch() {}

    func armGlobalInlineScopeChat(_ scope: GlobalInlineAppScope) {
        armGlobalScopedChat(appName: scope.appName, bundleId: scope.bundleId)
    }

    var currentGlobalScopedChatTarget: (appName: String, bundleId: String)? {
        // Finder desktop scope is pure FILE SEARCH — never a chat surface. With no chat target
        // there's no pin, no auto-arm, and no "send to AI" on a no-match, in BOTH Global Context
        // and Context Dock. A query that matches nothing means "no files found", full stop.
        if isFinderDesktopOnlyMode { return nil }
        if let scope = globalInlineAppScope {
            let name = scope.appName.trimmingCharacters(in: .whitespacesAndNewlines)
            let bundleId = scope.bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !bundleId.isEmpty {
                return (name.isEmpty ? "this app" : name, bundleId)
            }
        }
        if let target = l2.targetApp {
            let name = target.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let bundleId = target.bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !bundleId.isEmpty {
                return (name.isEmpty ? "this app" : name, bundleId)
            }
        }
        return nil
    }

    func armGlobalScopedChat(appName: String, bundleId: String) {
        l2.chatDraftAppName = appName
        l2.chatDraftBundleId = bundleId
        l2.chatArmed = true
        l2.chatDismissed = false
        requestWindowSizeUpdate(reason: .panelChanged, animated: true)
    }

    /// When a frontmost-app chat is active (armed / open / has messages), the header chip
    /// must stay locked to the CHAT's app — otherwise it follows the live frontmost while
    /// the placeholder still reads "Ask <chat app>", showing a mismatched chip. Empty when
    /// no chat is active (chip then tracks the live frontmost as before).
    var frontmostChipChatBundleID: String {
        let a = l2.chatDraftBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        let active = l2.chatArmed || l2.showChatPopover || !l2.chatMessages.isEmpty
        return (active && !a.isEmpty) ? a : ""
    }

    /// Chip label: the chat's app while a chat is active, else the live frontmost.
    var frontmostChipName: String {
        frontmostChipChatBundleID.isEmpty
            ? (inlineDockFeedbackAppName() ?? frontmost.name)
            : contextDockChatDraftAppName
    }

    /// True when a frontmost-app chat is active AND pinned — the chip then renders a locked
    /// pill (accent fill + `−` exit) instead of the soft frontmost chip.
    var isFrontmostChatPinned: Bool {
        settings.launcherPinned && !frontmostChipChatBundleID.isEmpty
    }

    /// `−` on the pinned frontmost-chat chip: unpin and drop back to menu search.
    func exitPinnedFrontmostChat() {
        if settings.launcherPinned {
            settings.launcherPinned = false
            AppDelegate.shared?.applyPersistentDockBehavior()
        }
        exitContextDockChatBackToContext()
    }

    /// Chip icon: the chat's app icon while a chat is active, else the live frontmost.
    var frontmostChipIcon: NSImage? {
        let chatBundle = frontmostChipChatBundleID
        if !chatBundle.isEmpty {
            return resolvedApplicationIcon(
                bundleIdentifier: chatBundle, appName: contextDockChatDraftAppName)
                ?? frontmost.icon
        }
        return inlineDockFeedbackAppIcon()
            ?? (isContextDockChatConnected ? currentBrowserPageIcon() : nil)
            ?? frontmost.icon
    }

    var contextDockChatDraftAppName: String {
        let stored = l2.chatDraftAppName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty { return stored }
        let scoped = l2.targetApp?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !scoped.isEmpty { return scoped }
        let name = frontmost.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "this app" : name
    }

    func armContextDockChat(animated: Bool = true) {
        // Hold the dock open for the whole scoped-chat session. Setting this only from
        // the debounced requestWindowSizeUpdate left it stale, so clicking the frontmost
        // app resigned key and hid the chat mid-conversation.
        AppDelegate.shared?.scopeChatSpaceHold = true
        let existingName = l2.chatDraftAppName.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingBundleId = l2.chatDraftBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        if (l2.chatArmed || l2.showChatPopover || !l2.chatMessages.isEmpty),
            !existingName.isEmpty,
            !existingBundleId.isEmpty
        {
            l2.chatArmed = true
            l2.chatAutoArmedForNoMenuMatch = false
            l2.chatDismissed = false
            requestWindowSizeUpdate(reason: .panelChanged, animated: animated)
            return
        }
        let scopedName = l2.targetApp?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let scopedBundleId = l2.targetApp?.bundleId.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackName = frontmost.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackBundleId = frontmost.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        l2.chatArmed = true
        l2.chatAutoArmedForNoMenuMatch = false
        l2.chatDismissed = false
        l2.chatDraftAppName = scopedName.isEmpty ? fallbackName : scopedName
        l2.chatDraftBundleId = scopedBundleId.isEmpty ? fallbackBundleId : scopedBundleId
        requestWindowSizeUpdate(reason: .panelChanged, animated: animated)
    }

    func disarmContextDockChat() {
        l2.showChatPopover = false
        l2.chatArmed = false
        l2.chatAutoArmedForNoMenuMatch = false
        l2.chatDismissed = true
        l2.chatDraftAppName = ""
        l2.chatDraftBundleId = ""
        syncScopeChatSpaceHold()
        requestWindowSizeUpdate(reason: .panelChanged)
    }

    func clearContextDockChatConversation(keepScope: Bool = true) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            l2.currentTask?.cancel()
            l2.currentTask = nil
            l2.isLoading = false
            l2.activeRequestID = nil
            l2.chatMessages = []
            updateL2Results([])
            if let key = l2.activeDockSessionKey {
                AppPanelChatStore.shared.clear(for: key)
            }
            if keepScope {
                l2.chatArmed = true
                l2.showChatPopover = true
                l2.chatDismissed = false
                l2.chatAutoArmedForNoMenuMatch = false
            }
        }
        requestWindowSizeUpdate(reason: .chatChanged, animated: true)
    }

    func exitContextDockChatSheet() {
        if let key = l2.activeDockSessionKey {
            AppPanelChatStore.shared.save(l2.chatMessages, for: key)
        }
        l2.showChatPopover = false
        l2.chatArmed = false
        l2.chatAutoArmedForNoMenuMatch = false
        l2.chatDismissed = true
        l2.chatDraftAppName = ""
        l2.chatDraftBundleId = ""
        syncScopeChatSpaceHold()
        l2.appCompletion = nil
        l2.showResultsPopover = false
        l2.focusedPillIndex = nil
        l2.pillNavViaKeyboard = false
        focusedAppPillIndex = nil
        searchState.query = ""
        searchState.results = []
        searchState.selectedIndex = nil
        livePanelVisible = false
        contextDockViewModel.resetPillRenderingState(cancelBuild: true)
        requestWindowSizeUpdate(reason: .modeChanged)
    }

    /// Backspace/close out of a chat. If the chat is tied to the FRONTMOST app, return
    /// to that app's menu search (Context Dock) — even if the chat was armed while
    /// Global Context was active (the "+" button has no global guard). Only chats not
    /// bound to the frontmost app fall out to Global Context.
    func exitContextDockChatBackToContext() {
        // Scoped chat over → release the hold so normal click-away hiding resumes.
        defer { syncScopeChatSpaceHold() }
        let chatApp = l2.chatDraftBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        let frontApp = frontmost.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopedApp = l2.targetApp?.bundleId.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Bound to the frontmost app when the chat draft OR the locked scope IS the
        // frontmost app — either way, exiting must land on that app's menu search,
        // never Global Context.
        // A frontmost-app chat now survives app switches, so its draft bundle may name the
        // app the chat STARTED in rather than the live frontmost one. With no explicit
        // scope (l2.targetApp / global inline scope) exiting still belongs on the CURRENT
        // frontmost app's menu search — never a drop into Global Context.
        let boundToFrontmost =
            !frontApp.isEmpty
            && (l2.targetApp == nil || scopedApp == frontApp)
            && (chatApp.isEmpty || chatApp == frontApp || allGlobalInlineAppScopes.isEmpty)
        if boundToFrontmost {
            exitContextDockChatSheet()
            l2.targetApp = nil
            if !allGlobalInlineAppScopes.isEmpty {
                clearGlobalInlineAppScope(preserveQuery: false)
            }
            // Force the frontmost app's Context Dock, not Global Context.
            globalContextActivation = nil
            showContextInDock = true
            scheduleDockPillRebuild(query: "", delayNanoseconds: 0, refreshContext: true)
        } else {
            exitContextDockChatAndScope()
        }
    }

    /// Shared exit used by the header button and empty-field Backspace. Clear the current
    /// app chat, cancel any in-flight work, then return the unified shell to Context Dock.
    func clearAndExitContextDockChatBackToContext() {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
            l2.chatMessages = []
            if let key = l2.activeDockSessionKey {
                AppPanelChatStore.shared.clear(for: key)
            }
            l2.isLoading = false
            l2.loadingStatus = nil
            l2.activeRequestID = nil
            l2.currentTask?.cancel()
            l2.currentTask = nil
            exitContextDockChatBackToContext()
        }
        // Tear down the CLI scope's embedded PTY so the next scope starts clean.
        CLIScopeTerminalManager.shared.reset()
        // Drop any captured text / attachments from the frontmost-app chat + menu.
        contextDockChatCapturedText = nil
        contextDockChatFiles = []
        isSearchFieldFocused = true
    }

    func exitContextDockChatAndScope() {
        let wasCLIToolScope = isCLIToolScopeLocked
        exitContextDockChatSheet()
        clearSearchContext()
        remPanelIsProcessing = false
        remIsInstalled = nil
        systemDataResults = []
        searchState.lastSmartQuery = ""
        globalContextActivation = wasCLIToolScope ? nil : GlobalContextActivation(autoActivated: false)
        showContextInDock = true
        isSearchFieldFocused = true
    }

    var contextDockChatButton: some View {
        Button {
            toggleInlineAIChatPanel()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: (isContextDockChatConnected || l2.isLoading)
                    ? "bubble.left.and.bubble.right.fill"
                    : "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.72))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.07), in: Circle())

                if isContextDockChatConnected && !l2.chatMessages.isEmpty
                    && !shouldShowContextDockChatSheet
                {
                    Text("\(min(l2.chatMessages.count, 9))")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 13, minHeight: 13)
                        .background(Color.accentColor, in: Circle())
                        .offset(x: 3, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .help(isContextDockChatConnected ? "AI conversation connected" : "Connect AI conversation")
    }

    /// + menu for the frontmost-app chat: attach files/photos, screenshots, or grab
    /// on-screen text (Capture Text) so the scoped chat can act on what's visible —
    /// e.g. OCR a Messages thread, then ask "what should I reply?".
    @ViewBuilder
    var contextDockChatAttachMenu: some View {
        Menu {
            Button {
                let picked = pickFilesForChatAttachment(imagesOnly: false)
                if !picked.isEmpty { contextDockChatFiles.append(contentsOf: picked) }
            } label: { Label("Upload File", systemImage: "doc") }
            Button {
                let picked = pickFilesForChatAttachment(imagesOnly: true)
                if !picked.isEmpty { contextDockChatFiles.append(contentsOf: picked) }
            } label: { Label("Upload Photo", systemImage: "photo") }
            Divider()
            Button {
                captureScreenshotToAttachments(interactive: false) { url in
                    contextDockChatFiles.append(url)
                }
            } label: { Label("Take Screenshot", systemImage: "camera.viewfinder") }
            Button {
                captureScreenshotToAttachments(interactive: true, windowFirst: true) { url in
                    contextDockChatFiles.append(url)
                }
            } label: { Label("Capture Area", systemImage: "crop") }
            Button {
                captureScreenText { text in
                    let existing = contextDockChatCapturedText?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    contextDockChatCapturedText =
                        existing.isEmpty ? text : existing + "\n\n" + text
                }
            } label: { Label("Capture Text", systemImage: "text.viewfinder") }
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 15))
                .foregroundStyle(
                    .secondary.opacity(
                        contextDockChatFiles.isEmpty && contextDockChatCapturedText == nil ? 0.6 : 0.95))
                .frame(width: 26, height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Attach a file, screenshot, or capture on-screen text")
    }

    /// Attachment chips (files / captured text) for the frontmost-app chat, shown next
    /// to the + so the user can see what will be sent — and drop it again.
    @ViewBuilder
    var contextDockChatAttachmentChips: some View {
        let fileCount = contextDockChatFiles.count
        let hasText = (contextDockChatCapturedText?.isEmpty == false)
        if fileCount > 0 || hasText {
            HStack(spacing: 4) {
                if fileCount > 0 {
                    Button {
                        contextDockChatFiles.removeAll()
                    } label: {
                        HStack(spacing: 3) {
                            if let first = contextDockChatFiles.first,
                                let thumb = NSImage(contentsOf: first)
                            {
                                Image(nsImage: thumb)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 16, height: 16)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            } else {
                                Image(systemName: "doc.fill").font(.system(size: 9))
                            }
                            Text(fileCount > 1 ? "\(fileCount)" : "1")
                                .font(.system(size: 10, weight: .semibold))
                            Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                        }
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("\(fileCount) attachment(s) — click to remove")
                }
                if hasText {
                    Button {
                        contextDockChatCapturedText = nil
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "text.viewfinder").font(.system(size: 9))
                            Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                        }
                        .foregroundStyle(.green)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Captured text attached — click to remove")
                }
            }
            .transition(.scale(scale: 0.85).combined(with: .opacity))
        }
    }

    /// Pin + the attach menu, shown together in the frontmost-app chat toolbar.
    var contextDockChatTrailingControls: some View {
        HStack(spacing: 4) {
            contextDockChatAttachmentChips
            contextDockChatAttachMenu
            contextDockChatCloseButton
        }
    }

    /// Trailing pin toggle (replaces the old duplicate "−" close button — the scope
    /// chip's "−" already exits the chat). Pinned = launcher floats over every app
    /// and never auto-hides until unpinned.
    var contextDockChatCloseButton: some View {
        Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
                settings.launcherPinned.toggle()
                // Pin changes dockJoinsAllSpaces — re-apply the window collectionBehavior
                // now, otherwise the dock keeps moveToActiveSpace and vanishes when the
                // user switches desktop Spaces despite being pinned.
                AppDelegate.shared?.applyPersistentDockBehavior()
            }
            isSearchFieldFocused = true
        } label: {
            Image(systemName: settings.launcherPinned ? "pin.fill" : "pin")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(
                    settings.launcherPinned
                        ? AnyShapeStyle(Color.orange.opacity(0.9))
                        : AnyShapeStyle(.secondary.opacity(0.70)))
                .frame(width: 22, height: 22)
                .background(
                    settings.launcherPinned
                        ? Color.orange.opacity(0.16) : Color.white.opacity(0.07),
                    in: Circle())
        }
        .buttonStyle(.plain)
        .help(settings.launcherPinned
            ? "Unpin — launcher hides normally again"
            : "Pin — keep floating over all apps")
    }

    /// Right-arrow on a non-Finder frontmost app in Context Dock (empty field, idle)
    /// connects the frontmost-app chat — the "+" affordance. Finder uses folder attach.
    /// Guarded so it never steals right-arrow from the pinned/running app-pill row.
    @discardableResult
    func connectFrontmostAppChatFromEmptyFieldIfNeeded() -> Bool {
        guard showContextInDock, !isGlobalContextActive else { return false }
        guard !isCompactSmartScope, l2.targetApp == nil else { return false }
        guard !isContextDockChatConnected else { return false }
        guard searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard isSearchInputActiveAtEnd() else { return false }
        let bid = frontmost.bundleID
        guard !bid.isEmpty, bid != "com.apple.finder", bid != Bundle.main.bundleIdentifier else {
            return false
        }
        // Only when the frontmost-app dock has content — otherwise right-arrow drives the
        // pinned/running app-pill row, which must keep its navigation.
        guard !selectionScopedDockPills(cachedDockPills).isEmpty else { return false }
        toggleInlineAIChatPanel()
        return true
    }

    func toggleInlineAIChatPanel() {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
            if l2.showChatPopover {
                exitContextDockChatAndScope()
            } else {
                if l2.chatArmed {
                    exitContextDockChatAndScope()
                } else {
                    armContextDockChat()
                }
            }
            if l2.chatArmed {
                livePanelVisible = false
                showFolderPreview = false
                l2.focusedPillIndex = nil
                focusedAppPillIndex = nil
            }
        }
        isSearchFieldFocused = true
    }

    func openInlineAIChatPanel() {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
            armContextDockChat()
            livePanelVisible = false
            showFolderPreview = false
            l2.focusedPillIndex = nil
            focusedAppPillIndex = nil
        }
        // Auto-attach mail context when the user explicitly opens a Mail-scoped chat
        // (right arrow, pin, or any direct invocation). The deliberate scope choice
        // is the consent signal — no separate + button press needed.
        let mailBundleId = "com.apple.mail"
        if frontmost.bundleID == mailBundleId
            || l2.targetApp?.bundleId == mailBundleId
            || l2.chatDraftBundleId.trimmingCharacters(in: .whitespacesAndNewlines) == mailBundleId
        {
            isMailContextAttached = true
        }
        isSearchFieldFocused = true
    }

    // MARK: - Inline Dock Terminal
    @ViewBuilder
    func inlineDockTerminalView(term: TerminalHostController) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.green)
                Text("Terminal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    l2.terminalDismissed = true
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        livePanelVisible = false
                    }
                    isSearchFieldFocused = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.3))

            TerminalNSViewRepresentable(terminalController: term)
                .frame(maxWidth: .infinity)
                .frame(height: 220)
        }
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.green.opacity(0.15), lineWidth: 0.75)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - L2 Chat Section
    /// One-line "Using: <app> · <cli tools> · <N shortcuts>" summary shown under the
    /// Context Dock Chat header so the user sees the conversation's tool scope.
    func contextDockChatUsingSummary(bundleId: String, appName: String) -> String {
        if isContextDockBrowserBundle(bundleId), connectedBrowserPageGhostTitle != nil {
            return "Using: \(appName) · current page"
        }
        var parts: [String] = [appName]
        let cli = TerminalPackageManager.shared.packages.filter {
            $0.isEnabled && $0.contextAppBundleIds.contains(bundleId)
        }
        if !cli.isEmpty {
            parts.append(cli.map(\.command).joined(separator: ", "))
        }
        let shortcutCount = adapterManager.adapter(for: bundleId)?
            .actions.filter { $0.type == .shortcut }.count ?? 0
        if shortcutCount > 0 {
            parts.append("\(shortcutCount) shortcut\(shortcutCount == 1 ? "" : "s")")
        }
        return "Using: " + parts.joined(separator: " · ")
    }

    func contextDockChatTitle(appName: String, bundleId: String) -> String {
        guard isContextDockBrowserBundle(bundleId),
            let pageTitle = connectedBrowserPageGhostTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            !pageTitle.isEmpty
        else { return appName }
        return pageTitle
    }

    @ViewBuilder
    var l2ChatSection: some View {
        let hasConversation = !l2.chatMessages.isEmpty || l2.isLoading
        let scopedTarget = l2.targetApp
        // Chat-style avatars: scoped app icon on answers, provider symbol on queries —
        // scope stays readable even when the header scrolls out of view.
        let scopedAppIcon: NSImage? = scopedTarget.flatMap { target in
            target.icon
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleId)
                    .map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
        let providerSymbol = settings.selectedAIProvider.iconName
        if hasConversation || l2.showChatPopover {
            VStack(spacing: 0) {
                if hasConversation {
                    // Minimal header — app name + Clear + Exit Scope only (icon already in search bar)
                    HStack(spacing: 8) {
                        if let scopedTarget {
                            // Browser scope with a connected page → show the SITE's favicon
                            // so the user sees which page they are chatting with.
                            if isContextDockBrowserBundle(scopedTarget.bundleId),
                                let faviconURL = connectedBrowserPageFaviconURL
                            {
                                AsyncImage(url: faviconURL) { img in
                                    img.resizable().scaledToFit()
                                } placeholder: {
                                    AppBundleIconView(
                                        bundleId: scopedTarget.bundleId,
                                        fallbackSymbol: "bubble.left.and.text.bubble.right",
                                        size: 18, cornerRadius: 4
                                    )
                                }
                                .frame(width: 18, height: 18)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            } else {
                                AppBundleIconView(
                                    bundleId: scopedTarget.bundleId,
                                    fallbackSymbol: "bubble.left.and.text.bubble.right",
                                    size: 18, cornerRadius: 4
                                )
                            }
                            // Single-line header — per-message avatars carry the scope
                            // identity now, so the "Using: …" subtitle is gone.
                            Text("Chat with \(contextDockChatTitle(appName: scopedTarget.name, bundleId: scopedTarget.bundleId))")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer()
                        Button {
                            clearContextDockChatConversation(keepScope: true)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "trash")
                                    .font(.system(size: 9, weight: .medium))
                                Text("Clear")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(.secondary.opacity(0.6))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.regularMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        if scopedTarget != nil {
                            Button("Exit Scope") {
                                clearAndExitContextDockChatBackToContext()
                            }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                        }
                    }
                    // Leading 20 aligns the header app icon under the input scope-chip icon
                    // (input pad 12 + chip leading 8) so the surface doesn't visually jump.
                    .padding(.leading, 20)
                    .padding(.trailing, 14)
                    .padding(.vertical, 6)

                    Divider().opacity(0.15)
                }

                if hasConversation {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(spacing: 12) {
                                ForEach(l2.chatMessages) { message in
                                    if message.role == .approval {
                                        l2InlineApprovalCard(message)
                                            .id(message.id)
                                    } else if message.hasInstallButton {
                                        AIChatMessageView(
                                            message: message,
                                            onInstallExtension: installSuggestedExtension,
                                            onInstallProposal: { json in installFromProposal(json)
                                            },
                                            onRunOnceProposal: { json in runOnceFromProposal(json) },
                                            userAvatarSymbol: providerSymbol,
                                            assistantAvatarImage: scopedAppIcon
                                        )
                                        .id(message.id)
                                    } else {
                                        AIChatMessageView(
                                            message: message,
                                            userAvatarSymbol: providerSymbol,
                                            assistantAvatarImage: scopedAppIcon
                                        )
                                        .id(message.id)
                                    }
                                }

                                if let pendingAdapterApproval {
                                    InlineAdapterApprovalCard(request: pendingAdapterApproval)
                                        .id("adapter-approval")
                                }

                                if let gap = pendingCapabilityGap {
                                    CapabilityGapCard(
                                        gap: gap,
                                        isWorking: capabilityGapWorking,
                                        onPrimary: { resolveCapabilityGap(gap) },
                                        onDismiss: { dismissCapabilityGap() }
                                    )
                                    .id("capability-gap")
                                }

                                if let pending = taskExecutor.pendingToolChoice {
                                    ToolSelectionInlineView(
                                        pending: pending,
                                        onSelect: { tool in taskExecutor.approveToolChoice(tool) },
                                        onCancel: { taskExecutor.denyToolChoice() }
                                    )
                                    .id("toolChoice")
                                }

                                if l2.isLoading {
                                    AILoadingView(status: l2.loadingStatus).id("l2loading")
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            // Measure intrinsic message height (independent of the scroll frame).
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                updateMeasuredChatContentHeight(height)
                            }
                        }
                        // Hug short chats, scroll long ones — frame to the measured height, capped.
                        .frame(height: min(max(measuredChatContentHeight, 1), 400))
                        .onChange(of: l2.chatMessages.count) { _, _ in
                            withAnimation {
                                if let last = l2.chatMessages.last {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                        .onChange(of: l2.isLoading) { _, newValue in
                            if newValue {
                                withAnimation { proxy.scrollTo("l2loading", anchor: .bottom) }
                            }
                        }
                    }
                }

                // CLI tool scopes get an embedded live PTY docked at the bottom —
                // approved commands run here in real time; chevron expands it.
                if isInCLIToolScope {
                    CLIScopeTerminalPanel(isDark: isEffectiveDark, accentColor: .green)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                        .padding(.bottom, 8)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
    }

    /// True while the active scope / scoped chat is a CLI tool (cli:// bundle, a
    /// pinned CLI tool, or a bare binary path) — drives the embedded terminal panel.
    var isInCLIToolScope: Bool {
        if isCLIToolScopeLocked { return true }
        if let scope = globalInlineAppScope,
            isCLIToolScopeChip(
                bundleId: scope.bundleId, appName: scope.appName, appPath: scope.appPath)
        {
            return true
        }
        if let target = l2.targetApp,
            isCLIToolScopeChip(bundleId: target.bundleId, appName: target.name, appPath: "")
        {
            return true
        }
        return false
    }

    /// Two-step send confirmation: the AI proposed sharing its result; the user approves the
    /// destination before the native Share fires.
    @ViewBuilder
    func selectionShareConfirmCard(_ pending: PendingSelectionShare) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text("Send via \(pending.destination)?")
                    .font(.system(size: 12, weight: .semibold))
                Text(aiMode.selectionFiles.isEmpty
                    ? "Sends the result text" : "Sends the result + \(aiMode.selectionFiles.count) file(s)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { aiMode.pendingShare = nil }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("Send") {
                let p = pending
                aiMode.pendingShare = nil
                shareSelectionResult(text: p.text, destination: p.destination)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.blue.opacity(0.25)))
    }

    // MARK: - AI Chat Section
    @ViewBuilder
    var aiChatSection: some View {
        let showingContent =
            hasUserSentMessageInCurrentSession
            && (!aiMode.messages.isEmpty || aiMode.isLoading || aiMode.streamingId != nil)
        if showingContent {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    // VStack (not Lazy) so SwiftUI knows the full content height for scrolling
                    VStack(spacing: 10) {
                        if let label = generalAISelectionContextLabel {
                            HStack(spacing: 8) {
                                Image(systemName: generalAISelectionContextIcon)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 18, height: 18)
                                Text(label)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.7)
                            )
                            .id("general-ai-selection-context")
                        }
                        ForEach(aiMode.messages) { message in
                            AIChatMessageView(
                                message: message,
                                isStreaming: message.id == aiMode.streamingId,
                                onInstallProposal: { json in installFromProposal(json) },
                                onRunOnceProposal: { json in runOnceFromProposal(json) },
                                onReplaceText: selectionScopeReplaceTextAction(for: message),
                                onEnableApp: { req in enableAppForGeneralChat(req) }
                            )
                            .id(message.id)
                        }
                        if let progress = aiMode.actionProgress {
                            actionProgressCard(progress)
                                .id("action-progress")
                        }
                        if aiMode.isLoading {
                            AILoadingView(status: aiMode.loadingStatus)
                            .animation(.easeInOut(duration: 0.18), value: aiMode.loadingStatus)
                            .padding(.horizontal, 4)
                            .id("loading")
                        }
                        if let pendingPrivacyApproval {
                            InlinePrivacyApprovalCard(pending: pendingPrivacyApproval)
                                .id("privacy-approval")
                        }
                        if let pendingAdapterApproval {
                            InlineAdapterApprovalCard(request: pendingAdapterApproval)
                                .id("adapter-approval")
                        }
                        if let pending = aiMode.pendingShare {
                            selectionShareConfirmCard(pending)
                                .id("pending-share")
                        }
                        // DoraX Action Chat: first-run approval for executable actions.
                        GeneralAIActionApprovalCard()
                            .id("general-ai-action-approval")
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                    // Measure intrinsic conversation height (independent of the scroll frame).
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        updateMeasuredChatContentHeight(height)
                    }
                }
                // Hug short chats, scroll long ones — frame to the measured height, capped at 450.
                .frame(height: min(max(measuredChatContentHeight, 1), 450))
                .onChange(of: aiMode.messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        if let lastMessage = aiMode.messages.last {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: aiMode.isLoading) { _, newValue in
                    if newValue {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("loading", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    func selectionScopeReplaceTextAction(for message: AIChatMessage) -> (() -> Void)? {
        guard hasSelectionScopeSurface,
            message.role == .assistant,
            message.id != aiMode.streamingId,
            // Text selections only, and only when the source field can be written back to —
            // otherwise the button offered a paste that had nowhere to land (files, folders,
            // read-only views).
            aiMode.selectionFiles.isEmpty,
            selectionScopeSourceAcceptsReplacement,
            aiMode.selectionText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { return nil }
        let replacement = cleanedNativeWritingToolOutput(message.content)
        guard !replacement.isEmpty else { return nil }
        return {
            replaceSelectionTextWithAIAnswer(replacement)
        }
    }

    func replaceSelectionTextWithAIAnswer(_ text: String) {
        guard hasSelectionScopeSurface else { return }
        let target =
            AppDelegate.shared?.previousFrontmostApp
            ?? NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier == selectionScopePayload?.sourceBundleId
            }
        let pid = target?.processIdentifier ?? 0
        pasteNativeWritingToolOutput(text, sourcePID: pid)
        DockActionFeedback.showResult("Replacement pasted", icon: "arrow.left.arrow.right", success: true)
    }

    var generalAISelectionContextLabel: String? {
        if aiMode.selectionFiles.count > 1 {
            return "\(aiMode.selectionFiles.count) selected files"
        }
        if let file = aiMode.selectionFiles.first {
            return file.lastPathComponent
        }
        if let text = aiMode.selectionText?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        {
            return String(text.prefix(80))
        }
        if let url = aiMode.selectionURL?.trimmingCharacters(in: .whitespacesAndNewlines),
            !url.isEmpty
        {
            return URL(string: url)?.host ?? String(url.prefix(80))
        }
        return nil
    }

    var generalAISelectionContextIcon: String {
        if aiMode.selectionFiles.count > 1 { return "doc.on.doc.fill" }
        if let file = aiMode.selectionFiles.first {
            return fileIcon(for: file.pathExtension.lowercased())
        }
        if aiMode.selectionText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return "text.cursor"
        }
        if aiMode.selectionURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return "link"
        }
        return "target"
    }

    // Removed connector execution indicators - simplified for launcher/file manager focus

    // MARK: - AI Extension Suggestions Loading
    func loadAIExtensionSuggestions() {
        #if DEBUG
        print("🔧 [ContentView] Loading AI extension suggestions...")
        #endif
        #if DEBUG
        print("🔧 [ContentView] Current context: \(currentContext.description)")
        #endif

        Task {
            let matcher = IntelligentExtensionMatcher.shared
            let detectedContext = convertUserContextToDetectedContext(currentContext)

            #if DEBUG
            print("🔧 [ContentView] Converted to DetectedContext: \(detectedContext)")
            #endif

            // Get suggestions from matcher
            var newSuggestions = matcher.suggestExtensions(for: detectedContext)
            #if DEBUG
            print("🔧 [ContentView] Got \(newSuggestions.count) suggestions from matcher")
            #endif

            // If no suggestions from matcher, load default built-in extensions
            if newSuggestions.isEmpty {
                #if DEBUG
                print("⚠️ [ContentView] No suggestions from matcher, loading defaults...")
                #endif
                let allExtensions = ExtensionManager.shared.getEnabledExtensions()
                #if DEBUG
                print("📦 [ContentView] Found \(allExtensions.count) total extensions")
                #endif

                newSuggestions = allExtensions.map { ext in
                    let score: Double = {
                        switch ext.name.lowercased() {
                        case "copy": return 90.0
                        case "copy-path", "copypath": return 85.0
                        case "file-info", "fileinfo": return 80.0
                        case "count-words", "countwords": return 75.0
                        case "summarize": return 70.0
                        case "uppercase": return 65.0
                        case "lowercase": return 64.0
                        default: return 60.0
                        }
                    }()

                    return SuggestedExtension(
                        scriptExtension: ext,
                        relevanceScore: score,
                        reason: "General purpose action"
                    )
                }
            }

            // Sort by relevance
            newSuggestions.sort { $0.relevanceScore > $1.relevanceScore }

            #if DEBUG
            print("🔧 [ContentView] Sorted suggestions: \(newSuggestions.count)")
            #endif
            for (index, suggestion) in newSuggestions.prefix(6).enumerated() {
                print(
                    "🔧 [ContentView]   \(index + 1). \(suggestion.scriptExtension.displayName) (score: \(suggestion.relevanceScore))"
                )
            }

            await MainActor.run {
                aiExtensionSuggestions = newSuggestions
                #if DEBUG
                print("✅ [ContentView] AI extension suggestions updated!")
                #endif
            }
        }
    }

    func convertUserContextToDetectedContext(_ context: UserContext) -> DetectedContext {
        switch context {
        case .filesSelected(let urls):
            return .files(urls)
        case .textSelected(let text):
            return .text(text)
        case .url(let urlString):
            return .text(urlString)  // URLs are treated as text for extension matching
        case .appFocused(let name, let bundleID):
            return .app(bundleID: bundleID, name: name)
        case .contactSelected(let contact):
            return .text(contact)
        case .none:
            // Try clipboard as fallback
            if let clipboardText = NSPasteboard.general.string(forType: .string),
                !clipboardText.isEmpty
            {
                return .text(clipboardText)
            }
            return .app(bundleID: "", name: "Unknown")
        }
    }

    // MARK: - Clipboard Image Paste for AI Chat
    /// Checks if the clipboard contains an image. If so, saves to a temp file,
    /// appends to aiMode.attachments, and returns true so the caller can show a confirmation.
    @discardableResult
    func pasteClipboardImageToChat() -> Bool {
        let pasteboard = NSPasteboard.general
        guard pasteboard.canReadItem(withDataConformingToTypes: [NSPasteboard.PasteboardType.tiff.rawValue,
                                                                   NSPasteboard.PasteboardType.png.rawValue])
        else { return false }
        guard let image = NSImage(pasteboard: pasteboard) else { return false }
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else { return false }

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("paste-\(UUID().uuidString).png")
        do {
            try pngData.write(to: tmpURL)
            aiMode.attachments.append(tmpURL)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Get Context Extensions for AI Chat Mode
    func getContextExtensions() -> [SuggestedExtension] {
        let detectedContext = convertUserContextToDetectedContext(currentContext)
        return IntelligentExtensionMatcher.shared.suggestExtensions(for: detectedContext)
    }

    // MARK: - AI Query Submission
    /// One-tap "Enable <app> for this chat": add the app to the focus picker, then re-run the
    /// original query now that it's in scope. Keeps the user in control — nothing was read
    /// until they tapped.
    func enableAppForGeneralChat(_ req: EnableAppRequest) {
        if !chatFocusApps.contains(where: {
            $0.bundleId.caseInsensitiveCompare(req.bundleId) == .orderedSame
        }) {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
                chatFocusApps.append(.init(name: req.name, bundleId: req.bundleId))
            }
        }
        aiMode.pendingEnableApp = nil
        guard !aiMode.isLoading, aiMode.streamingId == nil else { return }
        searchState.query = req.query
        submitAIQuery()
    }

    /// Launch + warm the menu cache for any picked focus app that isn't running yet, so its
    /// menu commands get listed and become callable via menu_call. Only invoked for
    /// action-shaped queries (not plain Q&A), and skips apps whose cache is already warm.
    func warmFocusAppMenusForAction() async {
        for app in chatFocusApps {
            let bundle = app.bundleId
            guard !bundle.isEmpty, !bundle.hasPrefix("scope://") else { continue }
            // Already warm? nothing to do.
            let cached = AppMenuCapabilityCache.shared.menuItems(
                bundleIdentifier: bundle, appName: app.name, query: "", maxResults: 1)
            if !cached.isEmpty { continue }
            await MainActor.run { aiMode.loadingStatus = "Opening \(app.name)…" }
            guard let running = await AppAdapterManager.shared.launchAndActivate(bundleId: bundle)
            else { continue }
            await MainActor.run { aiMode.loadingStatus = "Reading \(app.name) menus…" }
            await MenuWarmCacheService.shared.warm(app: running, force: true)
        }
    }

    func submitAIQuery() {
        restoreGeneralAIConversationIfNeeded()
        hydrateAISelectionContextFromVisibleSelection()

        let query = searchState.query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        guard !aiMode.isLoading && aiMode.streamingId == nil else { return }

        print(
            "🤖 [AI] Submitting query: \"\(query.prefix(60))\" | provider: \(settings.selectedAIProvider.shortName)"
        )

        hasUserSentMessageInCurrentSession = true

        let pendingAttachments = mergedAIRequestAttachments(
            explicitAttachments: aiMode.attachments
        )

        withAnimation {
            aiMode.messages.append(
                AIChatMessage(role: .user, content: query, attachments: pendingAttachments))
        }
        persistGeneralAIConversation()
        searchState.query = ""

        aiMode.attachments = []

        aiMode.isLoading = true
        aiMode.loadingStatus = pendingAttachments.isEmpty
            ? "Checking App Adapters…"
            : "Reading attached files…"
        aiMode.currentTask?.cancel()
        let providerSelection = AIProviderSelectionResolver.current(settings: settings)

        // Every provider, including on-device, uses the same context-aware router pipeline.
        aiMode.currentTask = Task {
            do {
                let response: String
                response = try await sendToAIProvider(
                    query: query,
                    attachments: pendingAttachments,
                    providerSelection: providerSelection
                )
                // "Open in <App>" buttons are keyword-derived, so in Selection Scope they used to
                // appear next to answers where nothing ran — a receipt for work that never
                // happened. Attach them only when a route actually executed.
                let launches = await MainActor.run { () -> [AppLaunchAction] in
                    if self.hasSelectionScopeSurface,
                        self.selectionRouterExecutedRouteTitle == nil
                    {
                        return []
                    }
                    return self.referencedAppLaunches(for: query)
                }
                let shareInvocation = AITypedInvocationResolver.shareInvocation(
                    query: query,
                    responseText: response,
                    hasSelection: !self.currentAISelectionSnapshot.isEmpty
                )
                var cleaned = self.sanitizeGeneralChatAssistantText(response)
                // Selection Scope: nothing executed → the answer may not read like a receipt.
                cleaned = await MainActor.run { () -> String in
                    guard self.hasSelectionScopeSurface,
                        self.selectionRouterExecutedRouteTitle == nil
                    else { return cleaned }
                    return self.enforceNoFalseSelectionSuccess(cleaned)
                }
                await MainActor.run {
                    let enableReq = self.aiMode.pendingEnableApp
                    self.aiMode.pendingEnableApp = nil
                    withAnimation {
                        // Auto-create: if the AI proposed a runnable extension (no route fit),
                        // tag the message so it shows Run once / Save buttons instead of just
                        // describing a script.
                        let baseMsg = AIChatMessage(
                            role: .assistant, content: cleaned, appLaunches: launches,
                            mcpToolsRan: self.aiMode.pendingToolChips,
                            enableAppRequest: enableReq,
                            trace: self.aiMode.routerTrace)
                        self.aiMode.messages.append(self.tagMessageWithProposal(baseMsg))
                        self.aiMode.pendingToolChips = []
                        self.aiMode.routerTrace = []
                        self.aiMode.loadingStatus = nil
                        self.aiMode.isLoading = false
                    }
                    self.persistGeneralAIConversation()
                    // Two-step: don't send yet — show a confirm card so the user approves the
                    // destination first.
                    if let shareInvocation,
                        let shareDest = shareInvocation.arguments["destination"]
                    {
                        self.aiMode.pendingShare = PendingSelectionShare(
                            text: cleaned, destination: shareDest)
                    }
                    self.requestWindowSizeUpdate(reason: .chatChanged)
                }
            } catch {
                await MainActor.run {
                    withAnimation {
                        self.aiMode.messages.append(
                            AIChatMessage(
                                role: .assistant,
                                content: "Error: \(error.localizedDescription)",
                                isError: true))
                        self.aiMode.pendingToolChips = []
                        self.aiMode.loadingStatus = nil
                        self.aiMode.isLoading = false
                    }
                    self.persistGeneralAIConversation()
                    self.requestWindowSizeUpdate(reason: .chatChanged)
                }
            }
        }
    }

    /// Strip leaked tool-call scaffolding from a general-chat answer before it is shown.
    /// Models sometimes print their tool call as text — Anthropic-style
    /// `<function><invoke name="mcp_call">…</invoke></function>` XML, or a bare
    /// `{"mcp_call":…}` / TERMINAL_COMMAND blob — instead of it being executed silently.
    /// Remove those fragments so the user sees only the prose, never raw call syntax.
    func sanitizeGeneralChatAssistantText(_ text: String) -> String {
        var out = text
        let patterns = [
            "(?s)<function>.*?</function>",
            "(?s)<invoke\\b.*?</invoke>",
            "(?s)<invoke\\b.*?</invoke>",
            "(?m)^\\s*</?(?:antml:)?(?:function|invoke|parameter)\\b[^>]*>\\s*$",
            "(?s)<parameter\\b.*?</parameter>",
            "(?s)\\[?TERMINAL_COMMAND\\].*?\\[/TERMINAL_COMMAND\\]",
            "(?m)^\\s*\\{\\s*\"(?:mcp_call|menu_call|adapter_call|terminal_call|capability_call)\"\\s*:[\\s\\S]*?\\}\\s*$",
        ]
        for pattern in patterns {
            out = out.replacingOccurrences(
                of: pattern, with: "", options: [.regularExpression])
        }
        // Collapse the blank gaps left behind.
        out = out.replacingOccurrences(
            of: "(?m)\\n{3,}", with: "\n\n", options: [.regularExpression])
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func restoreGeneralAIConversationIfNeeded() {
        guard aiMode.messages.isEmpty else { return }
        let restored = GeneralAIChatConversationStore.load()
        guard !restored.isEmpty else { return }
        aiMode.messages = restored
        hasUserSentMessageInCurrentSession = true
        requestWindowSizeUpdate(reason: .chatChanged)
    }

    func persistGeneralAIConversation() {
        GeneralAIChatConversationStore.save(aiMode.messages)
    }

    func clearGeneralAIConversation() {
        GeneralAIChatConversationStore.clear()
    }

    func mergedAIRequestAttachments(explicitAttachments: [URL]) -> [URL] {
        var seen = Set(explicitAttachments.map(\.standardizedFileURL.path))
        var merged = explicitAttachments
        for url in aiMode.selectionFiles {
            let key = url.standardizedFileURL.path
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(url)
        }
        return merged
    }

    func hydrateAISelectionContextFromVisibleSelection() {
        if aiMode.selectionText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            // Only a TEXT payload may seed selectionText. A file/folder payload's frozenText is a
            // display label ("Screenshot"), and feeding it in as selected content made the model
            // answer about the word instead of the folder — and lit up "Replace text".
            if case .text(let text)? = effectiveSelectionForScope {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { aiMode.selectionText = trimmed }
            } else if case .textSelected(let text) = currentContext,
                effectiveSelectionForScope == nil
            {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { aiMode.selectionText = trimmed }
            }
        }
        if aiMode.selectionFiles.isEmpty {
            aiMode.selectionFiles = effectiveSelectedFileURLsForConversation()
        }
        selectionScopeSourceAcceptsReplacement = selectionSourceAcceptsTextReplacement()
    }

    /// Whether the app the selection came from can actually take the answer back. Checks the AX
    /// focused element of the source app for a settable selected-text/value attribute — a Mail
    /// compose body or editor says yes, a Finder icon view or read-only web page says no.
    func selectionSourceAcceptsTextReplacement() -> Bool {
        guard aiMode.selectionFiles.isEmpty else { return false }
        guard aiMode.selectionText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { return false }
        let sourceBundleId = selectionScopePayload?.sourceBundleId
        let app =
            AppDelegate.shared?.previousFrontmostApp
            ?? NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier == sourceBundleId
            }
        guard let pid = app?.processIdentifier,
            let element = currentFocusedElement(in: pid)
        else { return false }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
            == .success, settable.boolValue
        {
            return true
        }
        settable = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
            == .success, settable.boolValue, isEditableAXElement(element)
        {
            return true
        }
        return false
    }

    func userQueryWithExplicitSelection(_ query: String) -> String {
        guard let selectedText = aiMode.selectionText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !selectedText.isEmpty
        else { return query }
        return """
        Selected text:
        \"\"\"
        \(String(selectedText.prefix(12_000)))
        \"\"\"

        User request:
        \(query)
        """
    }

    var currentAISelectionSnapshot: AISelectionSnapshot {
        AISelectionSnapshot(
            text: aiMode.selectionText,
            files: aiMode.selectionFiles,
            pageURL: aiMode.selectionURL
        )
    }

    func selectionAIContextBlock(compact: Bool = false, query: String? = nil) -> String {
        let snapshot = currentAISelectionSnapshot
        guard !snapshot.isEmpty else { return "" }
        var parts: [String] = []
        let textLimit = compact ? 4_000 : 12_000
        let fileLimit = compact ? 5 : 20
        let fileContentLimit = compact ? 2_500 : 5_000
        if let text = snapshot.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        {
            let selectedText = String(text.prefix(textLimit))
            let suffix = text.count > selectedText.count
                ? "\n\n*(Selected text compacted for the current AI context budget)*"
                : ""
            parts.append("Selected content:\n\"\"\"\n\(selectedText)\(suffix)\n\"\"\"")
        }
        if let pageURL = snapshot.pageURL, !pageURL.isEmpty {
            parts.append("Selection page: \(pageURL)")
        }
        if !snapshot.files.isEmpty {
            // Filesystem facts FIRST. analyzeFiles only yields readable text, so a selected
            // folder (or any binary) contributed nothing and the model answered "contents
            // unknown" / "0 bytes". These lines are the ground truth for size/count questions.
            let facts = selectionFileSystemFactsBlock(
                Array(snapshot.files.prefix(fileLimit)), compact: compact)
            if !facts.isEmpty { parts.append(facts) }
            let blocks = ContextDetector.shared.analyzeFiles(Array(snapshot.files.prefix(fileLimit))).compactMap {
                item -> String? in
                guard let content = item.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !content.isEmpty
                else { return nil }
                let markdown = MarkItDownService.compact(content, for: query, limit: fileContentLimit)
                return "### \(item.url.lastPathComponent) (\(item.type))\n\(markdown)"
            }
            if !blocks.isEmpty { parts.append("Selected files:\n\n" + blocks.joined(separator: "\n\n")) }
            if snapshot.files.count > fileLimit {
                parts.append("Additional selected files omitted for context budget: \(snapshot.files.count - fileLimit)")
            }
        }
        return parts.joined(separator: "\n\n")
    }

    /// Ground truth about the selected files/folders: real sizes, item counts, dates, and a
    /// sample of a folder's contents. Without this the model can only see filenames and starts
    /// guessing ("empty or inaccessible") for exactly the questions selections invite.
    func selectionFileSystemFactsBlock(_ urls: [URL], compact: Bool) -> String {
        guard !urls.isEmpty else { return "" }
        let childSample = compact ? 10 : 25
        var lines: [String] = ["Selected item facts (verified from disk — trust these numbers):"]
        let fm = FileManager.default
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                lines.append("- \(url.path) — missing (no longer on disk)")
                continue
            }
            let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey, .creationDateKey, .fileSizeKey,
            ])
            let modified = values?.contentModificationDate.map { Self.selectionDateFormatter.string(from: $0) }
            if isDirectory.boolValue {
                let stats = directorySelectionStats(url)
                var line = "- \(url.path) — folder, \(stats.topLevelCount) items at top level"
                if stats.totalFiles > 0 {
                    line += ", \(stats.totalFiles) files total"
                    line += ", \(ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file))"
                    if stats.truncated { line += " (scan capped — totals are a lower bound)" }
                }
                if let modified { line += ", modified \(modified)" }
                lines.append(line)
                if !stats.sampleNames.isEmpty {
                    let sample = stats.sampleNames.prefix(childSample).joined(separator: ", ")
                    lines.append("  contents sample: \(sample)")
                }
                if let newest = stats.newestName, let oldest = stats.oldestName, newest != oldest {
                    lines.append("  newest: \(newest) · oldest: \(oldest)")
                }
            } else {
                var line = "- \(url.path) — file"
                if let size = values?.fileSize {
                    line += ", \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
                }
                if let modified { line += ", modified \(modified)" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static let selectionDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// Recursive size/count scan with a hard budget so a huge folder can't stall the ask.
    private func directorySelectionStats(_ url: URL) -> (
        topLevelCount: Int, totalFiles: Int, totalBytes: Int64, truncated: Bool,
        sampleNames: [String], newestName: String?, oldestName: String?
    ) {
        let fm = FileManager.default
        let topLevel =
            (try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
        let sampleNames = topLevel.prefix(40).map(\.lastPathComponent)

        var newest: (name: String, date: Date)?
        var oldest: (name: String, date: Date)?
        for child in topLevel.prefix(500) {
            guard let date = (try? child.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            else { continue }
            if newest == nil || date > newest!.date { newest = (child.lastPathComponent, date) }
            if oldest == nil || date < oldest!.date { oldest = (child.lastPathComponent, date) }
        }

        var totalFiles = 0
        var totalBytes: Int64 = 0
        var truncated = false
        // Hard caps: this runs on the main actor while composing the prompt, so a huge tree
        // (someone selects their home folder) must degrade to a lower bound, never stall the ask.
        let scanLimit = 20_000
        let deadline = Date().addingTimeInterval(0.4)
        if let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        {
            for case let file as URL in enumerator {
                if totalFiles >= scanLimit || Date() > deadline {
                    truncated = true
                    break
                }
                guard let values = try? file.resourceValues(forKeys: [
                    .fileSizeKey, .isRegularFileKey,
                ]), values.isRegularFile == true else { continue }
                totalFiles += 1
                totalBytes += Int64(values.fileSize ?? 0)
            }
        }
        return (
            topLevel.count, totalFiles, totalBytes, truncated, sampleNames,
            newest?.name, oldest?.name
        )
    }

    func selectionRequestNeedsCapabilities(_ query: String) -> Bool {
        guard !currentAISelectionSnapshot.isEmpty else { return true }
        let normalized = query.lowercased()
        return [
            "send ", "share ", "email ", "message ", "save ", "create ", "add ",
            "append ", "update ", "upload ", "open in ", "move ", "rename ", "run ",
        ].contains(where: normalized.contains)
    }

    /// Share the AI result (plus any selected files) through the native macOS Share service
    /// matching `destination` (Mail / Messages / Notes / …) — DoraX's NSSharingService path.
    func shareSelectionResult(text: String, destination: String) {
        var items: [Any] = []
        if !aiMode.selectionFiles.isEmpty { items.append(contentsOf: aiMode.selectionFiles) }
        if !text.isEmpty { items.append(text) }
        guard !items.isEmpty else { return }

        let dests = ShareActionCoordinator.shared.shareDestinations(items: items)
        let nd = destination.lowercased()
        let match = dests.first {
            let t = $0.title.lowercased()
            return t.contains(nd) || nd.contains(t)
        }
        forceHideLauncherAfterResultExecution()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if let match {
                match.perform(withItems: items)
            } else {
                self.presentSharingPicker(items: items)
            }
        }
    }

    func onDeviceFrontmostContextQuery(_ query: String) -> String {
        let timeBlock = currentDateTimeContextBlock()
        let scope = resolveDockScope(for: searchState.query)
        if showContextInDock,
            scope.isExplicitAppScope,
            !scope.scopedBundleId.isEmpty,
            !scope.scopedAppName.isEmpty
        {
            return """
                \(timeBlock)

                User request:
                \(query)
                """
        }
        let contextBlock =
            isGlobalQueryModeActive ? globalAIContextBlock() : frontmostAIContextBlock()
        guard !contextBlock.isEmpty else {
            return """
                \(timeBlock)

                User request:
                \(query)
                """
        }
        return """
            \(timeBlock)

            \(contextBlock)

            User request:
            \(query)
            """
    }

    func frontmostAIContextBlock() -> String {
        var lines: [String] = []
        let appName = frontmost.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleID = frontmost.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)

        if !appName.isEmpty || !bundleID.isEmpty {
            lines.append("## Frontmost App Context")
            if !appName.isEmpty { lines.append("App: \(appName)") }
            if !bundleID.isEmpty { lines.append("Bundle ID: \(bundleID)") }
        }

        let ax = axContext
        if !ax.isEmpty {
            if lines.isEmpty { lines.append("## Frontmost App Context") }
            lines.append(ax.contextSummary)
        }

        // Browser in front but no address resolved: say so. Silence let the model fill the gap
        // from page text or the window title and present the result as the URL.
        if isContextDockBrowserBundle(bundleID),
            !AXContext.looksLikeWebAddress(ax.currentURL ?? "")
        {
            if lines.isEmpty { lines.append("## Frontmost App Context") }
            lines.append(
                "Current URL: unavailable — the page address could not be read. "
                + "Say it is unavailable; never infer or reconstruct it.")
        }

        if !adapterContextData.isEmpty {
            if lines.isEmpty { lines.append("## Frontmost App Context") }
            lines.append("## Deep Local App Context")
            lines.append(adapterContextData.values.joined(separator: "\n"))
        }

        let enabledMenuItems =
            liveMenuItems
            .filter { $0.isEnabled && !isAppleMenuItem($0) && !$0.pathString.isEmpty }
            .prefix(45)
        if !enabledMenuItems.isEmpty {
            if lines.isEmpty { lines.append("## Frontmost App Context") }
            lines.append("## Frontmost App Menu Actions")
            for item in enabledMenuItems {
                let shortcut = item.shortcutDisplay.map { " [\($0)]" } ?? ""
                lines.append("- \(item.pathString)\(shortcut)")
            }
        } else if let app = AppDelegate.shared?.previousFrontmostApp {
            let cachedBlock = AppMenuCapabilityCache.shared.contextBlock(
                for: app,
                query: "",
                maxResults: 45
            )
            if !cachedBlock.isEmpty {
                if lines.isEmpty { lines.append("## Frontmost App Context") }
                lines.append(cachedBlock)
            }
        }

        return lines.joined(separator: "\n")
    }

    func handleL2Query() {
        handleL2Query(searchState.query.trimmingCharacters(in: .whitespaces))
    }

    func contextualCLIPackages(for context: SearchContextApp?, query: String)
        -> [TerminalPackage]
    {
        guard let context, context.resultType == .application else { return [] }
        let appPath = context.appPath.isEmpty ? (context.filePath ?? "") : context.appPath
        guard !appPath.isEmpty,
            let bundleId = Bundle(path: appPath)?.bundleIdentifier
        else {
            return []
        }
        return terminalPackageManager.packages(
            forContextBundleId: bundleId,
            query: query,
            maxResults: 5
        )
    }

    func appPanelCLIDocumentation(for package: TerminalPackage) -> String {
        var doc = "### \(package.command) [CLI]"
        if let path = package.installedPath, !path.isEmpty {
            doc += " at \(path)"
        }
        if let helpText = package.helpText, !helpText.isEmpty {
            doc += "\n" + String(helpText.prefix(1000))
        } else if !package.description.isEmpty {
            doc += "\n" + package.description
        } else {
            doc +=
                "\nUNKNOWN: Call run_command(\"\(package.command) --help\") first, read output, then answer."
        }
        if !package.usageExamples.isEmpty {
            doc += "\nExamples: " + package.usageExamples.prefix(4).joined(separator: " | ")
        }
        return doc
    }

    func appPanelCLIIntentLine(for package: TerminalPackage) -> String {
        if !package.taskCategories.isEmpty {
            return "• \(package.command): "
                + package.taskCategories.prefix(4).joined(separator: " | ")
        }
        if !package.subcommands.isEmpty {
            return "• \(package.command): " + package.subcommands.prefix(6).joined(separator: " | ")
        }
        return "• \(package.command): run_command(\"\(package.command) \\\"<full user query>\\\"\")"
    }

    func dockScopedCLIDocumentation(for package: TerminalPackage) -> String {
        var doc = "### \(package.command) [CLI]"
        if let path = package.installedPath, !path.isEmpty {
            doc += " at \(path)"
        }
        if let helpText = package.helpText, !helpText.isEmpty {
            doc += "\n" + String(helpText.prefix(1000))
        } else if !package.subcommands.isEmpty {
            doc += "\nSubcommands (always include a space between command and subcommand):\n"
            doc += package.subcommands.map { "  \(package.command) \($0)" }.joined(separator: "\n")
            if !package.description.isEmpty { doc += "\n" + package.description }
        } else if !package.description.isEmpty {
            doc += "\n" + package.description
        } else {
            doc += "\nIf syntax is unclear, inspect `\(package.command) --help` before acting."
        }
        if !package.usageExamples.isEmpty {
            doc += "\nExamples: " + package.usageExamples.prefix(4).joined(separator: " | ")
        }
        return doc
    }

    func dockScopedCLIIntentLine(for package: TerminalPackage) -> String {
        if !package.taskCategories.isEmpty {
            return "• \(package.command): "
                + package.taskCategories.prefix(4).joined(separator: " | ")
        }
        if !package.subcommands.isEmpty {
            return "• Exact commands: "
                + package.subcommands.prefix(6).map { "\(package.command) \($0)" }.joined(
                    separator: " | ")
        }
        return
            "• \(package.command): inspect `\(package.command) --help` or run the appropriate subcommand in the current dock terminal"
    }

    func dockScopedCLIContextPrompt(
        for query: String,
        scope: DockScopeResolution? = nil
    ) -> String {
        let resolvedScope = scope ?? resolveDockScope(for: query)
        guard !resolvedScope.isGlobalScope else { return "" }

        let scopedBundleId = resolvedScope.scopedBundleId.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let scopedAppName = resolvedScope.scopedAppName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !scopedBundleId.isEmpty, !scopedAppName.isEmpty else { return "" }

        let scopedQuery = resolvedScope.scopedSearchQuery.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let matchedScopedPackages = terminalPackageManager.packages(
            forContextBundleId: scopedBundleId,
            query: scopedQuery,
            maxResults: scopedQuery.isEmpty ? 6 : 4
        )
        let allScopedPackages = terminalPackageManager.packages(
            forContextBundleId: scopedBundleId,
            query: "",
            maxResults: 6
        )
        let scopedPackages = matchedScopedPackages.isEmpty ? allScopedPackages : matchedScopedPackages
        let scopedAdapterActions =
            scopedQuery.isEmpty
            ? adapterManager.actions(for: scopedBundleId)
            : adapterManager.actions(for: scopedBundleId, query: scopedQuery)

        var seenCommands = Set<String>()
        var documentationBlocks: [String] = []
        var intentLines: [String] = []

        func appendCommand(_ command: String) {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            let normalized = trimmed.lowercased()
            guard seenCommands.insert(normalized).inserted else { return }

            if let package =
                scopedPackages.first(where: {
                    $0.command.caseInsensitiveCompare(trimmed) == .orderedSame
                        || $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
                })
                ?? terminalPackageManager.packages.first(where: {
                    $0.command.caseInsensitiveCompare(trimmed) == .orderedSame
                        || $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
                })
            {
                documentationBlocks.append(dockScopedCLIDocumentation(for: package))
                intentLines.append(dockScopedCLIIntentLine(for: package))
                return
            }

            documentationBlocks.append(
                """
                ### \(trimmed) [CLI]
                User configured this command for \(scopedAppName).
                Keep CLI guidance and execution in the current dock terminal.
                If syntax is unclear, inspect `\(trimmed) --help` before acting.
                """
            )
            intentLines.append(
                "• \(trimmed): use this attached CLI in the current dock terminal when it fits the request"
            )
        }

        for action in scopedAdapterActions where action.type == .cliTool {
            appendCommand(action.cliToolCommand ?? "")
        }
        for package in scopedPackages {
            appendCommand(package.command)
        }

        guard !documentationBlocks.isEmpty else { return "" }

        var lines: [String] = [
            "## Scoped CLI Context",
            "The user is scoped to \(scopedAppName) in the current dock.",
            "Answer only for \(scopedAppName)'s app context unless the user explicitly asks to leave this scope.",
            "Use only the CLI tools listed in this scoped block for command execution. Do not use unrelated app actions, Finder actions, or global trigger rules for this scoped chat.",
            "Keep CLI guidance and execution in this dock terminal. Do not switch to or mention a separate CLI or app panel.",
            "",
            documentationBlocks.joined(separator: "\n\n"),
        ]
        if !intentLines.isEmpty {
            lines.append("")
            lines.append("Preferred entry points:")
            lines.append(intentLines.joined(separator: "\n"))
        }
        lines.append("")
        lines.append(
            "If no scoped CLI fits, fall back to app-scoped reasoning for \(scopedAppName). When the provider is On-Device, continue using Foundation Models in this same dock."
        )
        lines.append("")
        lines.append(
            "IMPORTANT: When the request warrants a CLI command, output one exact JSON line: {\"terminal_call\":{\"command\":\"pear list-orphaned\",\"purpose\":\"List orphaned packages\"}}. Never place executable requests in prose or code fences."
        )
        lines.append(
            "NEVER invent placeholder values like CURRENT_VIDEO_URL or <url>. When the context includes a CURRENT PAGE URL, paste that exact URL into the command. If a required value is genuinely missing from the context, ask the user for it instead of emitting a command."
        )
        return lines.joined(separator: "\n")
    }

    func runtimeAppCLIContextPrompt(
        bundleId: String,
        appName: String,
        query: String
    ) async -> String {
        let normalizedApp = "\(bundleId) \(appName)".lowercased()
        if normalizedApp.contains("vscode") || bundleId == "com.microsoft.VSCode" {
            return await vsCodeRuntimeContextPrompt(query: query)
        }
        if bundleId == "com.apple.MobileSMS" {
            return await messagesRuntimeContextPrompt(query: query)
        }
        guard normalizedApp.contains("tailscale") else { return "" }

        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let wantsNetworkDiagnostics =
            q.contains("why") || q.contains("connect") || q.contains("network")
            || q.contains("status") || q.contains("ip") || q.contains("tailnet")
            || q.contains("lock") || q.contains("funnel") || q.contains("serve")

        var commands: [(String, String)] = [
            ("tailscale status", "Read Tailscale connection and peer status"),
            ("tailscale ip", "Read Tailscale IP addresses"),
        ]
        if wantsNetworkDiagnostics {
            commands.append(("tailscale netcheck", "Read Tailscale network diagnostics"))
            commands.append(("tailscale lock status", "Read Tailnet Lock status"))
        }

        var blocks: [String] = []
        for (command, purpose) in commands {
            let result = await TerminalCommandExecutor.shared.run(command, purpose: purpose)
            let status = result.success ? "success" : "failed"
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            blocks.append(
                """
                $ \(command) [\(status)]
                \(String(output.prefix(2000)))
                """
            )
        }

        guard !blocks.isEmpty else { return "" }
        return """
        ## Live Tailscale CLI Snapshot
        Read-only commands were run because the frontmost/scoped app is Tailscale.
        Use this as factual app state. Do not claim GUI-only state when CLI output disagrees.
        State-changing Tailscale commands such as `tailscale up`, `tailscale down`, `tailscale logout`, or `tailscale set ...` still require explicit user approval.

        \(blocks.joined(separator: "\n\n"))
        """
    }

    /// Live Messages state via the linked imsg CLI: recent chats for read-style
    /// queries, plus an exact-syntax cheatsheet so the AI emits correct commands.
    /// Detects the chat.db Full Disk Access failure and tells the AI to explain it.
    func messagesRuntimeContextPrompt(query: String) async -> String {
        guard let imsg = TerminalPackageManager.shared.packages.first(where: {
            $0.command == "imsg" && $0.isInstalled
                && $0.contextAppBundleIds.contains("com.apple.MobileSMS")
        }) else { return "" }
        let binary = imsg.installedPath ?? "imsg"

        var lines: [String] = [
            "## Messages CLI (imsg) — exact syntax",
            "- List recent conversations: \(binary) chats --limit 12",
            "- Read a conversation: \(binary) history --chat-id <rowid from chats> --limit 20",
            "- Send a message: \(binary) send --to \"<phone or email>\" --text \"<message>\"",
            "Always resolve the chat-id via `chats` first when the user names a person.",
            "Sending always needs the user's approval — propose the CMD line, never assume.",
        ]

        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let wantsRead =
            q.contains("chat") || q.contains("message") || q.contains("recent")
            || q.contains("unread") || q.contains("said") || q.contains("conversation")
            || q.contains("history") || q.contains("who") || q.contains("what")
        if wantsRead {
            let result = await TerminalCommandExecutor.shared.run(
                "\"\(binary)\" chats --limit 12", purpose: "List recent Messages conversations")
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if output.lowercased().contains("permissiondenied")
                || output.lowercased().contains("authorization denied")
            {
                lines.append("")
                lines.append(
                    "IMPORTANT: imsg cannot read chat.db — this Mac has not granted the launcher "
                    + "Full Disk Access. Tell the user: System Settings → Privacy & Security → "
                    + "Full Disk Access → enable Context-Dock, then relaunch it. Do not claim "
                    + "Messages is unsupported.")
            } else if result.success, !output.isEmpty {
                lines.append("")
                lines.append("## Live recent conversations (`imsg chats`)")
                lines.append(String(output.prefix(2_500)))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Live VS Code state: `code --status` prints the running instance's workspace
    /// folders and open windows — so "what am I working with?" is answered with real
    /// data instead of asking the user. Read-only, runs only for state-style queries.
    func vsCodeRuntimeContextPrompt(query: String) async -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let wantsState =
            q.contains("work") || q.contains("project") || q.contains("workspace")
            || q.contains("file") || q.contains("open") || q.contains("folder")
            || q.contains("what") || q.contains("which") || q.contains("current")
        guard wantsState else { return "" }

        // The `code` shim often isn't on PATH — use the linked package's resolved
        // binary (app-bundle path needs quoting for its spaces).
        let codeBinary = TerminalPackageManager.shared.packages.first {
            $0.command == "code" && $0.isInstalled
        }?.installedPath
        let codeInvocation = codeBinary.map { "\"\($0)\"" } ?? "code"
        let result = await TerminalCommandExecutor.shared.run(
            "\(codeInvocation) --status", purpose: "Read VS Code workspace and window state")
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.success, !output.isEmpty else { return "" }
        return """
        ## Live VS Code Snapshot (`code --status`)
        Read-only output from the running VS Code instance. The "Workspace Stats" \
        section lists the folders and windows actually open — use it as factual state.

        \(String(output.prefix(3000)))
        """
    }

    /// Decodes typed `terminal_call` JSON lines, strips them from the displayed message,
    /// and appends inline approval cards that run in the scoped dock terminal.
    @MainActor
    func extractAndInsertDockApprovalCards(
        from response: String,
        intoMessageAt msgId: UUID
    ) {
        var cleanedLines: [String] = []
        var extractedCmds: [(command: String, purpose: String)] = []
        var lastNonCmdLine = ""

        for line in response.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let invocation = AITypedInvocationResolver.terminalInvocation(from: trimmed),
                let command = invocation.arguments["command"]
            {
                extractedCmds.append((
                    command,
                    invocation.arguments["purpose"] ?? lastNonCmdLine
                ))
            } else {
                cleanedLines.append(line)
                if !trimmed.isEmpty { lastNonCmdLine = trimmed }
            }
        }

        guard !extractedCmds.isEmpty else { return }

        // Strip typed invocation lines from the displayed message; keep explanation if any.
        var cleanedResponse = cleanedLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedResponse.isEmpty {
            cleanedResponse =
                extractedCmds.count == 1
                ? "Here's the command to run:"
                : "Here are the commands to run:"
        }
        if let idx = l2.chatMessages.firstIndex(where: { $0.id == msgId }) {
            l2.chatMessages[idx] = AIChatMessage(
                id: msgId, role: .assistant, content: cleanedResponse)
        }

        // Append one approval card per command
        for (cmd, purpose) in extractedCmds {
            let card = AIChatMessage(
                role: .approval,
                content: cmd,
                structuredData: "dock_cmd|||\(purpose)"
            )
            l2.chatMessages.append(card)
        }
    }

    func attachCLIToolToCurrentDock(
        command: String,
        package: TerminalPackage? = nil,
        bundleIdentifier: String? = nil,
        appName: String? = nil,
        runImmediately: Bool = false
    ) {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return }

        if let bundleIdentifier,
            let appName,
            !bundleIdentifier.isEmpty,
            !appName.isEmpty
        {
            _ = activateInlineDockAppScope(
                bundleIdentifier: bundleIdentifier,
                appName: appName
            )
        } else {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
                showContextInDock = true
                aiMode.isActive = false
                isSearchBarExpanded = true
            }
            if l2.activeDockSessionKey == nil {
                syncL2DockSession(force: true)
            }
        }

        let resolvedPackage =
            package
            ?? terminalPackageManager.packages.first(where: {
                $0.command.caseInsensitiveCompare(trimmedCommand) == .orderedSame
                    || $0.name.caseInsensitiveCompare(trimmedCommand) == .orderedSame
            })

        if let resolvedPackage,
            resolvedPackage.helpText?.isEmpty != false
        {
            Task {
                await TerminalPackageManager.shared.refreshHelpTextByCommand(
                    resolvedPackage.command)
            }
        }

        let consoleKey = prepareScopedWorkspaceTerminal()
        let term = panelTerminal(for: consoleKey)
        showLivePanel(.terminal)
        isSearchFieldFocused = true

        if runImmediately {
            term.sendCommand(trimmedCommand)
            let runMsg = "Running `\(trimmedCommand)` in terminal"
            if l2.chatMessages.last?.content != runMsg {
                l2.chatMessages.append(AIChatMessage(role: .assistant, content: runMsg))
            }
            return
        }

        var messageLines = ["Attached CLI ready in this dock: `\(trimmedCommand)`"]
        if let description = resolvedPackage?.description,
            !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            messageLines.append(description)
        } else if let path = resolvedPackage?.installedPath, !path.isEmpty {
            messageLines.append("Path: `\(path)`")
        }
        if let example = resolvedPackage?.usageExamples.first,
            !example.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            messageLines.append("Example: `\(example)`")
        }

        let message = messageLines.joined(separator: "\n")
        if l2.chatMessages.last?.content != message {
            l2.chatMessages.append(
                AIChatMessage(role: .assistant, content: message)
            )
        }
    }

    func beginL2AIRequest() -> UUID {
        let requestID = UUID()
        l2.activeRequestID = requestID
        return requestID
    }

    func finishL2AIRequest(_ requestID: UUID) {
        guard l2.activeRequestID == requestID else { return }
        l2.activeRequestID = nil
        l2.isLoading = false
        l2.loadingStatus = nil
        l2.currentTask = nil
    }

    @MainActor
    func setL2LoadingStatus(_ status: String?, requestID: UUID) {
        guard l2.activeRequestID == requestID, l2.isLoading else { return }
        l2.loadingStatus = status
    }

    func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    func handleL2TaskControlQueryIfNeeded(_ query: String) -> Bool {
        let normalized =
            query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }

        let stopTerms = [
            "stop current task", "stop task", "cancel current task", "cancel task",
            "abort current task", "abort task", "stop running", "cancel running",
            "kill current task", "interrupt",
        ]
        let rerunTerms = [
            "run again", "rerun", "re-run", "retry", "try again",
            "start again", "restart task", "run it again",
        ]

        let wantsStop =
            stopTerms.contains { normalized.contains($0) }
            || normalized == "stop"
            || normalized == "cancel"
        let wantsRerun = rerunTerms.contains { normalized.contains($0) }

        guard wantsStop || wantsRerun else { return false }

        l2.chatMessages.append(AIChatMessage(role: .user, content: query))
        stopActiveDockWork(showToast: true)
        searchState.query = ""

        guard wantsRerun else {
            l2.chatMessages.append(
                AIChatMessage(role: .assistant, content: "Stopped the current task.")
            )
            return true
        }

        if let rerunQuery = l2.lastRunnableQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rerunQuery.isEmpty,
            rerunQuery.lowercased() != normalized
        {
            l2.chatMessages.append(
                AIChatMessage(
                    role: .assistant, content: "Stopped it. Running again: `\(rerunQuery)`")
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                self.handleL2Query(rerunQuery)
            }
            return true
        }

        if let lastCommand = TerminalAIBridge.shared.executionHistory.last?.command
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !lastCommand.isEmpty
        {
            l2.chatMessages.append(
                AIChatMessage(
                    role: .assistant,
                    content: "Stopped it. Running command again:\n```bash\n\(lastCommand)\n```")
            )
            l2.isLoading = true
            l2.currentTask = Task {
                let result = await TerminalCommandExecutor.shared.run(
                    lastCommand,
                    purpose: "Run previous command again"
                )
                await MainActor.run {
                    self.l2.chatMessages.append(
                        AIChatMessage(
                            role: .assistant,
                            content:
                                "\(result.success ? "Done" : "Failed"):\n```\n\(result.output)\n```",
                            isError: !result.success
                        )
                    )
                    self.l2.isLoading = false
                    self.l2.currentTask = nil
                }
            }
            return true
        }

        l2.chatMessages.append(
            AIChatMessage(
                role: .assistant,
                content:
                    "Stopped the current task. I don't have a previous request to run again yet."
            )
        )
        return true
    }

    func stopActiveDockWork(showToast: Bool) {
        l2.currentTask?.cancel()
        l2.currentTask = nil
        l2.activeRequestID = nil
        l2.isLoading = false

        remPanelAITask?.cancel()
        remPanelAITask = nil
        remPanelIsProcessing = false

        aiMode.currentTask?.cancel()
        aiMode.currentTask = nil
        aiMode.isLoading = false

        pendingTerminalCommand = nil
        TerminalAIBridge.shared.denyCommand()

        let activeWorkers = BackgroundWorkerPool.shared.activeWorkers
        let hasPTYWorkers = activeWorkers.contains { $0.isPTY }
        if hasPTYWorkers {
            TerminalAIBridge.shared.terminalController?.sendKeys("\u{03}")
            for controller in panelTerminalControllers.values {
                controller.sendKeys("\u{03}")
            }
        }
        for worker in activeWorkers {
            BackgroundWorkerPool.shared.terminate(worker.id)
        }

        if hasPTYWorkers || !activeWorkers.isEmpty {
            showLivePanel(.terminal)
        }
        if showToast {
            AppToast.show(
                activeWorkers.isEmpty
                    ? "Task stopped"
                    : "Stopped \(activeWorkers.count) task\(activeWorkers.count == 1 ? "" : "s")",
                icon: "stop.circle",
                tint: .orange.opacity(0.95)
            )
        }
    }

    /// Called when MenuIntentRouter found no menu match — skips menu routing to avoid recursion.
    func handleL2QuerySkippingMenuRouter(_ query: String) {
        handleL2Query(query, skipMenuRouter: true)
    }

    /// Closes the offered capability gap, then re-runs the request that exposed it — so the user
    /// presses one button and gets the thing they asked for, not a confirmation dialog and a
    /// second attempt they have to type again.
    func resolveCapabilityGap(_ gap: CapabilityGapService.Gap) {
        guard !capabilityGapWorking else { return }
        capabilityGapWorking = true
        let service = CapabilityGapService.shared

        switch gap.resolution {
        case .linkInstalledTool(let packageID, let command, _):
            service.link(packageID: packageID, to: gap.bundleID)
            finishCapabilityGap(gap, note: "Linked \(command) to \(gap.appName).")

        case .installTool(let command, let formula, _):
            Task { @MainActor in
                l2.isLoading = true
                l2.loadingStatus = "Installing \(formula)…"
                // Runs through the normal command approval + execution path, so the user still
                // sees and approves the exact brew command.
                let result = await TerminalAIBridge.shared.processAICommand(
                    "brew install \(formula)",
                    purpose: "Install \(formula) so \(gap.appName) can \(gap.query)")
                l2.loadingStatus = nil
                l2.isLoading = false
                guard result.success else {
                    capabilityGapWorking = false
                    l2.chatMessages.append(
                        AIChatMessage(
                            role: .assistant,
                            content: "\(formula) was not installed, so nothing ran.\n\n"
                                + String(result.output.prefix(600)),
                            isError: true))
                    pendingCapabilityGap = nil
                    persistActiveL2DockSession()
                    requestWindowSizeUpdate(reason: .chatChanged)
                    return
                }
                // Pick the new binary up before linking it.
                _ = await TerminalPackageManager.shared.scanForInstalledTools()
                let linked = service.linkCommand(command, to: gap.bundleID)
                finishCapabilityGap(
                    gap,
                    note: linked
                        ? "Installed \(formula) and linked \(command) to \(gap.appName)."
                        : "Installed \(formula). It could not be linked automatically — add it in Settings → Automation → CLI Tools.")
            }
        }
    }

    private func finishCapabilityGap(_ gap: CapabilityGapService.Gap, note: String) {
        capabilityGapWorking = false
        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
            pendingCapabilityGap = nil
        }
        l2.chatMessages.append(AIChatMessage(role: .assistant, content: note))
        persistActiveL2DockSession()
        // Re-run the original request now that the scope owns the tool.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.handleL2Query(gap.query, skipMenuRouter: true)
        }
    }

    func dismissCapabilityGap() {
        capabilityGapWorking = false
        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
            pendingCapabilityGap = nil
        }
        requestWindowSizeUpdate(reason: .chatChanged)
    }

    func handleL2Query(_ query: String) {
        handleL2Query(query, skipMenuRouter: false)
    }

    func isExplicitAppFindCommand(_ query: String, rawScopedQuery: String) -> Bool {
        let candidates = [query, rawScopedQuery]
            .map { normalizedDockPillText($0) }
            .filter { !$0.isEmpty }

        let explicitPatterns = [
            #"^(open|show|use)\s+(app\s+)?find\b"#,
            #"^(open|show|use)\s+(app\s+)?search\b"#,
            #"^(find|search|lookup|look\s+for)\s+.+\s+(in|inside|within)\s+(this\s+)?(app|application|window)\b"#,
            #"^(find|search|lookup|look\s+for)\s+(in|inside|within)\s+(this\s+)?(app|application|window)\b"#,
            #"^(app|application|window)\s+(find|search)\b"#,
            #"^(find|search)\s+(menu|menus|command|commands)\b"#,
        ]

        return candidates.contains { candidate in
            explicitPatterns.contains { pattern in
                candidate.range(of: pattern, options: .regularExpression) != nil
            }
        }
    }

    /// Fuzzy-match query against Context Trigger rule names. If a rule matches:
    ///   - conditions pass  → execute its first pill, show "Running…" in chat
    ///   - conditions fail  → show a contextual hint about what's needed
    /// Returns true if the query was handled (caller should return immediately).
    @discardableResult
    func tryExecuteTriggerRuleByName(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.count >= 3 else { return false }

        let rules = AppSettings.shared.axTriggerRules.filter { $0.isEnabled && !$0.pills.isEmpty }
        guard !rules.isEmpty else { return false }

        func triggerTokens(_ text: String) -> [String] {
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { token in
                    token.count >= 3
                        && !["the", "and", "for", "with", "from", "this", "that", "into", "what", "when", "where", "how", "why"].contains(token)
                }
        }

        func matchScore(_ ruleName: String) -> Int {
            let n = ruleName.lowercased()
            if n == q { return 100 }
            if q.count >= 8, q.contains(n) || n.contains(q) { return 80 }
            let nameWords = triggerTokens(n)
            let queryWords = triggerTokens(q)
            guard !nameWords.isEmpty, !queryWords.isEmpty else { return 0 }
            let hits = nameWords.filter { nw in
                queryWords.contains { qw in
                    qw == nw || (qw.count >= 4 && nw.hasPrefix(qw)) || (nw.count >= 4 && qw.hasPrefix(nw))
                }
            }.count
            return hits > 0 ? hits * 20 : 0
        }

        let candidates =
            rules
            .compactMap { r -> (AXTriggerRule, Int)? in
                let s = matchScore(r.name)
                return s >= 20 ? (r, s) : nil
            }
            .sorted { $0.1 > $1.1 }

        guard let (bestRule, bestScore) = candidates.first else { return false }

        // Augment AX context with the browser bridge URL when the dock is frontmost
        // (AXContextReader sees the dock as active app, losing the prior Safari URL).
        var ctx = AXContextReader.shared.current
        if (ctx.currentURL ?? "").isEmpty,
            let bCtx = SafariBrowserBridge.shared.currentContext(), !bCtx.url.isEmpty
        {
            ctx.currentURL = bCtx.url
            ctx.windowTitle = ctx.windowTitle ?? bCtx.title
        }

        let resolved = AXTriggerRuleEngine.shared.evaluate(rule: bestRule, context: ctx)

        if let first = resolved.first {
            AppToast.show(
                "Running \(bestRule.name)…", icon: "bolt.fill", tint: .blue.opacity(0.9),
                duration: 2.0, centered: true)
            searchState.query = ""
            first.execute()
            return true
        }

        // Conditions didn't pass. Only surface the "needs X to run" message when the
        // user clearly invoked the rule by name (strong match). A weak token overlap
        // ("download this image" hitting "Download Video") must NOT hijack the chat —
        // fall through so the AI / scoped CLI can handle the request instead.
        guard bestScore >= 60 else { return false }
        let urlConditions = bestRule.conditions.filter { $0.field == .currentURL }
        let hint: String
        if !urlConditions.isEmpty {
            let sites = urlConditions.map { $0.value }.joined(separator: ", ")
            hint = "a page matching \(sites)"
        } else {
            let parts = bestRule.conditions.compactMap { c -> String? in
                switch c.field {
                case .appName: return "the \"\(c.value)\" app"
                case .filePath: return "a \(c.value) file selected"
                case .selectedText: return "text selected"
                default: return nil
                }
            }
            hint = parts.isEmpty ? "the right context" : parts.joined(separator: " or ")
        }
        l2.chatMessages.append(AIChatMessage(role: .user, content: query))
        l2.chatMessages.append(
            AIChatMessage(
                role: .assistant,
                content:
                    "**\(bestRule.name)** needs \(hint) to run. Open the right page first, then try again."
            ))
        searchState.query = ""
        return true
    }

    /// Match query against SystemCommandsRegistry. Execute immediately if found.
    @discardableResult
    func trySystemCommand(_ query: String) -> Bool {
        guard isGlobalContextActive,
            !aiMode.isActive,
            searchState.activeSmartQueryKey == nil,
            !isCompactSmartScope,
            !l2.chatArmed,
            !l2.showChatPopover
        else { return false }
        guard let cmd = SystemCommandsRegistry.shared.bestMatch(for: query) else { return false }
        searchState.query = ""
        runSystemCommand(cmd, originalQuery: query)
        return true
    }

    func tryHandleNotesMCPQuery(_ query: String, scopedBundleId: String) -> Bool {
        guard scopedBundleId == "com.apple.Notes",
              AppSettings.shared.noteMCPEnabled
        else { return false }

        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let wantsCount = normalized.contains("how many")
            || normalized.contains("count")
            || normalized.contains("number of")
        let wantsSearch = normalized.contains("find")
            || normalized.contains("search")
            || normalized.hasPrefix("any ")
            || normalized.contains(" any ")
            || normalized.contains("with ")
            || normalized.contains("link")
            || normalized.contains("url")
        guard wantsCount || wantsSearch else { return false }

        let userMessage = AIChatMessage(role: .user, content: query)
        l2.chatMessages.append(userMessage)
        l2.isLoading = true
        l2.loadingStatus = "Looking at Notes capabilities…"
        let requestID = beginL2AIRequest()

        l2.currentTask = Task {
            do {
                let response: String
                if wantsCount && !wantsSearch {
                    // Single Apple Event — no full metadata refresh for a count question.
                    let count = try await AppleNotesMCPServer.shared.noteCount()
                    response = "There are \(count) notes."
                } else {
                    let notes = try await AppleNotesMCPServer.shared.allMetadata()
                    let searchTerm = notesSearchTerm(from: normalized)
                    let matches = searchTerm.isEmpty
                        ? notes
                        : try await AppleNotesMCPServer.shared.search(
                            query: searchTerm, maxResults: 8)
                    response = formatNotesSearchResponse(matches, query: searchTerm)
                }
                await MainActor.run {
                    l2.isLoading = false
                    l2.chatMessages.append(
                        AIChatMessage(role: .assistant, content: response, mcpToolsRan: ["DoraX Notes MCP"])
                    )
                    finishL2AIRequest(requestID)
                }
            } catch {
                await MainActor.run {
                    l2.isLoading = false
                    l2.chatMessages.append(
                        AIChatMessage(
                            role: .assistant,
                            content: "Notes MCP failed: \(error.localizedDescription)",
                            isError: true
                        )
                    )
                    finishL2AIRequest(requestID)
                }
            }
        }
        return true
    }

    private func notesSearchTerm(from query: String) -> String {
        let cleaned = query
            .replacingOccurrences(of: "?", with: " ")
            .replacingOccurrences(of: "#", with: " ")
            .replacingOccurrences(of: "notes", with: " ")
            .replacingOccurrences(of: "note", with: " ")
            .replacingOccurrences(of: "links", with: " ")
            .replacingOccurrences(of: "link", with: " ")
            .replacingOccurrences(of: "urls", with: " ")
            .replacingOccurrences(of: "url", with: " ")
        let stopwords: Set<String> = [
            "any", "with", "there", "are", "is", "have", "has", "find", "search",
            "for", "about", "show", "me", "please", "a", "an", "the", "in", "on",
            "do", "does", "did", "how", "many", "count", "number", "of"
        ]
        return cleaned
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !stopwords.contains($0) }
            .joined(separator: " ")
    }

    private func formatNotesSearchResponse(_ matches: [NoteMetadata], query: String) -> String {
        guard !matches.isEmpty else {
            return query.isEmpty
                ? "No notes found."
                : "No notes found for \(query)."
        }
        let rows = matches.prefix(5).map { note in
            "• \(note.title) — \(note.folder)"
        }.joined(separator: "\n")
        let suffix = matches.count > 5 ? "\n+\(matches.count - 5) more" : ""
        return "Found \(matches.count) note\(matches.count == 1 ? "" : "s")\(query.isEmpty ? "" : " for \(query)"):\n\(rows)\(suffix)"
    }

    func handleL2Query(_ query: String, skipMenuRouter: Bool) {
        guard !query.isEmpty else { return }
        let wasContextDockChatActive = l2.chatArmed || l2.showChatPopover || !l2.chatMessages.isEmpty
        let trimmedSubmittedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if searchState.query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedSubmittedQuery {
            searchState.query = ""
        }
        armContextDockChat(animated: wasContextDockChatActive)
        l2.chatAutoArmedForNoMenuMatch = false
        l2.showChatPopover = true
        l2.chatDismissed = false
        if handleL2TaskControlQueryIfNeeded(query) {
            return
        }
        if let findToken = lockedFindToken {
            executeFindToken(findToken, userMessage: "find \(query)")
            return
        }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let dockScope = resolveDockScope(for: query)
        let rawScopedSearchQuery = rawScopedActionQuery(for: query, scope: dockScope)
        let scopedBundleId = dockScope.scopedBundleId.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let scopedAppName = dockScope.scopedAppName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let isExplicitScopedApp =
            dockScope.isExplicitAppScope
            && !scopedBundleId.isEmpty
            && !scopedAppName.isEmpty

        // Capability gap: the request needs a CLI this scope cannot reach. Offer the one action
        // that closes it (link it, or install then link) instead of spending a provider call on
        // an answer that can only say "open Terminal yourself".
        let gapBundleId = scopedBundleId.isEmpty ? frontmost.bundleID : scopedBundleId
        let gapAppName = scopedAppName.isEmpty ? frontmost.name : scopedAppName
        if pendingCapabilityGap == nil,
            let gap = CapabilityGapService.shared.resolve(
                query: query, bundleID: gapBundleId, appName: gapAppName)
        {
            l2.chatMessages.append(AIChatMessage(role: .user, content: query))
            withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                pendingCapabilityGap = gap
            }
            requestWindowSizeUpdate(reason: .chatChanged)
            return
        }
        // Global context + live selection or clipboard → query is about the content; skip app routing
        let globalSelectionActive =
            dockScope.isGlobalScope
            && hasSelectionScopeSurface

        // ── Detect question-style queries ─────────────────────────────────────
        let looksLikeQuestion: Bool = {
            let q = normalizedQuery
            return q.hasSuffix("?")
                || q.hasPrefix("what") || q.hasPrefix("how") || q.hasPrefix("why")
                || q.hasPrefix("tell") || q.hasPrefix("explain") || q.hasPrefix("describe")
                || q.hasPrefix("show me") || q.hasPrefix("summarize") || q.hasPrefix("who")
                || q.hasPrefix("when") || q.hasPrefix("where") || q.hasPrefix("is ")
                || q.hasPrefix("can ") || q.hasPrefix("does ") || q.hasPrefix("do ")
                || q.hasPrefix("translate") || q.hasPrefix("write") || q.hasPrefix("give me")
        }()

        let scopedHasLinkedCLI =
            !dockScope.isGlobalScope
            && !scopedBundleId.isEmpty
            && !terminalPackageManager.packages(
                forContextBundleId: scopedBundleId,
                query: "",
                maxResults: 1
            ).isEmpty
        let shouldStayInScopedAIChat =
            wasContextDockChatActive
            && !dockScope.isGlobalScope
            && !isGlobalContextActive

        if !looksLikeQuestion && !scopedHasLinkedCLI, tryExecuteTriggerRuleByName(query) { return }
        if trySystemCommand(query) { return }
        if let existingTask = l2.currentTask {
            existingTask.cancel()
            l2.currentTask = nil
            l2.isLoading = false
            l2.activeRequestID = nil
        }

        if tryHandleNotesMCPQuery(query, scopedBundleId: scopedBundleId) {
            return
        }

        // Stamp the context key when the chat starts so we can detect future context switches.
        let currentKey = contextIdentityKey(currentContext)
        if l2.chatContextKey.isEmpty || l2.chatMessages.isEmpty {
            l2.chatContextKey = currentKey == "none" ? l2.chatContextKey : currentKey
        }

        let findIntentMustBeExplicit =
            wasContextDockChatActive || scopedHasLinkedCLI || looksLikeQuestion
        if (!findIntentMustBeExplicit || isExplicitAppFindCommand(query, rawScopedQuery: rawScopedSearchQuery)),
            let findIntent = resolvedFindIntent(
            for: query,
            dockScope: dockScope,
            rawScopedQuery: rawScopedSearchQuery
        ) {
            executeAppFindIntent(findIntent)
            return
        }

        // ── Menu Intent Router ────────────────────────────────────────────────
        // Only runs when:
        //   • Not explicitly skipped (recursion guard)
        //   • Query does NOT look like a question (selection-oriented questions → AI answer)
        //   • App has a cached menu snapshot to search
        let menuRouteEligible =
            !skipMenuRouter
            && !looksLikeQuestion  // question  = user wants an AI answer
            && !isGlobalContextActive  // global context already active = chat mode
            && !shouldStayInScopedAIChat  // continued scoped chat stays AI, not menu scan
        let menuRouteTarget: (bundleId: String, appName: String)? = {
            if isExplicitScopedApp {
                return (scopedBundleId, scopedAppName)
            }
            if let target = l2.targetApp, !target.bundleId.hasPrefix("scope://") {
                return (target.bundleId, target.name)
            }
            if let frontmostApp = NSWorkspace.shared.frontmostApplication,
                let bundleId = frontmostApp.bundleIdentifier,
                bundleId != Bundle.main.bundleIdentifier
            {
                return (bundleId, frontmostApp.localizedName ?? frontmost.name)
            }
            return nil
        }()
        if menuRouteEligible,
            let target = menuRouteTarget,
            target.bundleId != "com.apple.Safari",  // Safari has its own command system
            GlobalContextEngine.shared.hasMenuSnapshot(bundleIdentifier: target.bundleId)
        {
            let capturedTarget = target
            l2.isLoading = true
            let reqID = beginL2AIRequest()
            l2.currentTask = Task {
                // Find the best menu match WITHOUT activating the app (will activate on pill click)
                let runningApp = NSWorkspace.shared.runningApplications.first(where: {
                    $0.bundleIdentifier == capturedTarget.bundleId && !$0.isTerminated
                })
                if let app = runningApp,
                    let matchedItem = await MenuIntentRouter.shared.findMatch(
                        query: query, app: app)
                {
                    await MainActor.run {
                        l2.isLoading = false
                        let pid = app.processIdentifier
                        let path = matchedItem.path
                        let sc = matchedItem.shortcutChar
                        let mod = matchedItem.shortcutModifiers
                        self.pendingAIMenuProposal = AIMenuProposal(
                            path: path,
                            title: matchedItem.title,
                            fullPathLabel: matchedItem.pathString,
                            shortcutChar: sc,
                            shortcutModifiers: mod,
                            menuImage: matchedItem.image,
                            sourcePID: pid,
                            sourceBundleId: capturedTarget.bundleId,
                            sourceAppName: capturedTarget.appName
                        )
                        searchState.query = ""
                        scheduleDockPillRebuild(query: "", delayNanoseconds: 0)
                        l2.pillNavViaKeyboard = true
                        l2.focusedPillIndex = 0
                        finishL2AIRequest(reqID)
                    }
                    return
                }
                // No match or app not running — fall through to normal AI flow
                await MainActor.run {
                    l2.isLoading = false
                    finishL2AIRequest(reqID)
                    self.handleL2QuerySkippingMenuRouter(query)
                }
            }
            return
        }

        if !shouldStayInScopedAIChat, let transformIntent = transformShareIntent(for: query) {
            executeTransformShareIntent(transformIntent, userMessage: query)
            return
        }

        // ── Finder AI — natural language over current folder / selection ──────
        let allowFrontmostFinderRouting =
            !dockScope.isGlobalScope
            && !isGlobalContextActive
            && finderFolderQueryModeActive
            && isFinderFolderSearchAttached(currentFolderPath: currentFinderFolderPath())
        if allowFrontmostFinderRouting
            && ((frontmost.bundleID == "com.apple.finder" || frontmost.name == "Finder")
                || (scopedBundleId == "com.apple.finder"
                    && !dockScope.scopedSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty))
        {
            handleFinderAIQuery(query: query)
            return
        }

        if dockScope.scopedBundleId == "com.apple.MobileSMS",
            let intent = messagesScopedSemanticIntent(for: rawScopedSearchQuery)
        {
            executeCrossAppIntent(
                intent,
                userMessage: query,
                unresolvedMessage:
                    "❌ Couldn't resolve that Messages recipient. Try: message send \"hi\" to [name]"
            )
            return
        }

        if dockScope.scopedBundleId == "com.apple.mail" {
            let isMailQuestion = isQuestionStyleMailQuery(rawScopedSearchQuery)

            if frontmost.bundleID == "com.apple.mail",
                isMailQuestion,
                !isCurrentMailContextAttached()
            {
                l2.chatMessages.append(AIChatMessage(role: .user, content: query))
                l2.chatMessages.append(
                    AIChatMessage(
                        role: .assistant,
                        content:
                            "Attach Mail context with the + button first, then ask again. That keeps Mail questions local and targeted to the current mailbox."
                    ))
                searchState.query = ""
                l2.focusedPillIndex = nil
                return
            }

            if isMailQuestion, let answer = answerAttachedMailQuestion(for: rawScopedSearchQuery) {
                l2.chatMessages.append(AIChatMessage(role: .user, content: query))
                l2.chatMessages.append(AIChatMessage(role: .assistant, content: answer))
                searchState.query = ""
                l2.focusedPillIndex = nil
                return
            }

            if shouldExecuteMailMailboxSearch(for: rawScopedSearchQuery) != nil {
                Task {
                    let intent = await resolvedMailMailboxSearchIntent(for: rawScopedSearchQuery)
                    guard let intent else { return }
                    await MainActor.run {
                        self.executeMailMailboxSearch(intent: intent, userMessage: query)
                    }
                }
                return
            }
        }

        // ── Cross-app natural language ────────────────────────────────────────
        // "send this to salman", "email this to john", "open this in xcode", etc.
        let shouldSkipCrossAppMailRouting =
            dockScope.scopedBundleId == "com.apple.mail"
            && isQuestionStyleMailQuery(rawScopedSearchQuery)

        if !shouldStayInScopedAIChat,
            !shouldSkipCrossAppMailRouting,
            let intent = CrossAppNLHandler.shared.parse(normalizedQuery)
        {
            executeCrossAppIntent(intent, userMessage: query)
            return
        }

        if dockScope.isGlobalScope && !globalSelectionActive,
            let resolution =
                L2AppActionRouter.shared.resolve(query: normalizedQuery)
                ?? resolveGlobalActionQuery(query),
            !resolution.primary.usedFrontmostFallback
        {
            executeResolvedAppAction(resolution, userMessage: query)
            return
        }

        if dockScope.isGlobalScope && !globalSelectionActive,
            let target = L2AppActionRouter.shared.appScopeTarget(for: normalizedQuery),
            target.actionQuery.isEmpty
        {
            executeGlobalAppLaunch(
                bundleId: target.bundleId,
                appName: target.appName,
                userMessage: query
            )
            return
        }

        if isExplicitScopedApp {
            let wasGlobalOrNewScope =
                isGlobalContextActive || (l2.targetApp?.bundleId != scopedBundleId)
            _ = activateInlineDockAppScope(
                bundleIdentifier: scopedBundleId,
                appName: scopedAppName,
                preserveGlobalContext: isGlobalContextActive
            )
            if wasGlobalOrNewScope {
                // Re-run with the stripped scoped query after context/menus load.
                // The full query contained the app name ("safari …"); rawScopedSearchQuery
                // has "safari" stripped so the AI receives the actual intent.
                // We pass the ORIGINAL full query to handleL2Query so that find-intent
                // detection can still see the original verb (e.g. "show" in
                // "show photos of gowri" → fullQuery.hasPrefix("show ") → true).
                let rerunQuery = rawScopedSearchQuery.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                guard !rerunQuery.isEmpty else { return }
                searchState.query = rerunQuery
                let fullQueryForRerun = query
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard
                        !self.searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                    else { return }
                    self.handleL2Query(fullQueryForRerun)
                }
                return
            }
        }
        // ─────────────────────────────────────────────────────────────────────

        if let pending = pendingTerminalCommand {
            if isAffirmativeResponse(normalizedQuery) {
                pendingTerminalCommand = nil
                l2.chatMessages.append(AIChatMessage(role: .user, content: query))
                l2.isLoading = true
                l2.currentTask = Task {
                    let (success, output) = await TerminalCommandExecutor.shared.run(
                        pending.command, purpose: pending.purpose)
                    await MainActor.run {
                        let resultIcon = success ? "✅" : "❌"
                        let resultMessage = AIChatMessage(
                            role: .assistant,
                            content: "\(resultIcon) Command Result:\n```\n\(output)\n```"
                        )
                        l2.chatMessages.append(resultMessage)
                        updateL2Results(
                            buildL2OutputResults(title: "Terminal Output", output: output))
                        l2.isLoading = false
                        l2.currentTask = nil
                    }
                }
                return
            }
            if isNegativeResponse(normalizedQuery) {
                pendingTerminalCommand = nil
                l2.chatMessages.append(AIChatMessage(role: .user, content: query))
                l2.chatMessages.append(
                    AIChatMessage(role: .assistant, content: "Okay, I won't run that command."))
                return
            }
        }

        let l2RequestID = beginL2AIRequest()

        // Do not run the full context detector while SwiftUI is handling submit.
        // AX/context lifecycle updates remain authoritative; this bounded live read
        // only fills a missing selection for the request being submitted.
        if case .none = currentContext {
            if let frontmostApp = contextTargetApp(),
                let selectedText = ContextDetector.shared.getSelectedText(from: frontmostApp),
                !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                currentContext = .textSelected(selectedText)
            }
        } else if case .appFocused = currentContext {
            if let frontmostApp = contextTargetApp(),
                let selectedText = ContextDetector.shared.getSelectedText(from: frontmostApp),
                !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                currentContext = .textSelected(selectedText)
            }
        }

        if case .none = currentContext {
            let finderSelection = ContextDetector.shared.getFinderSelectedFiles()
            if !finderSelection.isEmpty {
                currentContext = .filesSelected(finderSelection)
            }
        } else if case .appFocused = currentContext {
            let finderSelection = ContextDetector.shared.getFinderSelectedFiles()
            if !finderSelection.isEmpty {
                currentContext = .filesSelected(finderSelection)
            }
        }

        let queryLower = query.lowercased()
        if queryLower.contains("pdf") {
            let finderSelection = ContextDetector.shared.getFinderSelectedFiles()
            if !finderSelection.isEmpty {
                currentContext = .filesSelected(finderSelection)
            }
        }

        // Document-based apps (Preview, TextEdit, …): no selection and no Finder
        // selection, but the app HAS an open document — read it via AXDocument so
        // "image info?" over a Preview image actually sees the image (vision) or PDF.
        switch currentContext {
        case .none, .appFocused:
            if !isContextDockBrowserBundle(frontmost.bundleID),
                !isExplicitScopedApp || scopedBundleId == frontmost.bundleID,
                let docURL = focusedDocumentURLForShareContext()
            {
                let ext = docURL.pathExtension.lowercased()
                let attachable: Set<String> = [
                    "jpg", "jpeg", "png", "gif", "bmp", "tiff", "heic", "webp",
                    "pdf", "txt", "md", "rtf", "csv", "json", "log",
                ]
                if attachable.contains(ext) {
                    currentContext = .filesSelected([docURL])
                }
            }
        default:
            break
        }

        let dockCLIContextPrompt = dockScopedCLIContextPrompt(for: query, scope: dockScope)

        // Offer to auto-create a saveable extension as a LAST RESORT for scoped ACTION
        // requests — independent of whether the app has (unrelated) CLI tools linked. The
        // appendix itself is last-resort worded and self-suppresses on questions, so it never
        // overrides an adapter/menu/tool route; it only rescues the "no route fits, don't just
        // narrate" case (e.g. "add selected text to Reminders" from Code, which has CLI tools
        // but none that create reminders).
        let proposalAppendix: String = {
            guard !dockScope.isGlobalScope else { return "" }
            let appName = dockScope.scopedAppName.isEmpty ? frontmost.name : dockScope.scopedAppName
            guard !appName.isEmpty else { return "" }
            return extensionProposalPromptAppendix(appName: appName, query: query)
        }()
        let finalContextPrompt =
            proposalAppendix.isEmpty
            ? dockCLIContextPrompt
            : (dockCLIContextPrompt.isEmpty
                ? proposalAppendix : dockCLIContextPrompt + "\n\n" + proposalAppendix)

        let scopedConversationContext = sanitizedConversationContextForScope(
            effectiveConversationUserContext,
            scopedBundleId: scopedBundleId,
            scopedAppName: scopedAppName
        )

        // Store original query for potential re-execution after extension install
        originalUserQuery = query
        l2.lastRunnableQuery = query

        // Clear search text after capturing the query
        searchState.query = ""

        dismissMediaLayer()
        if !isSearchBarExpanded {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isSearchBarExpanded = true
            }
            requestWindowSizeUpdate(reason: .rowLayoutChanged)
        }

        let frontmostName: String? = {
            guard !dockScope.isGlobalScope else { return nil }
            if isExplicitScopedApp {
                return scopedAppName
            }
            switch currentContext {
            case .appFocused(let name, _):
                return name
            default:
                return frontmost.name.isEmpty ? nil : frontmost.name
            }
        }()

        let selectedFiles: [URL] = {
            if case .filesSelected(let urls) = scopedConversationContext {
                return urls
            }
            return []
        }()

        // Extension discovery
        let matches = LayeredExtensionManager.shared.discoverExtensions(
            for: query,
            selectedFiles: selectedFiles,
            frontmostApp: frontmostName,
            layer: .l2_context
        ).filter { result in
            result.ilExtension.triggers.contains { trigger in
                if case .appContext = trigger { return true }
                return false
            }
        }

        // PDF content questions — read the file and answer directly.
        // Covers explain, summarize, describe, what is, translate, any content query.
        let isFileContentQuery =
            queryLower.contains("summarize") || queryLower.contains("summary")
            || queryLower.contains("tldr") || queryLower.contains("explain")
            || queryLower.contains("describe") || queryLower.contains("what is")
            || queryLower.contains("what does") || queryLower.contains("tell me about")
            || queryLower.contains("about this") || queryLower.contains("this file")
            || queryLower.contains("translate") || queryLower.contains("key point")
            || queryLower.contains("highlight") || queryLower.contains("overview")
            || queryLower.contains("analyse") || queryLower.contains("analyze")
        if isFileContentQuery,
            case .filesSelected(let urls) = scopedConversationContext,
            let pdf = ContextDetector.shared.analyzeFiles(urls).first(where: { $0.type == "pdf" }),
            let pdfContent = pdf.content,
            !pdfContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            l2.chatMessages.append(AIChatMessage(role: .user, content: query))
            l2.isLoading = true
            l2.currentTask = Task {
                do {
                    let prompt =
                        "Answer the user's question about this PDF document.\n\nPDF CONTENT:\n\(pdfContent)\n\nUser question: \(query)\n\nAnswer directly from the document content. Do not run any commands."
                    let response = try await sendToAIProviderWithContext(
                        query: prompt, messageHistory: l2.chatMessages)
                    if Task.isCancelled {
                        await MainActor.run { finishL2AIRequest(l2RequestID) }
                        return
                    }
                    await MainActor.run {
                        let assistantMessage = AIChatMessage(role: .assistant, content: response)
                        l2.chatMessages.append(assistantMessage)
                        finishL2AIRequest(l2RequestID)
                    }
                } catch {
                    if isCancellationError(error) {
                        await MainActor.run { finishL2AIRequest(l2RequestID) }
                        return
                    }
                    await MainActor.run {
                        let errorMessage = AIChatMessage(
                            role: .assistant,
                            content: "Sorry, I encountered an error: \(error.localizedDescription)",
                            isError: true)
                        l2.chatMessages.append(errorMessage)
                        finishL2AIRequest(l2RequestID)
                    }
                }
            }
            return
        }

        if let top = matches.first, shouldAutoRunL2Extension(query: query, ext: top.ilExtension) {
            l2.currentTask = Task {
                await executeL2Extension(top.ilExtension, context: scopedConversationContext)
                await MainActor.run { finishL2AIRequest(l2RequestID) }
            }
            return
        }

        if matches.isEmpty { updateL2Results([]) }

        // ── Ensure browser context is set correctly for Safari / Chrome ──────
        // If frontmost app is a browser but currentContext isn't .url yet, fix it now.
        let shouldUseFrontmostBrowserContext =
            scopedBundleId.isEmpty ? !isExplicitScopedApp : isContextDockBrowserBundle(scopedBundleId)
        if shouldUseFrontmostBrowserContext,
            !dockScope.isGlobalScope,
            isContextDockBrowserBundle(frontmost.bundleID)
        {
            // NEVER substitute the bundle id for an address. The old `?? frontmost.bundleID`
            // put "com.apple.Safari" into the prompt as if it were the page URL, so the model
            // either reasoned about a fake address or (correctly) called it out as a
            // placeholder. If the AX read hasn't landed, ask the browser directly; if that
            // fails too, leave the context alone so the prompt simply has no URL.
            let cachedURL = axContext.currentURL?.trimmingCharacters(in: .whitespacesAndNewlines)
            let liveURL: String? = {
                if let cachedURL, !cachedURL.isEmpty, cachedURL != frontmost.bundleID {
                    return cachedURL
                }
                return ContextDetector.shared.liveBrowserURL(bundleId: frontmost.bundleID)
            }()
            if let liveURL, !liveURL.isEmpty {
                if axContext.currentURL != liveURL { axContext.currentURL = liveURL }
                if case .url = currentContext { /* already set */
                } else {
                    currentContext = .url(liveURL)
                }
                // Prime the AXWebReader cache for on-device AI if needed
                if let browser = AppDelegate.shared?.previousFrontmostApp {
                    let pid = browser.processIdentifier
                    if AXWebReader.shared.cachedSnapshot(for: pid)?.text.isEmpty != false {
                        Task { @MainActor in
                            AXWebReader.shared.refresh(pid: pid, currentURL: liveURL)
                        }
                    }
                }
            }
        }

        // Fast-path: Safari NL commands ("search youtube for X", "close tab", etc.) skip AI entirely
        let safariCommandScopeAllowed =
            scopedBundleId == "com.apple.Safari"
            || (!isExplicitScopedApp && frontmost.bundleID == "com.apple.Safari")
        if !shouldStayInScopedAIChat,
            safariCommandScopeAllowed,
            let directCmd = SafariCommandBridge.shared.parseIntent(query)
        {
            l2.chatMessages.append(AIChatMessage(role: .user, content: query))
            finishL2AIRequest(l2RequestID)
            Task {
                let result = await SafariCommandBridge.shared.execute(directCmd)
                await MainActor.run {
                    l2.chatMessages.append(AIChatMessage(role: .assistant, content: "🌐 \(result)"))
                }
            }
            return
        }

        // Display only the user's actual query in the chat UI (not the full context prompt)
        let userMessage = AIChatMessage(role: .user, content: query)
        l2.chatMessages.append(userMessage)
        l2.isLoading = true

        // Use the user's selected AI provider in L2 context dock (respects Settings → AI Provider).
        let provider: AIProvider = settings.selectedAIProvider
        let rawKey = provider.requiresAPIKey ? AppSettings.shared.getAPIKey(for: provider) : ""
        let apiKey: String? = rawKey.isEmpty ? nil : rawKey

        // Guard: bridge/local providers use endpoint/model, not API keys.
        if provider != .onDevice && provider != .shortcuts
            && !settings.isProviderConfigured(provider)
        {
            l2.isLoading = false
            let guide = provider.requiresAPIKey
                ? QueryFailureGuide.shared.instant(
                    for: .noAPIKey(provider: provider.shortName), originalQuery: query
                )
                : "\(provider.displayName) is not configured. Check endpoint and model in Settings -> AI Provider."
            l2.chatMessages.append(AIChatMessage(role: .assistant, content: guide, isError: true))
            finishL2AIRequest(l2RequestID)
            return
        }

        // Build conversation history (clean messages only — no tool chips)
        let chatHistory: [ChatMessage] = l2.chatMessages.dropLast()
            .filter { $0.role != .tool }
            .map { ChatMessage(role: $0.role == .user ? .user : .assistant, content: $0.content) }

        l2.currentTask = Task {
            do {
                #if DEBUG
                print("🧠 [L2 AI] Provider: \(provider.shortName), tool-aware message path")
                #endif

                let historyBundle = scopedBundleId.isEmpty
                    ? frontmost.bundleID : scopedBundleId
                if self.isContextDockBrowserBundle(historyBundle),
                    self.isBrowserHistoryReadQuery(query)
                {
                    await self.setL2LoadingStatus(
                        "Reading local browser-history URLs…", requestID: l2RequestID)
                    if let historyAnswer = await self.localBrowserHistoryAnswer(
                        query: query,
                        scopedBundleId: historyBundle,
                        requireAppAdapter: false)
                    {
                        await MainActor.run {
                            l2.chatMessages.append(
                                AIChatMessage(
                                    role: .assistant,
                                    content: historyAnswer,
                                    mcpToolsRan: ["Local browser history"]))
                            finishL2AIRequest(l2RequestID)
                        }
                        return
                    }
                }

                await self.setL2LoadingStatus("Checking linked actions, CLI, and MCP…", requestID: l2RequestID)
                let runtimeCLIContextPrompt = await self.runtimeAppCLIContextPrompt(
                    bundleId: scopedBundleId,
                    appName: scopedAppName.isEmpty ? (frontmostName ?? frontmost.name) : scopedAppName,
                    query: query
                )
                // Real Apple-apps data + weather only when the scoped app or query explicitly
                // asks for those apps. Otherwise ChatGPT/Codex-style scoped chat can answer
                // "scheduled tasks" from Calendar by mistake.
                let canUseAppleAppsContext = await MainActor.run {
                    self.shouldInjectAppleAppsAndWeatherContext(
                        for: query,
                        scopedBundleId: scopedBundleId,
                        scopedAppName: scopedAppName
                    )
                }
                let appleData = canUseAppleAppsContext
                    ? await self.appleAppsAndWeatherContext(for: query)
                    : ""
                // Live MCP tools linked to this app (App Adapters → Linked MCP).
                let mcpBlock = await MCPRuntime.shared.toolPromptBlock(forBundleId: scopedBundleId)
                // Live browser page (URL + text + selection) from the Safari Web
                // Extension, so every provider can answer "summarize this page",
                // pass the video URL to yt-dlp, etc. — without a page-reading tool.
                let browserPageBlock = await MainActor.run {
                    self.browserScopeContextBlock(scopedBundleId: scopedBundleId)
                }
                // Adapter Skills — reusable instruction bundles for this app, fed
                // as extra AI context (never executable).
                let skillsBlock = await MainActor.run {
                    SkillStore.shared.instructionsBlock(for: scopedBundleId)
                }
                // Always-present identity + tool inventory: WHICH app this chat is
                // scoped to and every integration it can use. Without this the model
                // claims it "cannot see which app is open".
                let identityBlock = await MainActor.run {
                    self.scopedAppIdentityBlock(
                        bundleId: scopedBundleId,
                        appName: scopedAppName.isEmpty
                            ? (frontmostName ?? frontmost.name) : scopedAppName
                    )
                }
                // Capture Text / screenshots / uploaded files attached via the + menu — inject
                // so the scoped agentic model actually receives what the user captured (images
                // are OCR'd since sendWithTools can't send vision). Without this the chip showed
                // but the content never reached the model.
                let attachmentBlock = contextDockChatAttachmentPromptBlock()
                // Image captures/uploads go to the model as REAL vision (not just OCR) for
                // vision-capable cloud providers via sendWithTools(imageAttachments:).
                let scopedImageExts: Set<String> = [
                    "png", "jpg", "jpeg", "gif", "bmp", "tiff", "heic", "webp",
                ]
                let scopedImageAttachments = contextDockChatFiles.filter {
                    scopedImageExts.contains($0.pathExtension.lowercased())
                }
                let activeContextPrompt = [
                    identityBlock, finalContextPrompt, runtimeCLIContextPrompt, appleData,
                    mcpBlock, browserPageBlock, skillsBlock, attachmentBlock,
                ]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")

                if let guardedAnswer = await MainActor.run(body: {
                    self.scopedChatMissingInternalDataAnswer(
                        query: query,
                        bundleId: scopedBundleId,
                        appName: scopedAppName.isEmpty
                            ? (frontmostName ?? frontmost.name) : scopedAppName
                    )
                }) {
                    await MainActor.run {
                        l2.chatMessages.append(
                            AIChatMessage(role: .assistant, content: guardedAnswer))
                        finishL2AIRequest(l2RequestID)
                    }
                    return
                }

                if provider != .onDevice && provider != .shortcuts {
                    // Collects MCP tools the model invokes via the tool loop, for the chip.
                    let mcpRan = MCPRunCollector()
                    let commandExecutor: (String, String) async -> (Bool, String) = {
                        command, purpose in
                        // Run an installed adapter action (New Board, Zoom, Delete, deep link,
                        // shortcut, script) directly — this is the native route the model is told
                        // to prefer over terminal. AppAdapterManager.execute shows its own approval
                        // panel for actions flagged requiresApproval/isDestructive.
                        // Click a verified app menu item (Minimize, New Tab, Export…) — the
                        // universal control surface. Works for any app even with zero linked
                        // adapters, so the chat DOES the task instead of narrating a shortcut.
                        if let invocation = AITypedInvocationResolver.invocation(from: command),
                           invocation.kind == .menuAction {
                            let path = (invocation.arguments["path"] ?? "")
                                .components(separatedBy: "\u{1F}")
                                .filter { !$0.isEmpty }
                            let bundle = (invocation.arguments["bundleId"].flatMap {
                                $0.isEmpty ? nil : $0 }) ?? scopedBundleId
                            guard !path.isEmpty else {
                                return (false, "No menu path given.")
                            }
                            await self.setL2LoadingStatus(
                                "Running \(path.joined(separator: " ▸ "))…", requestID: l2RequestID)
                            let (ok, out) = await AppAdapterManager.shared.runMenuPath(
                                path, targetBundleId: bundle,
                                appName: scopedAppName.isEmpty
                                    ? (frontmostName ?? frontmost.name) : scopedAppName)
                            return (ok, out.isEmpty ? "Ran \(path.joined(separator: " ▸ "))" : out)
                        }
                        if let invocation = AITypedInvocationResolver.invocation(from: command),
                           invocation.kind == .adapterAction {
                            let actionId = invocation.arguments["actionId"] ?? ""
                            let bundle = (invocation.arguments["bundleId"].flatMap {
                                $0.isEmpty ? nil : $0 }) ?? scopedBundleId
                            guard let adapter = AppAdapterManager.shared.adapter(for: bundle),
                                let action = adapter.actions.first(where: { $0.id == actionId })
                            else {
                                return (false, "No adapter action '\(actionId)' is installed for this app.")
                            }
                            await self.setL2LoadingStatus(
                                "Running \(action.name)…", requestID: l2RequestID)
                            let ctx = self.sanitizedAXContextForScope(
                                self.axContext, scopedBundleId: bundle)
                            let (ok, out) = await AppAdapterManager.shared.execute(
                                action, context: ctx, targetBundleId: bundle,
                                query: invocation.arguments["query"] ?? purpose)
                            return (ok, out.isEmpty ? "Ran \(action.name)" : out)
                        }
                        // The model often wraps an mcp_call inside a TERMINAL_COMMAND tag — route
                        // it to the MCP server instead of running it as a shell command (which
                        // would open Safari / do the wrong thing).
                        if let invocation = AITypedInvocationResolver.invocation(from: command),
                           invocation.kind == .mcp {
                            var scopedArguments = invocation.arguments
                            if (scopedArguments["bundleId"] ?? "").isEmpty {
                                scopedArguments["bundleId"] = scopedBundleId
                            }
                            let scopedInvocation = AITypedInvocation(
                                kind: invocation.kind,
                                capabilityID: invocation.capabilityID,
                                arguments: scopedArguments,
                                requiresApproval: invocation.requiresApproval
                            )
                            do {
                                try CapabilityAuthorizationGate.validateInvocation(
                                    scopedInvocation,
                                    scope: .contextDock(
                                        bundleID: scopedBundleId,
                                        appName: scopedAppName.isEmpty
                                            ? (frontmostName ?? frontmost.name) : scopedAppName)
                                )
                            } catch {
                                return (false, error.localizedDescription)
                            }
                            guard MCPToolSafety.isClearlyReadOnly(name: invocation.capabilityID) else {
                                return (
                                    false,
                                    "MCP tool \(invocation.capabilityID) is write/unknown risk and requires an approved app capability route."
                                )
                            }
                            let call = self.parseMCPCall(from: command) ?? (
                                server: scopedArguments["server"] ?? "",
                                tool: invocation.capabilityID,
                                arguments: self.decodeMCPArguments(from: scopedInvocation)
                            )
                            await self.setL2LoadingStatus(
                                "Using MCP tool \(call.tool)…", requestID: l2RequestID)
                            let result = (try? await MCPRuntime.shared.callProviderReadOnlyTool(
                                bundleId: scopedBundleId, server: call.server, tool: call.tool,
                                arguments: call.arguments)) ?? "MCP tool failed"
                            await mcpRan.add(
                                "\(call.tool) via \(call.server.isEmpty ? "MCP" : call.server)")
                            return (true, result)
                        }
                        await self.setL2LoadingStatus(
                            "Running linked CLI…", requestID: l2RequestID)
                        if self.scopedAppHasPreferredNonTerminalRoute(
                            bundleId: scopedBundleId,
                            appName: scopedAppName.isEmpty
                                ? (frontmostName ?? frontmost.name) : scopedAppName,
                            query: query)
                        {
                            return (
                                false,
                                "A linked app/native/MCP/API/Shortcut/menu capability exists for this app. Use that route instead of terminal_call; terminal is fallback-only."
                            )
                        }
                        return await TerminalCommandExecutor.shared.run(
                            command, purpose: purpose)
                    }
                    let toolQuery = activeContextPrompt.isEmpty
                        ? query
                        : "\(activeContextPrompt)\n\nUser request: \(query)"
                    await self.setL2LoadingStatus(
                        "Choosing the best available capability…", requestID: l2RequestID)
                    var (finalResponse, _) = try await AIProviderService.shared.sendWithTools(
                        toolQuery,
                        context: scopedConversationContext,
                        provider: provider,
                        apiKey: apiKey,
                        conversationHistory: chatHistory,
                        commandExecutor: commandExecutor,
                        additionalSystemPrompt: activeContextPrompt.isEmpty ? nil : activeContextPrompt,
                        imageAttachments: scopedImageAttachments
                    )
                    if Task.isCancelled {
                        await MainActor.run { finishL2AIRequest(l2RequestID) }
                        return
                    }
                    var toolsRan = await mcpRan.tools
                    await self.setL2LoadingStatus(
                        "Checking the result…", requestID: l2RequestID)
                    // Fallback: model emitted a raw mcp_call as its final text (not via the loop).
                    if let resolved = await self.resolveMCPToolCall(
                        in: finalResponse, bundleId: scopedBundleId, userQuery: query,
                        provider: provider, apiKey: apiKey, history: chatHistory,
                        systemPrompt: activeContextPrompt,
                        appName: scopedAppName.isEmpty
                            ? (frontmostName ?? frontmost.name) : scopedAppName)
                    {
                        finalResponse = resolved.answer
                        toolsRan += resolved.toolsRan
                    }
                    // Fallback: model emitted a raw menu_call / adapter_call as its FINAL text
                    // (narrated "I'll minimize…" + JSON) instead of routing it through the tool
                    // loop, so the executor never ran it. Execute it now and replace the JSON
                    // blob with a plain confirmation.
                    if let invocation = AITypedInvocationResolver.invocation(from: finalResponse) {
                        let scopeName = scopedAppName.isEmpty
                            ? (frontmostName ?? frontmost.name) : scopedAppName
                        if invocation.kind == .menuAction {
                            let path = (invocation.arguments["path"] ?? "")
                                .components(separatedBy: "\u{1F}").filter { !$0.isEmpty }
                            let bundle = (invocation.arguments["bundleId"].flatMap {
                                $0.isEmpty ? nil : $0 }) ?? scopedBundleId
                            if !path.isEmpty {
                                let label = path.joined(separator: " ▸ ")
                                await self.setL2LoadingStatus(
                                    "Running \(label)…", requestID: l2RequestID)
                                let (ok, out) = await AppAdapterManager.shared.runMenuPath(
                                    path, targetBundleId: bundle, appName: scopeName)
                                finalResponse = ok
                                    ? "Done — \(label)."
                                    : (out.isEmpty ? "Couldn't run \(label)." : out)
                                toolsRan.append(label)
                            }
                        } else if invocation.kind == .adapterAction {
                            let actionId = invocation.arguments["actionId"] ?? ""
                            let bundle = (invocation.arguments["bundleId"].flatMap {
                                $0.isEmpty ? nil : $0 }) ?? scopedBundleId
                            if let adapter = AppAdapterManager.shared.adapter(for: bundle),
                                let action = adapter.actions.first(where: { $0.id == actionId }) {
                                await self.setL2LoadingStatus(
                                    "Running \(action.name)…", requestID: l2RequestID)
                                let ctx = self.sanitizedAXContextForScope(
                                    self.axContext, scopedBundleId: bundle)
                                let (ok, out) = await AppAdapterManager.shared.execute(
                                    action, context: ctx, targetBundleId: bundle,
                                    query: invocation.arguments["query"] ?? query)
                                finalResponse = ok
                                    ? (out.isEmpty ? "Done — \(action.name)." : out)
                                    : (out.isEmpty ? "Couldn't run \(action.name)." : out)
                                toolsRan.append(action.name)
                            }
                        }
                    }
                    await MainActor.run {
                        var msg = AIChatMessage(
                            role: .assistant, content: finalResponse, mcpToolsRan: toolsRan)
                        msg = self.tagMessageWithProposal(msg)
                        l2.chatMessages.append(msg)
                        if !activeContextPrompt.isEmpty {
                            extractAndInsertDockApprovalCards(
                                from: msg.content, intoMessageAt: msg.id)
                        }
                        finishL2AIRequest(l2RequestID)
                    }
                    // Dispatch any Safari browser control tags embedded in the response
                    if safariCommandScopeAllowed,
                        case .safariCommand(let cmd) = parseL2AIResponse(finalResponse)
                    {
                        let result = await SafariCommandBridge.shared.execute(cmd)
                        if !result.isEmpty {
                            await MainActor.run {
                                l2.chatMessages.append(
                                    AIChatMessage(role: .assistant, content: "🌐 \(result)"))
                            }
                        }
                    }
                } else if provider == .onDevice {
                    await self.setL2LoadingStatus(
                        "Reading app context and live capabilities…", requestID: l2RequestID)
                    // On-device Apple Intelligence: trim history + use minimal context for scoped apps
                    // to avoid "Exceeded model context window size" from Foundation Models.
                    let onDeviceHistory = Array(chatHistory.suffix(4))
                    let placeholder = AIChatMessage(role: .assistant, content: "")
                    await MainActor.run { l2.chatMessages.append(placeholder) }
                    let msgId = placeholder.id
                    // Pass the raw query — buildContextPrompt inside streamOnDeviceResponse handles
                    // all file/app/text context via the `context` parameter. Passing a pre-built
                    // context string as message would double the context and overflow Foundation Models.
                    let onDeviceContext: UserContext = {
                        if let page = webResearch.pages.last,
                            isContextDockBrowserBundle(scopedBundleId.isEmpty ? frontmost.bundleID : scopedBundleId)
                        {
                            return .url(page.url)
                        }
                        if isExplicitScopedApp && !scopedBundleId.isEmpty {
                            return .appFocused(name: scopedAppName, bundleID: scopedBundleId)
                        }
                        return scopedConversationContext
                    }()
                    // Prepend date/time as a lightweight header so the model knows current time
                    let dateHeader = await MainActor.run { self.currentDateTimeContextBlock() }
                    let onDeviceMessage =
                        dateHeader.isEmpty ? query : "\(dateHeader)\n\nUser request: \(query)"

                    await withCheckedContinuation { cont in
                        // On-device Foundation Models can stall silently (no token, no
                        // onComplete/onError) — the old "stuck empty bubble". Guard the
                        // continuation so a timeout can finish it with a useful message.
                        let resumeGuard = ResumeOnceGuard()
                        let timeoutTask = Task {
                            try? await Task.sleep(nanoseconds: 30_000_000_000)  // 30s
                            guard resumeGuard.claim() else { return }
                            await MainActor.run {
                                guard let idx = self.l2.chatMessages.firstIndex(where: { $0.id == msgId })
                                else { return }
                                if self.l2.chatMessages[idx].content.isEmpty {
                                    self.l2.chatMessages[idx] = AIChatMessage(
                                        id: msgId, role: .assistant,
                                        content:
                                            "On-device AI didn't respond in time for this one. "
                                            + "Try again, switch to a cloud provider (pick a model at "
                                            + "the top-left of the chat), or route it through a Shortcut "
                                            + "in Settings → AI Providers.",
                                        isError: true)
                                }
                            }
                            cont.resume()
                        }
                        AIProviderService.shared.streamOnDeviceResponse(
                            message: onDeviceMessage,
                            context: onDeviceContext,
                            history: onDeviceHistory,
                            additionalContextPrompt: activeContextPrompt,
                            onPartial: { token in
                                DispatchQueue.main.async {
                                    if let idx = self.l2.chatMessages.firstIndex(where: {
                                        $0.id == msgId
                                    }) {
                                        self.l2.chatMessages[idx] = AIChatMessage(
                                            id: msgId, role: .assistant,
                                            content: self.l2.chatMessages[idx].content + token
                                        )
                                    }
                                }
                            },
                            onComplete: { response in
                                DispatchQueue.main.async {
                                    if let idx = self.l2.chatMessages.firstIndex(where: {
                                        $0.id == msgId
                                    }) {
                                        let currentContent = self.l2.chatMessages[idx].content
                                        if currentContent.isEmpty {
                                            let fallback = QueryFailureGuide.shared.instant(
                                                for: .emptyResponse(query: query),
                                                originalQuery: query
                                            )
                                            self.l2.chatMessages[idx] = AIChatMessage(
                                                id: msgId, role: .assistant,
                                                content: response.isEmpty ? fallback : response
                                            )
                                        }
                                        // Post-process: extract proposal block, tag message
                                        let rawContent = self.l2.chatMessages[idx].content
                                        let tagged = self.tagMessageWithProposal(
                                            AIChatMessage(
                                                id: msgId, role: .assistant, content: rawContent)
                                        )
                                        self.l2.chatMessages[idx] = tagged
                                        let finalContent = tagged.content
                                        if !activeContextPrompt.isEmpty {
                                            self.extractAndInsertDockApprovalCards(
                                                from: finalContent, intoMessageAt: msgId)
                                        }
                                    }
                                }
                                timeoutTask.cancel()
                                if resumeGuard.claim() { cont.resume() }
                            },
                            onError: { errText in
                                DispatchQueue.main.async {
                                    if let idx = self.l2.chatMessages.firstIndex(where: {
                                        $0.id == msgId
                                    }) {
                                        let kind: QueryFailureKind = {
                                            let e = errText.lowercased()
                                            if e.contains("context") || e.contains("token")
                                                || e.contains("length")
                                            {
                                                return .onDeviceContextOverflow
                                            }
                                            if e.contains("requires macos")
                                                || e.contains("apple silicon")
                                            {
                                                return .onDeviceNotAvailable
                                            }
                                            return .onDeviceGeneralError(errText)
                                        }()
                                        let guide = QueryFailureGuide.shared.instant(
                                            for: kind, originalQuery: query
                                        )
                                        self.l2.chatMessages[idx] = AIChatMessage(
                                            id: msgId, role: .assistant, content: guide,
                                            isError: true)
                                    }
                                }
                                timeoutTask.cancel()
                                if resumeGuard.claim() { cont.resume() }
                            }
                        )
                    }
                    if Task.isCancelled {
                        await MainActor.run { finishL2AIRequest(l2RequestID) }
                        return
                    }
                    // On-device MCP: if the streamed reply was a tool-call directive, run the
                    // tool and replace the message with a grounded answer.
                    let onDeviceReply = await MainActor.run {
                        self.l2.chatMessages.first(where: { $0.id == msgId })?.content ?? ""
                    }
                    if let resolved = await self.resolveMCPToolCall(
                        in: onDeviceReply, bundleId: scopedBundleId, userQuery: query,
                        provider: provider, apiKey: apiKey, history: onDeviceHistory,
                        systemPrompt: activeContextPrompt,
                        appName: scopedAppName.isEmpty
                            ? (frontmostName ?? frontmost.name) : scopedAppName)
                    {
                        await MainActor.run {
                            if let idx = self.l2.chatMessages.firstIndex(where: { $0.id == msgId }) {
                                self.l2.chatMessages[idx] = AIChatMessage(
                                    id: msgId, role: .assistant, content: resolved.answer,
                                    mcpToolsRan: resolved.toolsRan)
                            }
                        }
                    }
                    await MainActor.run {
                        finishL2AIRequest(l2RequestID)
                    }
                } else if provider == .shortcuts {
                    await self.setL2LoadingStatus(
                        "Running the configured Shortcut…", requestID: l2RequestID)
                    // Shortcuts provider runs a user-built Shortcut (Apple
                    // Intelligence, Ollama, any API) and returns its text. It is
                    // non-streaming. activeContextPrompt already carries the live
                    // browser page block (URL + text + selection), so the Shortcut
                    // sees the page like every other provider.
                    do {
                        let request = AIRequest(
                            text: query,
                            context: scopedConversationContext,
                            source: .contextDock,
                            additionalContextPrompt: activeContextPrompt)
                        let reply = try await AIProviderRouter.shared.send(
                            request, provider: .shortcuts)
                        if Task.isCancelled {
                            await MainActor.run { finishL2AIRequest(l2RequestID) }
                            return
                        }
                        var finalReply = reply
                        var toolsRan: [String] = []
                        if let resolved = await self.resolveMCPToolCall(
                            in: reply,
                            bundleId: scopedBundleId,
                            userQuery: query,
                            provider: provider,
                            apiKey: nil,
                            history: chatHistory,
                            systemPrompt: activeContextPrompt,
                            appName: scopedAppName.isEmpty
                                ? (frontmostName ?? frontmost.name) : scopedAppName)
                        {
                            finalReply = resolved.answer
                            toolsRan = resolved.toolsRan
                        }
                        await MainActor.run {
                            var msg = AIChatMessage(
                                role: .assistant,
                                content: finalReply.trimmingCharacters(in: .whitespacesAndNewlines)
                                    .isEmpty ? "The Shortcut returned no output." : finalReply,
                                mcpToolsRan: toolsRan)
                            msg = self.tagMessageWithProposal(msg)
                            l2.chatMessages.append(msg)
                            if !activeContextPrompt.isEmpty {
                                extractAndInsertDockApprovalCards(
                                    from: msg.content, intoMessageAt: msg.id)
                            }
                            finishL2AIRequest(l2RequestID)
                        }
                    } catch {
                        await MainActor.run {
                            l2.chatMessages.append(
                                AIChatMessage(
                                    role: .assistant,
                                    content: "Shortcut failed: \(error.localizedDescription)",
                                    isError: true))
                            finishL2AIRequest(l2RequestID)
                        }
                    }
                } else {
                    await MainActor.run {
                        l2.chatMessages.append(
                            AIChatMessage(
                                role: .assistant,
                                content:
                                    "This AI provider is not supported in L2 mode. Please select OpenAI, Anthropic, Gemini, Ollama, On-Device, or Shortcuts in Settings.",
                                isError: true))
                        finishL2AIRequest(l2RequestID)
                    }
                }

            } catch {
                if isCancellationError(error) {
                    await MainActor.run { finishL2AIRequest(l2RequestID) }
                    return
                }
                await MainActor.run {
                    let desc = error.localizedDescription
                    let kind: QueryFailureKind = {
                        let e = desc.lowercased()
                        if e.contains("api key") || e.contains("unauthorized") || e.contains("401")
                        {
                            return .noAPIKey(provider: provider.shortName)
                        }
                        if e.contains("context") || e.contains("token") {
                            return .onDeviceContextOverflow
                        }
                        return .cloudAPIError("\(provider.shortName) returned an error: \(desc)")
                    }()
                    let guide = QueryFailureGuide.shared.instant(for: kind, originalQuery: query)
                    let errorMessage = AIChatMessage(
                        role: .assistant, content: guide, isError: true)
                    l2.chatMessages.append(errorMessage)
                    finishL2AIRequest(l2RequestID)
                }
            }
        }
    }

    /// Real data from the user's Apple apps (Calendar, Reminders, Contacts, Photos) injected
    /// into General Chat when the query is about them — otherwise on-device AI guesses
    /// ("This week is currently ongoing") because it has no actual data. Empty when the query
    /// isn't about an Apple app or nothing is found.
    func appleAppsContextBlock(for query: String) async -> String {
        let q = query.lowercased()
        let api = AppleAppsAPI.shared
        var blocks: [String] = []

        let iso = ISO8601DateFormatter()
        let human = DateFormatter()
        human.dateFormat = "EEE d MMM yyyy, h:mm a"
        func fmt(_ isoString: Any?) -> String {
            guard let s = isoString as? String, let d = iso.date(from: s) else { return "" }
            return human.string(from: d)
        }

        let wantsEvents =
            ["event", "calendar", "meeting", "appointment", "schedule", "agenda", "busy",
             "free time", "plan", "tomorrow", "today", "this week", "next week", "coming week",
             "weekend"].contains { q.contains($0) }
        if wantsEvents {
            // Span the whole current month (incl. earlier days) through the next ~2 months so
            // "this month", "this week", and specific-date questions all resolve accurately.
            let cal = Calendar.current
            let monthStart =
                cal.date(from: cal.dateComponents([.year, .month], from: Date()))
                ?? cal.startOfDay(for: Date())
            let start = min(monthStart, cal.date(byAdding: .day, value: -7, to: Date()) ?? monthStart)
            let end = cal.date(byAdding: .day, value: 60, to: cal.startOfDay(for: Date())) ?? Date()
            let events = api.getEvents(from: start, to: end)
            if events.isEmpty {
                blocks.append("## Calendar (this month → next 60 days): no events.")
            } else {
                // Cap at 30 — on-device Foundation Models has a small context window; a huge
                // event dump overflows it and the model returns nothing.
                let lines = events.prefix(30).map { ev -> String in
                    let title = (ev["title"] as? String) ?? "(untitled)"
                    let when =
                        (ev["isAllDay"] as? Bool ?? false)
                        ? "All day \(fmt(ev["startDate"]))" : fmt(ev["startDate"])
                    let loc = (ev["location"] as? String).map { " @ \($0)" } ?? ""
                    return "- \(when): \(title)\(loc)"
                }.joined(separator: "\n")
                blocks.append(
                    "## Calendar (this month → next 60 days) — real events:\n\(lines)")
            }
        }

        if ["reminder", "todo", "to-do", "to do", "due"].contains(where: q.contains) {
            let reminders = api.getReminders(limit: 30)
            if reminders.isEmpty {
                blocks.append("## Reminders: none open.")
            } else {
                let lines = reminders.prefix(30).map { r -> String in
                    let title = (r["title"] as? String) ?? "(untitled)"
                    let due = fmt(r["dueDate"])
                    return due.isEmpty ? "- \(title)" : "- \(title) (due \(due))"
                }.joined(separator: "\n")
                blocks.append("## Reminders — open items:\n\(lines)")
            }
        }

        if ["contact", "phone number", "email of", "number of", "call ", "phone of"]
            .contains(where: q.contains)
        {
            let contacts = await ContactSearchManager.shared.rankedContacts(matching: query, limit: 12)
            if !contacts.isEmpty {
                let lines = contacts.prefix(10).map { c -> String in
                    var parts = [c.fullName.isEmpty ? "(no name)" : c.fullName]
                    if !c.nickname.isEmpty { parts.append("aka \(c.nickname)") }
                    if !c.organizationName.isEmpty { parts.append(c.organizationName) }
                    if !c.primaryPhone.isEmpty { parts.append("📞 \(c.primaryPhone)") }
                    if !c.primaryEmail.isEmpty { parts.append("✉️ \(c.primaryEmail)") }
                    return "- " + parts.joined(separator: " — ")
                }.joined(separator: "\n")
                blocks.append("## Contacts — best full-database matches:\n\(lines)")
            }
        }

        if ["photo", "picture", "screenshot"].contains(where: q.contains) {
            let photos = api.getRecentPhotos(limit: 10)
            if !photos.isEmpty {
                blocks.append("## Photos — \(photos.count) recent items in the library.")
            }
        }

        if ["note", "notes"].contains(where: q.contains) {
            let nameGuess = query.split(separator: " ").map(String.init)
                .filter { $0.first?.isUppercase ?? false }
                .max(by: { $0.count < $1.count }) ?? ""
            let notes =
                nameGuess.isEmpty ? api.getNotes(limit: 15) : api.searchNotes(query: nameGuess)
            if !notes.isEmpty {
                let lines = notes.prefix(15).map { n -> String in
                    let title = (n["title"] as? String) ?? "(untitled)"
                    let body = ((n["body"] as? String) ?? "").prefix(120)
                    return body.isEmpty ? "- \(title)" : "- \(title): \(body)"
                }.joined(separator: "\n")
                blocks.append("## Notes — matches:\n\(lines)")
            }
        }

        if ["email", "mail", "inbox", "message from"].contains(where: q.contains) {
            let emails = api.getRecentEmails(limit: 12)
            if !emails.isEmpty {
                let lines = emails.prefix(12).map { e -> String in
                    let subject = (e["subject"] as? String) ?? "(no subject)"
                    let sender = (e["sender"] as? String) ?? ""
                    let unread = (e["read"] as? Bool ?? true) ? "" : " [unread]"
                    return "- \(subject) — \(sender)\(unread)"
                }.joined(separator: "\n")
                blocks.append("## Mail — recent inbox:\n\(lines)")
            }
        }

        if ["playing", "song", "music", "track", "now playing"].contains(where: q.contains) {
            let music = api.getMusicInfo()
            let title = (music["title"] as? String) ?? ""
            if !title.isEmpty {
                let artist = (music["artist"] as? String) ?? ""
                let state = (music["state"] as? String) ?? ""
                blocks.append(
                    "## Music — \(state.isEmpty ? "" : "\(state): ")\(title)"
                        + (artist.isEmpty ? "" : " by \(artist)"))
            }
        }

        if ["tab", "tabs", "safari"].contains(where: q.contains) {
            let tabs = api.getAllTabs()
            if !tabs.isEmpty {
                let lines = tabs.prefix(20).map { t -> String in
                    let title = (t["title"] as? String) ?? ""
                    let url = (t["url"] as? String) ?? ""
                    return "- \(title.isEmpty ? url : title) (\(url))"
                }.joined(separator: "\n")
                blocks.append("## Safari — open tabs:\n\(lines)")
            }
        }

        guard !blocks.isEmpty else { return "" }
        return blocks.joined(separator: "\n\n")
            + "\n\nAnswer the user's question directly and concisely from this real data. Do NOT"
            + " add text telling the user to open an app — the UI shows an 'Open in <App>' button"
            + " automatically."
    }

    /// Combined Apple-apps data + live weather for a query, ready to append to any chat
    /// system prompt. Used by both General Chat and Context Dock chat so both answer with
    /// real Calendar/Reminders/Contacts/Photos/Notes/Mail/Music/Safari/Weather data.
    func appleAppsAndWeatherContext(for query: String) async -> String {
        var block = await appleAppsContextBlock(for: query)
        let ql = query.lowercased()
        if ["weather", "temperature", "forecast", "rain", "raining", "sunny", "humid",
            "how hot", "how cold", "degrees"].contains(where: ql.contains)
        {
            let place: String? = {
                guard let range = ql.range(of: " in ") else { return nil }
                let tail = query[range.upperBound...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ?.!,"))
                return tail.isEmpty ? nil : tail
            }()
            if let weather = await WeatherService.currentSummary(place: place) {
                let w = "## Weather — real current conditions:\n\(weather)"
                block = block.isEmpty ? w : block + "\n\n" + w
            }
        }
        return block
    }

    /// Thread-safe accumulator for MCP tool labels invoked inside the cloud tool loop.
    actor MCPRunCollector {
        private(set) var tools: [String] = []
        func add(_ label: String) { tools.append(label) }
    }

    /// If the model's reply is an MCP tool-call directive, run the tool — then let the model
    /// chain further tool calls (keeping the MCP block in context) until it answers in plain
    /// language or the step cap is hit. Returns nil when the first reply isn't a tool call.
    func resolveMCPToolCall(
        in response: String, bundleId: String, userQuery: String,
        provider: AIProvider, apiKey: String?, history: [ChatMessage], systemPrompt: String,
        appName: String? = nil
    ) async -> (answer: String, toolsRan: [String])? {
        let contextScope = AIConversationScope.contextDock(bundleID: bundleId, appName: bundleId)
        guard let firstInvocation = AITypedInvocationResolver.invocation(from: response),
              firstInvocation.kind == .mcp else { return nil }
        do {
            try CapabilityAuthorizationGate.validateInvocation(
                scopedMCPInvocation(firstInvocation, bundleId: bundleId),
                scope: contextScope
            )
        } catch {
            return (answer: error.localizedDescription, toolsRan: [])
        }
        guard MCPToolSafety.isClearlyReadOnly(name: firstInvocation.capabilityID) else {
            return (
                answer: "MCP tool \(firstInvocation.capabilityID) is write/unknown risk and requires an approved app capability route.",
                toolsRan: [])
        }

        // Weaker models (on-device especially) tend to re-emit the SAME tool call instead of
        // answering after it runs — which used to loop up to 5× (creating 5 tabs!) and then
        // surface the raw JSON. Cap tightly, break on a repeated call, and NEVER show a raw
        // directive: fall back to the last tool result phrased plainly.
        let maxSteps = 3
        var transcript = history
        var current = response
        var toolsRan: [String] = []
        var lastResult = ""
        var lastCallKey = ""

        for _ in 0..<maxSteps {
            guard let invocation = AITypedInvocationResolver.invocation(from: current),
                  invocation.kind == .mcp else {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty
                    ? (toolsRan.isEmpty ? nil : (answer: plainMCPAnswer(lastResult), toolsRan: toolsRan))
                    : (answer: trimmed, toolsRan: toolsRan)
            }
            let scopedInvocation = scopedMCPInvocation(invocation, bundleId: bundleId)
            do {
                try CapabilityAuthorizationGate.validateInvocation(scopedInvocation, scope: contextScope)
            } catch {
                return (answer: error.localizedDescription, toolsRan: toolsRan)
            }
            guard MCPToolSafety.isClearlyReadOnly(name: invocation.capabilityID) else {
                return (
                    answer: "MCP tool \(invocation.capabilityID) is write/unknown risk and requires an approved app capability route.",
                    toolsRan: toolsRan)
            }
            let call = parseMCPCall(from: current) ?? (
                server: scopedInvocation.arguments["server"] ?? "",
                tool: invocation.capabilityID,
                arguments: decodeMCPArguments(from: scopedInvocation)
            )
            // Same call as the previous step → the model is stuck. Stop and present the result.
            let callKey = "\(call.server)|\(call.tool)|\(call.arguments.keys.sorted().joined(separator: ","))"
            if callKey == lastCallKey {
                return (answer: plainMCPAnswer(lastResult), toolsRan: toolsRan)
            }
            lastCallKey = callKey

            let result: String
            do {
                result = try await MCPRuntime.shared.callProviderReadOnlyTool(
                    bundleId: bundleId, server: call.server, tool: call.tool,
                    arguments: call.arguments)
            } catch {
                return (
                    answer: "MCP tool “\(call.tool)” failed: \(error.localizedDescription)",
                    toolsRan: toolsRan)
            }
            lastResult = result
            toolsRan.append("\(call.tool) via \(call.server.isEmpty ? "MCP" : call.server)")
            if let grounded = groundedMCPAnswer(
                toolResult: result,
                userQuery: userQuery,
                appName: appName ?? bundleId
            ) {
                return (answer: grounded, toolsRan: toolsRan)
            }
            transcript.append(ChatMessage(role: .assistant, content: current))
            let followup =
                "The \"\(call.tool)\" tool ALREADY RAN and returned:\n\(result)\n\n"
                + "Do NOT call it again. Answer the user's request in one short plain sentence "
                + "using this result: \(userQuery)"
            transcript.append(ChatMessage(role: .user, content: followup))
            let next = (try? await AIProviderService.shared.sendWithTools(
                followup, context: .none, provider: provider, apiKey: apiKey,
                conversationHistory: transcript,
                commandExecutor: { _, _ in (false, "") },
                additionalSystemPrompt: systemPrompt.isEmpty ? nil : systemPrompt
            ))?.finalResponse ?? ""
            if next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (answer: plainMCPAnswer(result), toolsRan: toolsRan)
            }
            current = next
        }
        // Ran out of steps. Never leak the raw mcp_call directive.
        if let invocation = AITypedInvocationResolver.invocation(from: current),
           invocation.kind == .mcp {
            return (answer: plainMCPAnswer(lastResult), toolsRan: toolsRan)
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : (answer: trimmed, toolsRan: toolsRan)
    }

    /// Turn a raw MCP tool result into a short human line when the model won't summarize it.
    private func plainMCPAnswer(_ result: String) -> String {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Done." }
        // Long/JSON payloads: don't dump — just confirm.
        if trimmed.count > 400 || trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return "Done."
        }
        return trimmed
    }

    private func groundedMCPAnswer(
        toolResult: String,
        userQuery: String,
        appName: String
    ) -> String? {
        let q = userQuery.lowercased()
        let asksForLinks = q.contains("link") || q.contains("url") || q.contains("youtube")
        guard asksForLinks else { return nil }
        var links = extractURLs(from: toolResult)
        if q.contains("youtube") {
            links = links.filter {
                let lower = $0.absoluteString.lowercased()
                return lower.contains("youtube.com") || lower.contains("youtu.be")
            }
        }
        links = Array(NSOrderedSet(array: links.map(\.absoluteString)) as? [String] ?? [])
            .compactMap(URL.init(string:))
        guard !links.isEmpty else {
            if q.contains("youtube") {
                return "I checked \(appName)'s MCP result and found no YouTube links."
            }
            return "I checked \(appName)'s MCP result and found no saved links."
        }
        let lines = links.prefix(20).map { "- \($0.absoluteString)" }.joined(separator: "\n")
        let suffix = links.count > 20 ? "\n…and \(links.count - 20) more." : ""
        if q.contains("youtube") {
            return "I found \(links.count) YouTube link\(links.count == 1 ? "" : "s"):\n\(lines)\(suffix)"
        }
        return "I found \(links.count) saved link\(links.count == 1 ? "" : "s"):\n\(lines)\(suffix)"
    }

    private func extractURLs(from text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, options: [], range: range).compactMap(\.url)
    }

    /// Answer browser-history questions from the same local URL library that powers
    /// Context Dock search rows. The full history never enters a provider prompt.
    @MainActor
    func isBrowserHistoryReadQuery(_ query: String) -> Bool {
        let normalized = query.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.hasPrefix("open ") else { return false }
        return (normalized.contains("visit")
            && (normalized.contains("recent") || normalized.contains("history")
                || normalized.hasPrefix("did i")))
            || normalized.contains("browser history")
            || normalized.contains("browsing history")
    }

    @MainActor
    func localBrowserHistoryAnswer(
        query: String,
        scopedBundleId: String? = nil,
        requireAppAdapter: Bool
    ) async -> String? {
        let normalized = query.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isBrowserHistoryReadQuery(query) else { return nil }

        let namedApp = GeneralAIActionResolver.shared.namedInstalledApp(in: query)
        let requestedBundle: String? = {
            if let scopedBundleId, isContextDockBrowserBundle(scopedBundleId) {
                return scopedBundleId
            }
            if let namedApp, AXWebReader.shared.isBrowser(bundleId: namedApp.bundleId) {
                return namedApp.bundleId
            }
            return nil
        }()

        let allowedBrowserBundles = Set(
            AppAdapterManager.shared.adapters
                .filter { $0.isEnabled && AXWebReader.shared.isBrowser(bundleId: $0.bundleId) }
                .map(\.bundleId)
        )
        if requireAppAdapter, let requestedBundle,
            !allowedBrowserBundles.contains(requestedBundle)
        {
            let appName = namedApp?.name ?? "That browser"
            return "\(appName) isn’t added to App Adapters, so General AI can’t read its local history."
        }

        let stopWords: Set<String> = [
            "a", "about", "any", "browser", "browsing", "did", "do", "have", "history",
            "i", "in", "my", "recent", "recently", "safari", "site", "the", "visit",
            "visited", "website",
        ]
        let searchTerm = normalized
            .split { !$0.isLetter && !$0.isNumber && $0 != "." && $0 != "-" }
            .map(String.init)
            .filter { !stopWords.contains($0) }
            .joined(separator: " ")
        let libraryQuery = searchTerm.isEmpty ? "history" : searchTerm
        var entries = await BrowserURLLibraryService.shared.refreshedEntries(
            matching: libraryQuery,
            bundleId: requestedBundle,
            limit: requireAppAdapter && requestedBundle == nil ? 200 : 20)
        if requireAppAdapter, requestedBundle == nil {
            entries = entries.filter { allowedBrowserBundles.contains($0.browserBundleId) }
        }

        guard !entries.isEmpty else {
            if BrowserURLLibraryService.shared.refreshInProgress {
                return "Your local browser history is still refreshing. Please try again in a moment."
            }
            let subject = searchTerm.isEmpty ? "that" : "“\(searchTerm)”"
            return "I checked the local browser-history URL cache and found no recent visits matching \(subject)."
        }

        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let lines = entries.prefix(8).map { entry in
            let rawTitle = entry.title.isEmpty ? entry.domain : entry.title
            let title = rawTitle
                .replacingOccurrences(of: "[", with: "(")
                .replacingOccurrences(of: "]", with: ")")
            let date = entry.visitDate.map(formatter.string(from:)) ?? "date unavailable"
            return "- [\(title)](\(entry.url.absoluteString)) — \(entry.browserName), \(date)"
        }
        let countLabel = entries.count == 1 ? "one matching visit" : "\(entries.count) matching visits"
        return "I checked the local browser-history URL cache and found \(countLabel):\n\n"
            + lines.joined(separator: "\n")
    }

    /// Parse a `{"mcp_call": {"server","tool","arguments"}}` directive out of an AI reply —
    /// even when the model wraps it in a ```json fence or a [TERMINAL_COMMAND: …] tag. Finds
    /// the balanced JSON object that encloses the "mcp_call" key.
    func parseMCPCall(from response: String)
        -> (server: String, tool: String, arguments: [String: Any])?
    {
        guard let invocation = AITypedInvocationResolver.invocation(from: response),
              invocation.kind == .mcp
        else { return nil }
        return (
            server: invocation.arguments["server"] ?? "",
            tool: invocation.capabilityID,
            arguments: decodeMCPArguments(from: invocation)
        )
    }

    private func scopedMCPInvocation(
        _ invocation: AITypedInvocation,
        bundleId: String
    ) -> AITypedInvocation {
        var arguments = invocation.arguments
        if (arguments["bundleId"] ?? "").isEmpty {
            arguments["bundleId"] = bundleId
        }
        return AITypedInvocation(
            kind: invocation.kind,
            capabilityID: invocation.capabilityID,
            arguments: arguments,
            requiresApproval: invocation.requiresApproval
        )
    }

    private func decodeMCPArguments(from invocation: AITypedInvocation) -> [String: Any] {
        guard let json = invocation.arguments["argumentsJSON"],
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    /// "Open in <App>" buttons to attach to an answer, derived from the Apple-app data the
    /// query touched — lets the user jump straight to Calendar, Reminders, etc.
    func referencedAppLaunches(for query: String) -> [AppLaunchAction] {
        let q = query.lowercased()
        var launches: [AppLaunchAction] = []
        func add(_ keys: [String], _ label: String, _ icon: String, _ bundleId: String) {
            guard keys.contains(where: q.contains) else { return }
            launches.append(AppLaunchAction(label: label, systemIcon: icon, bundleId: bundleId))
        }
        add(
            ["event", "calendar", "meeting", "appointment", "schedule", "agenda", "tomorrow",
             "today", "this week", "next week", "coming week", "weekend"],
            "Open Calendar", "calendar", "com.apple.iCal")
        add(["reminder", "todo", "to-do", "to do", "due"],
            "Open Reminders", "checklist", "com.apple.reminders")
        add(["contact", "phone number", "email of", "number of", "call ", "phone of"],
            "Open Contacts", "person.crop.circle", "com.apple.AddressBook")
        // A screenshot capture is a system action, not a Photos launch. Only offer Photos
        // when the user is asking about existing photos or pictures.
        add(["photo", "picture"], "Open Photos", "photo", "com.apple.Photos")
        add(["note", "notes"], "Open Notes", "note.text", "com.apple.Notes")
        add(["email", "mail", "inbox", "message from"], "Open Mail", "envelope", "com.apple.mail")
        add(["playing", "song", "music", "track", "now playing"],
            "Open Music", "music.note", "com.apple.Music")
        add(["tab", "tabs", "safari"], "Open Safari", "safari", "com.apple.Safari")
        add(["weather", "temperature", "forecast", "rain", "raining", "sunny", "humid",
             "how hot", "how cold", "degrees"],
            "Open Weather", "cloud.sun", "com.apple.weather")
        return launches
    }

    func sendToAIProvider(
        query: String,
        attachments: [URL] = [],
        providerSelection capturedSelection: AIProviderSelection? = nil
    ) async throws -> String {
        await MainActor.run {
            aiMode.loadingStatus = attachments.isEmpty
                ? "Checking App Adapters…"
                : "Reading attached files…"
        }
        // A short follow-up such as “try again” refers to the last executable user request.
        // Resolve it locally instead of letting a provider narrate an action it cannot run.
        let actionQuery = generalAIRetryExpandedQuery(query)
        let providerSelection = capturedSelection
            ?? AIProviderSelectionResolver.current(settings: settings)
        // Build context from previous messages (uses aiMode.messages for global AI mode)
        let history = aiMode.messages.map { msg in
            ChatMessage(
                role: msg.role == .user ? .user : .assistant,
                content: msg.content
            )
        }
        let generalChatPolicy = AIOrchestrationPolicy.generalChat
        let hasExplicitContext = !attachments.isEmpty
            || aiMode.selectionText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || !aiMode.selectionFiles.isEmpty
            || aiMode.selectionURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let intentResolution = AIRequestClassifier.shared.classify(
            query: query,
            hasExplicitContext: hasExplicitContext
        )
        let requestLiveContext = generalChatPolicy.includesLiveContext(
            explicitlyRequested: false
        ) ? ContextCollector.shared.snapshot() : nil

        // ── Selection Scope router ───────────────────────────────────────────────────────
        // Action requests on a selection are resolved against the rows the result sheet
        // already exposes (share destinations, extensions, app menus, Shortcuts, built-ins)
        // and EXECUTED, instead of being narrated by a model with no tools. Returns nil for
        // questions, transforms and unroutable requests, which continue down the answer path.
        let selectionScopeActive = await MainActor.run { hasSelectionScopeSurface }
        if selectionScopeActive {
            await MainActor.run {
                selectionRouterExecutedRouteTitle = nil
                selectionRouterNoRouteNote = nil
                aiMode.routerTrace = []
            }
            if let routed = await runSelectionActionRouter(
                query: actionQuery,
                providerSelection: providerSelection
            ) {
                await MainActor.run { aiMode.loadingStatus = nil }
                return routed
            }
        }

        // App Adapters are General AI's explicit app-access allowlist. Block locally before
        // building or sending context, so an unconfigured app's identity/state never reaches
        // the selected provider.
        // Selection is the access boundary — the user decides which apps General Chat may
        // read or act on by choosing them in the app picker. If a query targets an installed
        // app that ISN'T selected, ask the user to select it rather than silently reaching
        // into it. This keeps answers scoped to only the chosen apps and keeps the user in
        // full control (e.g. Notes selected, asked about Mail → prompt to select Mail).
        if currentAISelectionSnapshot.isEmpty,
            let namedApp = GeneralAIActionResolver.shared.namedInstalledApp(in: actionQuery),
            !chatFocusApps.contains(where: {
                $0.bundleId.caseInsensitiveCompare(namedApp.bundleId) == .orderedSame
            })
        {
            // Offer a one-tap "Enable <app> for this chat" button — approving it adds the app
            // to the focus picker and re-runs the query, so the user grants access in one tap
            // instead of hunting for the picker.
            await MainActor.run {
                aiMode.pendingEnableApp = EnableAppRequest(
                    name: namedApp.name, bundleId: namedApp.bundleId, query: query)
            }
            if chatFocusApps.isEmpty {
                return "**\(namedApp.name)** isn’t in this chat’s scope yet. General Chat only reads the apps you choose, so you stay in control — enable it below to let me answer about \(namedApp.name)."
            } else {
                let focusNames = chatFocusApps.map(\.name).joined(separator: ", ")
                return "This chat is focused on **\(focusNames)**. To answer about **\(namedApp.name)**, enable it below — answers stay scoped to only the apps you’ve chosen, so you keep full control."
            }
        }

        if attachments.isEmpty, currentAISelectionSnapshot.isEmpty,
            isBrowserHistoryReadQuery(query)
        {
            await MainActor.run { aiMode.loadingStatus = "Reading local browser-history URLs…" }
            if let historyAnswer = await localBrowserHistoryAnswer(
                query: query,
                requireAppAdapter: true)
            {
                await MainActor.run { aiMode.pendingToolChips = ["Local browser history"] }
                return historyAnswer
            }
        }

        // Lightweight system message for standalone AI chat — no menu/AX overhead
        var sysContent = """
            You are DoraX AI Assistant, a system-wide workflow assistant inside the user's Mac launcher.
            Provide concise, accurate answers.
            Keep responses brief and to the point.
            This is AI Assistant mode. It is not Global Context and not Context Dock chat.
            Use explicit chat attachments/selection normally. Never ask for Accessibility,
            Vision, browser-page, or app-context permission in chat text. DoraX handles all
            permission decisions with native approval UI before verified context reaches you.
            When the user names or implies an app, ground the answer in DoraX's installed-app
            inventory, app adapters, cached menus, MCP tools, skills, CLI routes, and native
            share routes when those sections are provided. Prefer actionable approval-backed
            routes over generic instructions.
            If execution is needed, do not claim completion until the DoraX approval/executor
            path succeeds.
            Answer format: lead with a one-line headline that states the outcome (a count, a
            status, or a direct answer). When you list items (emails, notes, files, results),
            use a bullet per item with its key details — for mail: sender · subject · date;
            for notes/files: title · short snippet. Keep it a tight, scannable summary, not a
            rambling paragraph. If nothing was found, say so plainly in one line.
            NEVER print tool-call syntax in your reply — no <function>/<invoke> XML, no raw
            {"mcp_call":…}/{"menu_call":…} JSON. Emit a tool call only through the tool channel;
            your visible text is prose for the user, never call scaffolding.
            \(currentDateTimeContextBlock())
            """
        // App Store picker: the user explicitly chose a running app to focus on, so
        // ground answers on it (and treat it as allowed for this conversation).
        if !chatFocusApps.isEmpty {
            let focusList = chatFocusApps
                .map { "\($0.name) (\($0.bundleId))" }
                .joined(separator: ", ")
            sysContent += """


            Focus apps for this conversation: \(focusList).
            The user picked them explicitly as this conversation's scopes. Answer ONLY from
            these apps and their verified context + DoraX adapter/menu/MCP capabilities supplied
            below. Do NOT read or act on any other app. If the user asks about an app that is
            NOT in this focus list, do not answer from it — tell them to select that app in the
            app picker first. You may reason across the selected apps and coordinate workflows
            between them, but only claim actions DoraX actually executes through its
            approval-backed tools. Never produce a conversational permission request.
            """
            // A picked app that isn't running has a COLD menu cache, so no menu commands get
            // listed and the model can only narrate (the Clock "Starting Stopwatch…" case).
            // For action-shaped queries, launch + warm each closed focus app first so its menu
            // commands are listed and callable — the same warm state frontmost chat gets free.
            if intentResolution.kind != .conversation {
                await warmFocusAppMenusForAction()
            }
            // Give the model each selected app's real capabilities (adapter actions, verified
            // menu commands, linked CLI/MCP/Shortcuts) so it drives THAT app via adapter_call /
            // menu_call instead of answering generically. This is what makes "general chat works
            // only for the selected app, using its adapters" true end-to-end.
            let inventories = chatFocusApps
                .map { scopedAppIdentityBlock(bundleId: $0.bundleId, appName: $0.name) }
                .filter { !$0.isEmpty }
            if !inventories.isEmpty {
                sysContent += "\n\n## Selected app capabilities\n"
                    + inventories.joined(separator: "\n\n")
            }
        }
        if !attachments.isEmpty {
            // Extract the actual content (PDF text, text/code/markdown) so on-device AI can
            // answer about the file — passing only the filename gave the model nothing to
            // read ("Unable to determine PDF content"). Images flow through as vision payload
            // via the request attachments below.
            let analyzed = ContextDetector.shared.analyzeFiles(Array(attachments.prefix(20)))
            let listLines = analyzed.map { "- \($0.url.lastPathComponent) (\($0.type))" }
                .joined(separator: "\n")
            sysContent += "\n\nExplicit user attachments for this message:\n\(listLines)"
            let contentBlocks = analyzed.compactMap { item -> String? in
                guard let content = item.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !content.isEmpty
                else { return nil }
                return "### \(item.url.lastPathComponent) (\(item.type))\n\(content)"
            }
            if !contentBlocks.isEmpty {
                sysContent +=
                    "\n\nAttachment contents — use these to answer the user's question:\n\n"
                    + contentBlocks.joined(separator: "\n\n")
            }
        }

        let selectionContextBlock = selectionAIContextBlock(
            compact: providerSelection.effectiveProvider == .onDevice,
            query: query
        )
        if !selectionContextBlock.isEmpty {
            sysContent += "\n\n## Explicit Selection Scope\n" + selectionContextBlock
            // Reaching this point means the router did NOT execute anything: either the request
            // was a question, or no row in the sheet could perform it. Saying "saved" / "sent"
            // here would be a lie the UI then dressed up with an Open-in-App button.
            let routerNote = await MainActor.run { selectionRouterNoRouteNote }
            sysContent += """


                ══ EXECUTION TRUTH ══
                You have NOT run anything for this message. Never state or imply that a file was \
                saved, sent, shared, created, renamed, converted or moved. Do not write "Saved \
                to…", "Sent to…" or "Done". If the user asked for an action, say plainly that it \
                did not run and why, then offer the concrete next step.
                """
            if let routerNote, !routerNote.isEmpty {
                sysContent += """


                    ══ ROUTER RESULT ══
                    \(routerNote) Tell the user which capability is missing in one sentence, then \
                    follow the SELECTION-SCOPE AUTOMATION rules below to propose a saveable \
                    Selection Scope extension that would perform it next time.
                    """
            }
            // Deterministic built-in routing for selected files (sips/markitdown/ditto), so
            // "convert to jpeg" just runs sips per file instead of asking which tool.
            sysContent += selectionFileOperationGuidance()
            // Auto-create: when the user's selection-scope request has no built-in/linked route,
            // don't just narrate — write the automation and propose it as a saveable extension
            // (Run once / Save). Reuses the same proposal card the frontmost chat uses.
            sysContent += selectionScopeExtensionProposalAppendix(query: query)
        }

        if !chatFocusApps.isEmpty {
            let focusedContext = await selectedGeneralChatAppContext()
            if focusedContext.cancelled {
                return "Cancelled — selected app context was not read."
            }
            if !focusedContext.block.isEmpty {
                sysContent += "\n\n" + focusedContext.block
            }
        }

        // Read-only capability router first. Queries like "show Salman Khan email" are
        // contact lookups, not Mail/share commands. Run this before executable routing so
        // personal-data reads don't get misclassified as actions.
        if attachments.isEmpty, currentAISelectionSnapshot.isEmpty,
           let readAnswer = await readOnlyCapabilityAnswer(query: query) {
            return readAnswer
        }

        // DoraX Action Chat: executable requests ("open safari new private window",
        // "add reminder to buy milk") resolve to real capability routes and execute
        // with approval instead of getting an instructional chatbot answer.
        // Route-preference commands ("always use TextEdit for new text files", "avoid AX
        // for Safari") update local preferences instead of hitting a provider.
        if attachments.isEmpty, currentAISelectionSnapshot.isEmpty,
           let prefAnswer = await applyPreferenceCommand(query: query) {
            return prefAnswer
        }

        if attachments.isEmpty, currentAISelectionSnapshot.isEmpty,
           let actionAnswer = await generalAIExecutableActionAnswer(query: actionQuery) {
            return actionAnswer
        }

        // Named-app status grounding: "what's going on with vs code?" answers from
        // live app state (context readers, code --status, menu cache, MCP inventory)
        // — the same powers frontmost-app chat has — instead of provider guesses.
        let appRuntimeBlock = currentAISelectionSnapshot.isEmpty && chatFocusApps.isEmpty
            ? await generalAppRuntimeContextBlock(for: query) : ""
        if !appRuntimeBlock.isEmpty {
            sysContent += "\n\n" + appRuntimeBlock
        }

        if currentAISelectionSnapshot.isEmpty,
           let mcpAnswer = try await directGeneralAppMCPAnswer(
            query: query,
            history: history,
            baseSystemPrompt: sysContent,
            providerSelection: providerSelection
        ) {
            return mcpAnswer
        }

        // Inject real Apple-apps data + live weather when the query is about them.
        let appleData = currentAISelectionSnapshot.isEmpty
            ? await appleAppsAndWeatherContext(for: query) : ""
        if !appleData.isEmpty {
            sysContent += "\n\n" + appleData
        }

        let providerQuery = userQueryWithExplicitSelection(query)

        // Agentic path: give General Chat the same tool power Context Dock chat has, but with
        // a CROSS-APP catalog — every enabled adapter's MCP tools plus saved app-scoped chat
        // histories. Uses the JSON tool-call protocol via plain sendPrepared, so it works for
        // EVERY provider including on-device Apple Intelligence (which has no native function
        // calling). Attachments stay on the plain path so vision payloads keep flowing.
        let toolProvider = providerSelection.effectiveProvider
        let shouldDiscoverAppTools = currentAISelectionSnapshot.isEmpty
            && intentResolution.kind != .conversation
            && selectionRequestNeedsCapabilities(query)
        if shouldDiscoverAppTools, toolProvider != .shortcuts
        {
            await MainActor.run { aiMode.loadingStatus = "Looking for MCP and app tools…" }
            let executionScope: AIConversationScope = currentAISelectionSnapshot.isEmpty
                ? .general : .selection(currentAISelectionSnapshot)
            let appToolsBlock = await GeneralChatCapabilityHub.shared.capabilityPromptBlock(
                compact: toolProvider == .onDevice,
                query: query,
                scope: executionScope)
            if !appToolsBlock.isEmpty {
                let toolSystemPrompt = sysContent + "\n\n" + appToolsBlock
                var loopHistory = history
                var loopQuery = query
                var toolChips: [String] = []
                for _ in 0..<4 {
                    await MainActor.run {
                        aiMode.loadingStatus = toolChips.isEmpty
                            ? "Choosing the best capability…" : "Reading tool result…"
                    }
                    let loopRequest = AIRequestBuilder.aiChat(
                        text: loopQuery,
                        history: loopHistory,
                        attachments: attachments,
                        liveContext: requestLiveContext,
                        includesWorkflowCapabilities: true
                    )
                    let response = try await AIOrchestrationEngine.shared.submit(
                        AIOrchestrationRequest(
                            providerRequest: loopRequest,
                            scope: executionScope,
                            policy: .generalChat,
                            providerSelection: providerSelection,
                            contextPrompt: toolSystemPrompt
                        )
                    ).text
                    // Tool call? Execute, feed the result back, and go around again.
                    await MainActor.run { aiMode.loadingStatus = "Checking for tool calls…" }
                    let call = await GeneralChatCapabilityHub.shared.execute(
                        response,
                        scope: executionScope)
                    guard call.handled else {
                        await MainActor.run {
                            aiMode.loadingStatus = nil
                            aiMode.pendingToolChips = toolChips
                        }
                        return response
                    }
                    toolChips.append(call.label)
                    await MainActor.run { aiMode.loadingStatus = "Running \(call.label)…" }
                    loopHistory.append(ChatMessage(role: .user, content: loopQuery))
                    loopHistory.append(ChatMessage(role: .assistant, content: response))
                    let trimmedOutput = call.output.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    loopQuery = """
                    SYSTEM NOTE: You are the DoraX launcher assistant WITH live access to the \
                    user's apps through registered tools. You just called \(call.label) and it \
                    returned the REAL data below. NEVER claim you lack access to this app — you \
                    are connected to it. Any other persona instructions about being limited to \
                    a file system or shell do not apply here.

                    Tool result (\(call.label))\(call.success ? "" : " — FAILED"):
                    \(trimmedOutput.isEmpty ? "(the tool returned zero items — say that no matching items were found, not that you lack access)" : String(trimmedOutput.prefix(8_000)))

                    Using ONLY this result, answer the user's original question: "\(query)"
                    If the user asks "how many", count the returned items. If you still need \
                    another tool, reply with ONLY the tool-call JSON again.
                    """
                }
                // Loop budget exhausted — one final forced plain answer.
                await MainActor.run { aiMode.loadingStatus = "Writing answer…" }
                let finalRequest = AIRequestBuilder.aiChat(
                    text: loopQuery + "\n\nAnswer in plain language now. Do NOT call any more tools.",
                    history: loopHistory,
                    liveContext: requestLiveContext,
                    includesWorkflowCapabilities: true
                )
                let finalAnswer = try await AIOrchestrationEngine.shared.submit(
                    AIOrchestrationRequest(
                        providerRequest: finalRequest,
                        scope: currentAISelectionSnapshot.isEmpty
                            ? .general : .selection(currentAISelectionSnapshot),
                        policy: .generalChat,
                        providerSelection: providerSelection,
                        contextPrompt: toolSystemPrompt
                    )
                ).text
                await MainActor.run {
                    aiMode.loadingStatus = nil
                    aiMode.pendingToolChips = toolChips
                }
                return finalAnswer
            }
            await MainActor.run { aiMode.loadingStatus = nil }
        }

        let request = AIRequestBuilder.aiChat(
            text: providerQuery,
            history: history,
            attachments: attachments,
            liveContext: requestLiveContext
        )
        await MainActor.run { aiMode.loadingStatus = "Writing answer…" }
        return try await AIOrchestrationEngine.shared.submit(
            AIOrchestrationRequest(
                providerRequest: request,
                scope: currentAISelectionSnapshot.isEmpty
                    ? .general : .selection(currentAISelectionSnapshot),
                policy: .generalChat,
                providerSelection: providerSelection,
                contextPrompt: sysContent
            )
        ).text
    }

    /// Expand only explicit retry phrases. The current user message may already be present
    /// in `aiMode.messages`, so walk backwards past it and assistant responses to the most
    /// recent executable user request. This state stays local to DoraX.
    private func generalAIRetryExpandedQuery(_ query: String) -> String {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let retryPhrases: Set<String> = [
            "retry", "retry it", "try again", "try it again", "do it again", "go again",
        ]
        guard retryPhrases.contains(normalized) else { return query }
        for message in aiMode.messages.reversed() where message.role == .user {
            let previous = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard previous.caseInsensitiveCompare(query) != .orderedSame,
                !retryPhrases.contains(previous.lowercased()),
                GeneralAIActionResolver.shared.looksExecutable(previous)
            else { continue }
            return previous
        }
        return query
    }

    func directGeneralAppMCPAnswer(
        query: String,
        history: [ChatMessage],
        baseSystemPrompt: String,
        providerSelection: AIProviderSelection
    ) async throws -> String? {
        if let notesAnswer = try await directGeneralNotesMCPAnswer(query: query) {
            await MainActor.run { aiMode.pendingToolChips = ["DoraX Notes MCP"] }
            return notesAnswer
        }

        guard let target = generalMCPAppTarget(for: query) else { return nil }
        await MainActor.run {
            aiMode.loadingStatus = "Searching \(target.adapter.appName) tools…"
        }
        let tools = await MCPRuntime.shared.tools(forBundleId: target.adapter.bundleId)
        guard !tools.isEmpty else { return nil }
        guard let selected = selectGeneralMCPTool(from: tools, query: query) else { return nil }

        let arguments = generalMCPArguments(
            for: selected.tool,
            query: query,
            appName: target.adapter.appName
        )
        let toolChip = "\(selected.tool.name) via \(target.adapter.appName)"
        await MainActor.run { aiMode.loadingStatus = "Running \(toolChip)…" }
        let toolResult = try await MCPRuntime.shared.callProviderReadOnlyTool(
            bundleId: target.adapter.bundleId,
            server: selected.server,
            tool: selected.tool.name,
            arguments: arguments
        )
        let prompt = """
        \(baseSystemPrompt)

        General Chat used live MCP for \(target.adapter.appName) (\(target.adapter.bundleId)).
        Tool: \(selected.tool.name) via \(selected.server)
        Arguments: \(jsonString(arguments))

        MCP tool result:
        \(toolResult)

        Answer the user's exact question from the MCP result. If the user asks "how many", count the returned items. Do not say no data exists unless the MCP result is empty.
        """
        await MainActor.run {
            aiMode.loadingStatus = "Writing answer…"
            aiMode.pendingToolChips = [toolChip]
        }
        if let grounded = groundedMCPAnswer(
            toolResult: toolResult,
            userQuery: query,
            appName: target.adapter.appName
        ) {
            return grounded
        }
        let request = AIRequestBuilder.aiChat(
            text: query,
            history: history
        )
        return try await AIOrchestrationEngine.shared.submit(
            AIOrchestrationRequest(
                providerRequest: request,
                scope: currentAISelectionSnapshot.isEmpty
                    ? .general : .selection(currentAISelectionSnapshot),
                policy: .generalChat,
                providerSelection: providerSelection,
                contextPrompt: prompt
            )
        ).text
    }

    func directGeneralNotesMCPAnswer(query: String) async throws -> String? {
        guard AppSettings.shared.noteMCPEnabled else { return nil }
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.contains("note") || normalized.contains("notes") else { return nil }

        let wantsCount = normalized.contains("how many")
            || normalized.contains("count")
            || normalized.contains("number of")
        let wantsSearch = normalized.contains("find")
            || normalized.contains("search")
            || normalized.hasPrefix("any ")
            || normalized.contains(" any ")
            || normalized.contains("with ")
            || normalized.contains("containing")
            || normalized.contains("about")
        guard wantsCount || wantsSearch else { return nil }

        if wantsCount && !wantsSearch {
            let count = try await AppleNotesMCPServer.shared.noteCount()
            return "There are \(count) notes."
        }
        let notes = try await AppleNotesMCPServer.shared.allMetadata()
        let searchTerm = notesSearchTerm(from: normalized)
        let matches = searchTerm.isEmpty
            ? notes
            : try await AppleNotesMCPServer.shared.search(query: searchTerm, maxResults: 12)
        return formatNotesSearchResponse(matches, query: searchTerm)
    }

    func generalMCPAppTarget(for query: String) -> (adapter: AppAdapter, score: Int)? {
        let normalized = query.lowercased()
        var best: (adapter: AppAdapter, score: Int)?
        for adapter in AppAdapterManager.shared.adapters where adapter.isEnabled {
            let servers = MCPServerManager.shared.servers(forBundleId: adapter.bundleId)
            guard !servers.isEmpty else { continue }
            let appName = adapter.appName.lowercased()
            let bundle = adapter.bundleId.lowercased()
            let serverNames = servers.map { $0.name.lowercased() }
            var score = 0
            if normalized.contains(appName) { score += 20 }
            // Singular/plural tolerance: "artifact" must match the "Artifacts" adapter.
            if appName.hasSuffix("s"), normalized.contains(String(appName.dropLast())) {
                score += 16
            }
            if normalized.contains(appName.replacingOccurrences(of: " ", with: "")) { score += 14 }
            if normalized.contains(bundle) { score += 12 }
            for part in bundle.split(separator: ".").map(String.init) where part.count > 3 {
                if normalized.contains(part) { score += 5 }
            }
            for server in serverNames where normalized.contains(server) {
                score += 10
            }
            if score == 0 { continue }
            if best == nil || score > best!.score {
                best = (adapter, score)
            }
        }
        return best
    }

    func selectGeneralMCPTool(
        from tools: [(server: String, serverId: UUID, tool: MCPTool)],
        query: String
    ) -> (server: String, serverId: UUID, tool: MCPTool)? {
        let normalized = query.lowercased()
        let preferredNames: [String]
        if normalized.contains("link") || normalized.contains("url") || normalized.contains("item")
            || normalized.contains("movie") || normalized.contains("favorite")
            || normalized.contains("how many") || normalized.contains("count")
        {
            preferredNames = ["search_items", "search", "list_items", "list", "get_items"]
        } else {
            preferredNames = ["search_items", "search", "list", "get"]
        }
        for preferred in preferredNames {
            if let match = tools.first(where: { $0.tool.name.lowercased() == preferred }) {
                return match
            }
        }
        return tools.first { entry in
            let name = entry.tool.name.lowercased()
            return name.contains("search") || name.contains("list")
        } ?? tools.first
    }

    func generalMCPArguments(for tool: MCPTool, query: String, appName: String) -> [String: Any] {
        let term = generalMCPSearchTerm(from: query, appName: appName)
        let properties = ((tool.inputSchema["properties"] as? [String: Any]) ?? [:])
        guard !properties.isEmpty else {
            return ["query": term, "limit": 50]
        }

        var arguments: [String: Any] = [:]
        for key in properties.keys {
            let lower = key.lowercased()
            if ["query", "q", "search", "term", "text", "filter"].contains(lower) {
                arguments[key] = term
            } else if ["limit", "max", "maxresults", "max_results", "count"].contains(lower) {
                arguments[key] = 50
            }
        }
        if arguments.isEmpty,
           properties.keys.contains(where: { $0.lowercased().contains("query") }) {
            arguments["query"] = term
        }
        return arguments
    }

    func generalMCPSearchTerm(from query: String, appName: String) -> String {
        var cleaned = query.lowercased()
        for token in [appName.lowercased(), appName.lowercased().replacingOccurrences(of: " ", with: ""), "app"] {
            cleaned = cleaned.replacingOccurrences(of: token, with: " ")
        }
        let stopwords: Set<String> = [
            "how", "many", "link", "links", "url", "urls", "item", "items", "have",
            "has", "do", "does", "did", "any", "with", "there", "are", "is", "in",
            "about", "show", "me", "please", "the", "a", "an", "i", "my"
        ]
        return cleaned
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !stopwords.contains($0) }
            .joined(separator: " ")
    }

    func jsonString(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    /// Prompt block describing enabled built-in app capabilities (Notes, Calendar,
    /// Contacts, Reminders, GitHub) so the general chat can call them via the same
    /// mcp_call JSON with server "builtin". Empty when none are enabled.
    func builtInCapabilityPromptBlock() async -> String {
        await MainActor.run {
            let prefixes = [
                "notes.", "calendar.", "contacts.", "reminders.", "photos.", "mail.", "music.",
                "messages.", "github.",
            ]
            let caps = CapabilityRegistry.shared.all.filter { cap in
                prefixes.contains(where: cap.id.hasPrefix)
            }
            var lines: [String] = []
            if !caps.isEmpty {
                lines.append(contentsOf: [
                    "## Built-in App Tools",
                    "You can also call these built-in tools with the same single-line JSON format, using server \"builtin\":",
                    "{\"mcp_call\": {\"server\": \"builtin\", \"tool\": \"<tool id>\", \"arguments\": { … }}}",
                    "",
                    "Available built-in tools:",
                ])
                for cap in caps {
                    let fields = cap.inputSchema.fields.map { f in
                        "\(f.name)\(f.required ? "" : "?")"
                    }.joined(separator: ", ")
                    lines.append("- \(cap.id): \(cap.title) | input: [\(fields)]")
                }
            }

            // Selection Scope actions — runnable on the attached file/selection via the
            // extension.run tool. Only file/selection-triggered extensions are listed.
            let selectionManifests = ExtensionRegistry.shared.manifests.filter { manifest in
                manifest.extensionValue.triggers.contains { trigger in
                    if case .selection = trigger { return true }
                    if case .fileType = trigger { return true }
                    return false
                }
            }
            if !selectionManifests.isEmpty {
                if !lines.isEmpty { lines.append("") }
                lines.append("## Selection Scope actions (run on the attached file/selection)")
                lines.append(
                    "Run one with: {\"mcp_call\": {\"server\": \"builtin\", \"tool\": \"extension.run\", \"arguments\": {\"extensionID\": \"<id>\"}}}")
                for manifest in selectionManifests.prefix(30) {
                    lines.append("- \(manifest.id.uuidString): \(manifest.name) — \(manifest.summary)")
                }
            }

            return lines.joined(separator: "\n")
        }
    }

    /// Execute a built-in capability requested from the general chat tool loop.
    /// Returns nil when `tool` is not a registered capability (so the MCP path runs).
    /// Medium/high-risk capabilities still go through the normal approval UI.
    func executeBuiltInCapability(tool: String, arguments: [String: Any]) async -> String? {
        let isRegistered = await MainActor.run {
            CapabilityRegistry.shared.capability(id: tool) != nil
        }
        guard isRegistered else { return nil }
        let isAllowlisted = await MainActor.run { () -> Bool in
            guard let bundleID = CapabilityRegistry.shared.capability(id: tool)?.appBundleID else {
                return true
            }
            return AppAdapterManager.shared.adapter(for: bundleID) != nil
        }
        guard isAllowlisted else {
            return "That app isn’t added to App Adapters, so General AI cannot use \(tool)."
        }
        let input = arguments.mapValues { value -> String in
            if let s = value as? String { return s }
            return "\(value)"
        }
        let plan = AIActionPlan(
            capability: tool, input: input, explanation: "Requested from AI chat"
        )
        // Selection-scope tools (extension.run) act on the file/text the user attached
        // to the chat — pass it as the execution context instead of .none, so an
        // "OCR this image" style action runs on the attachment.
        let execContext: UserContext = await MainActor.run {
            if !aiMode.selectionFiles.isEmpty {
                return .filesSelected(aiMode.selectionFiles)
            }
            let sel = AXContextReader.shared.current.selectedText?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return sel.isEmpty ? .none : .textSelected(sel)
        }
        do {
            let result = try await AIExecutionEngine.shared.executeWithApproval(
                plan, context: execContext
            )
            return result.output
        } catch {
            return "Tool \(tool) failed: \(error.localizedDescription)"
        }
    }

    /// Deterministic last-mile routing for Context Dock app UI commands. Relevant linked
    /// integrations retain priority; otherwise DoraX refreshes the live frontmost menu and
    /// executes its verified shortcut/menu locally instead of allowing shell substitution.
    @MainActor
    private func scopedFrontmostMenuFallbackAnswer(
        query: String,
        bundleId: String,
        appName: String
    ) async -> String? {
        guard !bundleId.isEmpty,
            GeneralAIActionResolver.shared.looksExecutable(query),
            let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == bundleId && !$0.isTerminated
            }),
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId
        else { return nil }

        let matchingActions = AppAdapterManager.shared.actions(for: bundleId, query: query)
            .filter { $0.type != .aiPrompt }
        let matchingCLI = TerminalPackageManager.shared.packages(
            forContextBundleId: bundleId,
            query: query,
            maxResults: 1
        )
        let queryTokens = Set(query.lowercased().split {
            !$0.isLetter && !$0.isNumber
        }.map(String.init))
        let matchingMCP = await MCPRuntime.shared.cachedTools(forBundleId: bundleId).contains {
            let toolTokens = Set($0.tool.name.lowercased().split {
                $0 == "_" || $0 == "-" || $0.isWhitespace
            }.map(String.init))
            return !queryTokens.isDisjoint(with: toolTokens)
        }
        // Tools always win: MCP, CLI, and adapter actions take priority. Menus are
        // GUIDANCE ONLY — never executed from chat. So if any tool matches, bail and
        // let the capability planner handle it; only fall to menu guidance when no
        // tool matches at all.
        // Built-in Apple MCP caps (Messages/Notes/Calendar/…) also count as tools and
        // must win — the capability planner runs after this, so defer to it.
        let mcpFamilies = ["notes.", "calendar.", "contacts.", "reminders.", "messages.", "github."]
        let hasBuiltInMCP = CapabilityRegistry.shared
            .capabilities(for: bundleId)
            .contains { cap in mcpFamilies.contains(where: cap.id.hasPrefix) }
        guard matchingActions.isEmpty, matchingCLI.isEmpty, !matchingMCP, !hasBuiltInMCP
        else { return nil }

        if let requestID = l2.activeRequestID {
            setL2LoadingStatus("Reading \(appName) live menus…", requestID: requestID)
            await Task.yield()
        }
        let liveItems = AXMenuReader.shared.refreshAllMenuItems(
            for: app.processIdentifier,
            maxDepth: 6
        )
        if !liveItems.isEmpty {
            AppMenuCapabilityCache.shared.store(items: liveItems, for: app)
        }

        // Menus are guidance only — return the path (and shortcut) as instructions,
        // never click them.
        guard let match = bestMenuMatch(
            intent: query,
            bundleId: bundleId,
            appName: appName,
            processIdentifier: app.processIdentifier
        ) else {
            let closest = menuSuggestions(
                intent: query,
                bundleId: bundleId,
                appName: appName,
                processIdentifier: app.processIdentifier
            )
            if closest.isEmpty { return nil }
            return "I don’t have a tool that does “\(query)” in \(appName), but you can do it from the menus:\n"
                + closest.joined(separator: "\n")
        }
        let path = match.path.joined(separator: " → ")
        let shortcut = MenuShortcutFormatter.display(
            char: match.shortcutChar, modifiers: match.shortcutModifiers)
        let shortcutHint = shortcut.map { "  (\($0))" } ?? ""
        if !match.isEnabled {
            return "You can do this in \(appName) via **\(path)**\(shortcutHint) — it’s currently greyed out, so it may need a selection or different state first."
        }
        return "You can do this in \(appName): **\(path)**\(shortcutHint)."
    }

    func sendToAIProviderWithContext(query: String, messageHistory: [AIChatMessage])
        async throws -> String
    {
        // Pick up MCPs toggled on this session so scoped chat sees them without relaunch.
        CapabilityRegistry.shared.refreshBuiltInMCPs()
        let scopedForRead = currentContextDockChatScope
        let isMessagesScope = scopedForRead.bundleId.caseInsensitiveCompare(
            "com.apple.MobileSMS") == .orderedSame
            || scopedForRead.appName.lowercased().contains("messages")
        if isMessagesScope || readOnlyDataDomain(for: query) == .messages,
            let readAnswer = await readOnlyCapabilityAnswer(query: query)
        {
            return readAnswer
        }
        if !isGlobalQueryModeActive,
            let menuAnswer = await scopedFrontmostMenuFallbackAnswer(
                query: query,
                bundleId: scopedForRead.bundleId,
                appName: scopedForRead.appName
            )
        {
            return menuAnswer
        }
        let providerSelection = AIProviderSelectionResolver.current(settings: settings)
        // Build context from provided message history (for L2, uses l2.chatMessages)
        var context = messageHistory.map { msg in
            ["role": msg.role == .user ? "user" : "assistant", "content": msg.content]
        }

        // Build system message with live AX context
        var sysL2 = """
            You are an intelligent macOS assistant integrated into ILauncher.
            You can use pre-built extensions, answer questions directly, and suggest creating new extensions for recurring tasks.

            When responding:
            - If an extension was mentioned and user confirms (yes/ok/sure), provide the extension code you suggested
            - Maintain conversation context across multiple messages
            - Be helpful and actionable
            - Remember what you suggested in previous messages
            - You can analyze images when they are provided
            """
        if isGlobalQueryModeActive {
            sysL2 += """

                Global Context mode is active.
                - Prefer cross-app and system-wide actions over frontmost-app menu actions.
                - Treat the frontmost app only as passive payload context unless the user explicitly names that app.
                - For commands like system settings, VPN, Terminal, Safari history, Finder actions, or app switching, prefer orchestration over frontmost-app menu execution.
                """
        }
        sysL2 += "\n\n" + currentDateTimeContextBlock()
        let scoped = currentContextDockChatScope
        let identityBlock = scopedAppIdentityBlock(
            bundleId: scoped.bundleId,
            appName: scoped.appName
        )
        if !identityBlock.isEmpty {
            sysL2 += "\n\n" + identityBlock
        }
        if !isGlobalQueryModeActive {
            sysL2 += """


                ## Scoped App Execution Rules
                This chat is temporarily scoped to the frontmost app \(scoped.appName) (\(scoped.bundleId)).
                Its live menu may be inspected and executed even when no App Adapter exists, because the user explicitly opened this frontmost-app scope.
                App Adapter integrations (actions, readers, MCP, API, CLI, skills, and saved capabilities) remain available only when configured for this app.
                Prefer, in order: adapter action, MCP/API, linked CLI, macOS Shortcut, then a verified app menu.
                When no linked action/tool matches an app UI command, use the scoped app's known menu catalog.
                Prefer the live-verified menu item's keyboard shortcut; if it has none or sending it fails, click the live-verified menu item.
                Never claim an action ran from prose alone. Report only the executor's returned result.
                If no exact menu matches, say nothing was executed and provide the closest known menu paths.
                """
        }
        if let guardedAnswer = scopedChatMissingInternalDataAnswer(
            query: query,
            bundleId: scoped.bundleId,
            appName: scoped.appName
        ) {
            return guardedAnswer
        }
        let axL2 = sanitizedAXContextForScope(
            effectiveAXContextForConversation(),
            scopedBundleId: scoped.bundleId
        )
        if !axL2.isEmpty {
            sysL2 +=
                "\n\n## Live App Context (use this to ground your answers)\n" + axL2.contextSummary
        }
        let menuCapabilityJSONBlock =
            isGlobalQueryModeActive ? "" : currentFrontmostMenuCapabilityJSONBlock()
        if !menuCapabilityJSONBlock.isEmpty {
            sysL2 += "\n\n" + menuCapabilityJSONBlock
        }
        // Deep per-app context (current file, git branch, selected files, etc.)
        if !isGlobalQueryModeActive && !adapterContextData.isEmpty {
            sysL2 += "\n\n## Deep App Context\n"
            sysL2 += adapterContextData.values.joined(separator: "\n")
        }
        // Inject web research session (pages added via + button on browser)
        let research = WebResearchSession.shared
        let researchHasContent = research.pages.contains { !$0.text.isEmpty }
        if !research.isEmpty && researchHasContent {
            sysL2 += research.count > 1 ? research.contextBlock : research.singlePageBlock
        }
        // Inject compact Safari tag list ONLY for cloud AI providers.
        // On-device AI: Tier 1 parseIntent() handles it — no tokens wasted.
        let safariCommandsAvailable =
            frontmost.bundleID == "com.apple.Safari"
            || l2.targetApp?.bundleId == "com.apple.Safari"
        let isCloudProvider = providerSelection.effectiveProvider != .onDevice
        if safariCommandsAvailable && isCloudProvider {
            sysL2 += "\n\n" + SafariCommandBridge.compactSystemPromptBlock
        }
        let systemMessage: [String: String] = ["role": "system", "content": sysL2]

        // Insert system message at the beginning
        context.insert(systemMessage, at: 0)

        // Check if we have image files selected (for vision support)
        var imageFiles: [URL] = []
        if case .filesSelected(let urls) = currentScopedConversationContext() {
            imageFiles = urls.filter { url in
                let ext = url.pathExtension.lowercased()
                return ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "heic", "webp"].contains(ext)
            }
        }

        return try await sendToProvider(
            query: query,
            context: context,
            imageFiles: imageFiles,
            providerSelection: providerSelection
        )
    }

    // Direct provider sender that accepts pre-built context (used by L2 for custom prompts)
    // Common provider router
    func sendToProvider(query: String, context: [[String: String]]) async throws -> String {
        return try await sendToProvider(
            query: query,
            context: context,
            imageFiles: [],
            providerSelection: AIProviderSelectionResolver.current(settings: settings)
        )
    }

    // Common provider router with image support
    func sendToProvider(
        query: String,
        context: [[String: String]],
        imageFiles: [URL],
        providerSelection: AIProviderSelection
    )
        async throws -> String
    {
        var systemPrompt = context
            .filter { $0["role"] == "system" }
            .compactMap { $0["content"] }
            .joined(separator: "\n\n")
        // Context Dock chat may use real Apple-apps data + weather, but only when the
        // scoped app/query explicitly targets those apps. Otherwise scoped questions like
        // "what scheduled tasks did I have in ChatGPT/Codex" can be answered from Calendar.
        let scoped = currentContextDockChatScope
        if shouldInjectAppleAppsAndWeatherContext(
            for: query,
            scopedBundleId: scoped.bundleId,
            scopedAppName: scoped.appName
        ) {
            let appleData = await appleAppsAndWeatherContext(for: query)
            if !appleData.isEmpty {
                systemPrompt += "\n\n" + appleData
            }
        }
        let history = context.compactMap { item -> ChatMessage? in
            guard let roleValue = item["role"],
                  roleValue != "system",
                  let role = ChatMessage.MessageRole(rawValue: roleValue),
                  let content = item["content"]
            else { return nil }
            return ChatMessage(role: role, content: content)
        }
        let lowerQuery = query.lowercased()
        let planningBundleID = isGlobalQueryModeActive
            ? nil
            : (l2.targetApp?.bundleId ?? AXContextReader.shared.current.bundleId)
        // Read/data questions must reach the tools too — not just executable verbs.
        // If the active scope (or general chat) has built-in MCP capabilities, a data
        // question should plan a tool call instead of the model saying "no tool".
        let mcpFamilies = ["notes.", "calendar.", "contacts.", "reminders.", "messages.", "github."]
        let scopeHasBuiltInMCP = CapabilityRegistry.shared
            .capabilities(for: planningBundleID)
            .contains { cap in mcpFamilies.contains(where: cap.id.hasPrefix) }
        let readIntent =
            query.hasSuffix("?")
            || [
                "recent", "how many", "list", "show", "find", "search",
                "what ", "when ", "who ", "which ", "last ", "any ", "read ",
            ].contains { lowerQuery.contains($0) }
        let capabilityPlanningRequested =
            GeneralAIActionResolver.shared.looksExecutable(query)
            || [
                "run ", "execute ", "rename ", "reveal ", "open ", "close ",
                "summarize this page", "create ", "delete ", "update ", "send ",
                "compose ", "call ", "use ", "do ", "print", "settings", "extensions",
                "bookmarks", "history",
            ].contains { lowerQuery.contains($0) }
            || (scopeHasBuiltInMCP && readIntent)
        let request = isGlobalQueryModeActive
            ? AIRequestBuilder.globalContext(
                text: query,
                context: effectiveConversationUserContext,
                history: history,
                attachments: imageFiles,
                mode: capabilityPlanningRequested ? .plan : .answer,
                capabilityPrompt: capabilityPlanningRequested
                    ? AIActionPlanner.shared.capabilityPlanningPrompt(bundleID: planningBundleID)
                    : ""
            )
            : AIRequestBuilder.contextDock(
                text: query,
                context: currentScopedConversationContext(),
                history: history,
                attachments: imageFiles,
                mode: capabilityPlanningRequested ? .plan : .answer,
                capabilityPrompt: capabilityPlanningRequested
                    ? AIActionPlanner.shared.capabilityPlanningPrompt(
                        bundleID: planningBundleID
                    )
                    : ""
            )
        let response = try await AIOrchestrationEngine.shared.submit(
            AIOrchestrationRequest(
                providerRequest: request,
                scope: isGlobalQueryModeActive
                    ? .general
                    : .contextDock(bundleID: scoped.bundleId, appName: scoped.appName),
                policy: isGlobalQueryModeActive ? .generalChat : .frontmostAppChat,
                providerSelection: providerSelection,
                contextPrompt: systemPrompt
            )
        ).text
        guard capabilityPlanningRequested else { return response }
        do {
            let plan = try AIResponseParser.shared.parseActionPlan(response)
            let executionScope: AIConversationScope = isGlobalQueryModeActive
                ? .general
                : .contextDock(bundleID: scoped.bundleId, appName: scoped.appName)
            try CapabilityAuthorizationGate.validatePlan(plan, scope: executionScope)
            let result = try await AIExecutionEngine.shared.executeWithApproval(
                plan,
                context: isGlobalQueryModeActive
                    ? effectiveConversationUserContext
                    : currentScopedConversationContext()
            )
            return await AIResultExplanationService.shared.explain(
                plan: plan,
                result: result,
                context: isGlobalQueryModeActive
                    ? effectiveConversationUserContext
                    : currentScopedConversationContext(),
                provider: providerSelection.effectiveProvider
            )
        } catch AICapabilityError.invalidPlan {
            return response
        }
    }

    var smartQueryMeta: (icon: String, label: String, appPath: String) {
        switch searchState.activeSmartQueryKey ?? "" {
        case "calendar": return ("calendar", "Calendar", "/System/Applications/Calendar.app")
        case "reminders":
            return ("checkmark.circle", "Reminders", "/System/Applications/Reminders.app")
        case "clipboard":
            return ("doc.on.clipboard", "Clipboard", "")
        case "notifications":
            return ("bell.badge", "Notifications", "")
        case "windows":
            return ("macwindow.on.rectangle", "Window Preview", "")
        case "notes": return ("note.text", "Notes", "/System/Applications/Notes.app")
        case "mail": return ("envelope", "Mail", "/System/Applications/Mail.app")
        case "photos": return ("photo.on.rectangle", "Photos", "/System/Applications/Photos.app")
        case "messages": return ("message", "Messages", "/System/Applications/Messages.app")
        case "contacts": return ("person.2", "Contacts", "/System/Applications/Contacts.app")
        case "safari": return ("safari", "Safari Tabs", "/Applications/Safari.app")
        default:
            // Check custom app entries
            if let key = searchState.activeSmartQueryKey,
                let entry = settings.customAppEntries.first(where: { $0.key == key })
            {
                return (entry.iconName, entry.label, entry.appPath)
            }
            return ("apps.iphone", "App", "")
        }
    }

    // Items to show in the app panel — filtered by search text if any
    var appPanelDisplayedItems: [SearchResult] {
        let q = searchState.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return searchState.appPanelAllItems }
        let filtered = searchState.appPanelAllItems.filter {
            $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q)
        }
        return filtered.isEmpty ? searchState.appPanelAllItems : filtered
    }

}
