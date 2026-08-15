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

/// The General Chat conversation, on disk. Not private: the standalone chat window
/// reads and writes the same key, so one conversation continues across the result
/// sheet and the window instead of the two drifting apart.
enum GeneralAIChatConversationStore {
    private static let key = "dorax.generalAI.currentConversation.v1"

    private struct StoredAppLaunch: Codable {
        let label: String
        let systemIcon: String
        let bundleId: String
    }

    private struct StoredRecentFile: Codable {
        let path: String
    }

    private struct StoredMessage: Codable {
        let role: String
        let content: String
        let isError: Bool
        let structuredData: String?
        let hasInstallButton: Bool
        let attachments: [String]
        let appLaunches: [StoredAppLaunch]
        // Optional preserves conversations saved before file rows existed.
        let recentFiles: [StoredRecentFile]?
        let mcpToolsRan: [String]
    }

    /// Keyed variants, so per-scope sessions can reuse this exact serialisation instead of
    /// inventing a second message format that would drift from it.
    static func load(key storageKey: String) -> [AIChatMessage] {
        loadMessages(forKey: storageKey)
    }

    static func save(_ messages: [AIChatMessage], key storageKey: String) {
        saveMessages(messages, forKey: storageKey)
    }

    static func load() -> [AIChatMessage] {
        loadMessages(forKey: key)
    }

    private static func loadMessages(forKey key: String) -> [AIChatMessage] {
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
                recentFiles: (item.recentFiles ?? []).map {
                    RecentFileAction(url: URL(fileURLWithPath: $0.path))
                },
                mcpToolsRan: item.mcpToolsRan
            )
        }
    }

    static func save(_ messages: [AIChatMessage]) {
        saveMessages(messages, forKey: key)
    }

    private static func saveMessages(_ messages: [AIChatMessage], forKey key: String) {
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
                recentFiles: message.recentFiles.map { StoredRecentFile(path: $0.url.path) },
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

    var contextDockBrowserBundleIDs: Set<String> { ScopedAppPromptBuilder.browserBundleIDs }

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
        ScopedAppPromptBuilder.isBrowserBundle(bundleId)
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
    func browserScopeContextBlock(scopedBundleId: String, query: String? = nil) -> String {
        let bundle = scopedBundleId.isEmpty ? frontmost.bundleID : scopedBundleId
        guard isContextDockBrowserBundle(bundle) else { return "" }

        var pageTitle = ""
        var pageURL = ""
        var pageText = ""
        var selected = ""
        var links: [SafariPageLink] = []

        // 1) Safari Web Extension payload — preferred when fresh.
        if SafariBrowserBridge.shared.isFresh,
            let ext = SafariBrowserBridge.shared.currentContext() {
            pageTitle = ext.title
            pageURL = ext.url
            pageText = ext.pageTextForAI
            selected = ext.selectedText
            links = ext.links
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
        // The extension already removes browser chrome and sends readable page text. Run the
        // same query-aware Markdown compactor used for documents before this enters a model
        // context. Re-fetching the URL through MarkItDown would be slower, could see a
        // different signed-out page, and would discard the user's live selection/state.
        if !pageText.isEmpty {
            pageText = MarkItDownService.compact(pageText, for: query, limit: 5_000)
        }
        let selectedSection = selected.isEmpty
            ? "" : "\nSELECTED TEXT:\n\(String(selected.prefix(1500)))"
        // Where the page can take the user. Page text drops every href, so a download or
        // docs button reads as an ordinary word — the model then says it cannot find one.
        let linkSection: String = {
            guard !links.isEmpty else { return "" }
            let rows = links.prefix(30).map { "- \($0.text) → \($0.url)" }
            return """

                PAGE LINKS (action links first, as they appear on the page):
                \(rows.joined(separator: "\n"))
                Use these exact URLs when the answer is a page to open — never invent one,                 and never tell the user to hunt for a button that is listed here.
                """
        }()
        return """
            CURRENT PAGE TITLE: \(pageTitle.isEmpty ? "(unknown)" : pageTitle)
            CURRENT PAGE URL: \(pageURL.isEmpty ? "(unknown)" : pageURL)\(selectedSection)
            \(pageText.isEmpty
                ? "PAGE TEXT: (unavailable — could not read the page)"
                : "PAGE TEXT EXCERPT:\n\(String(pageText.prefix(5000)))")\(linkSection)
            """
    }

    /// Identity + integration inventory for the scoped app. ALWAYS injected into
    /// scoped chat so the model knows which app it serves, what the app is, and
    /// every tool it may pick (actions, CLI, MCP, API, shortcuts) — or what to
    /// suggest adding when nothing fits.
    @MainActor
    /// Joins prompt sections in priority order while staying inside a character budget the
    /// on-device model can actually hold. Sections that no longer fit are dropped whole —
    /// a truncated JSON block or half a menu list is worse than its absence.
    static func budgetedContextPrompt(_ sections: [String], limit: Int = 3_200) -> String {
        var used = 0
        var kept: [String] = []
        for section in sections {
            let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let cost = trimmed.count + 2
            guard used + cost <= limit else { continue }
            kept.append(trimmed)
            used += cost
        }
        return kept.joined(separator: "\n\n")
    }

    /// - Parameter compact: trims the block for Apple's on-device model, whose context
    ///   window the full inventory (50 menu paths + every rule paragraph) overruns — the
    ///   model then stalls with no token and the chat times out.
    /// The dock's view of the shared scoped-app prompt. Only the live browser page, the AX
    /// window title and the typed query come from here; the block itself is built by
    /// ScopedAppPromptBuilder so the chat window grounds an app the same way.
    func scopedAppIdentityBlock(
        bundleId: String, appName: String, compact: Bool = false
    ) -> String {
        let host =
            currentBrowserPageURL()?.host
            ?? webResearch.pages.last.flatMap { URL(string: $0.url)?.host }
        return ScopedAppPromptBuilder.appIdentityBlock(
            bundleId: bundleId,
            appName: appName,
            query: searchState.query,
            compact: compact,
            windowTitle: axContext.bundleId == bundleId ? axContext.windowTitle : nil,
            browserHost: host
        )
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
                // This session only. The history before it belongs to the chat window's
                // thread and is not the dock's to delete.
                AppPanelChatStore.shared.clearSession(for: key)
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
            AppPanelChatStore.shared.saveSession(l2.chatMessages, for: key)
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

    /// Shared non-destructive exit used by the header button and empty-field Backspace.
    /// Persist the app chat, cancel in-flight work, then hide the sheet. Conversation deletion
    /// belongs exclusively to the visible Clear/trash control.
    func clearAndExitContextDockChatBackToContext() {
        withAnimation(.dockStandard) {
            if let key = l2.activeDockSessionKey {
                AppPanelChatStore.shared.saveSession(l2.chatMessages, for: key)
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
        if wasCLIToolScope {
            // A CLI tool session is bound to the scope, not to an app the user returns to:
            // leaving it ends the run. Keeping the transcript meant the next scope opened
            // on the previous tool's conversation, and the model carried that history into
            // its first command.
            l2.chatMessages = []
            if let key = l2.activeDockSessionKey {
                // A CLI run ends with its scope, so this session goes; anything the window
                // holds for that tool stays.
                AppPanelChatStore.shared.clearSession(for: key)
            }
            l2.isLoading = false
            l2.loadingStatus = nil
            l2.activeRequestID = nil
            l2.currentTask?.cancel()
            l2.currentTask = nil
            contextDockChatCapturedText = nil
            contextDockChatFiles = []
            CLIScopeTerminalManager.shared.reset()
        }
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
            cliScopeWindowPinControl
            frontmostAppWindowControl
            contextDockChatCloseButton
        }
    }

    /// Moves the frontmost-app conversation into the chat window as its own thread.
    ///
    /// Same handover as the CLI control beside it: the transcript goes with it, the sheet
    /// closes, and the thread stays available afterwards whether or not the app is running.
    @ViewBuilder
    var frontmostAppWindowControl: some View {
        // The app this chat is with, not whatever happens to be frontmost. Those differ
        // constantly — the dock floats over VS Code while Finder is frontmost — and using
        // the frontmost one filed a Code conversation under Finder.
        let chatScope = currentContextDockChatScope
        let bundleId = chatScope.bundleId
        let appName = chatScope.appName
        if activeCLIScopePackage == nil {
            chatWindowHandoffControl(bundleId: bundleId, appName: appName)
        }
    }

    /// Closes the dock behind a handover. `hideLauncherAfterResultExecution` deliberately
    /// keeps the dock up in always-float and taskbar modes, which is right for running an
    /// action and wrong here: the conversation has moved, and leaving the sheet showing the
    /// same thread gives the user two copies of it, one of which is already stale.
    /// Sends a file to the chat window's Preview and hands the conversation over with it.
    ///
    /// Opening it in Preview.app or an editor takes the user out of the chat to read one
    /// file, and back again to say anything about it. The window shows the document and the
    /// conversation at the same time, which is what reading-and-replying actually requires.
    func previewFileInChatWindow(_ url: URL, bundleId: String, appName: String) {
        GeneralChatWindowModel.shared.pendingPreviewFile = url
        GeneralChatWindowModel.shared.openSession(
            .app(bundleId: bundleId), title: appName, seed: l2.chatMessages)
        handOffChatToWindow()
        GeneralChatWindowController.shared.show()
    }

    /// Moves the General AI thread to the window with the artifact it just built showing.
    ///
    /// The dock's own path auto-opens because an app-scoped chat already carries a window
    /// glyph — the handover is a gesture the user knows. General chat has no such glyph, so
    /// a window appearing unasked would be the app taking over a sheet the user is reading.
    /// Here it is a press, next to Clear.
    func openGeneralChatArtifactInWindow() {
        guard let artifact = generalChatArtifact else { return }
        GeneralChatWindowModel.shared.pendingPreviewFile = artifact
        GeneralChatWindowModel.shared.openSession(
            .general, title: "General", seed: aiMode.messages)
        GeneralChatWindowController.shared.show()
        aiMode.currentTask?.cancel()
        aiMode.currentTask = nil
        aiMode.isLoading = false
        aiMode.loadingStatus = nil
        searchState.query = ""
        isSearchFieldFocused = false
        AppDelegate.shared?.hideLauncher(force: true)
    }

    func handOffChatToWindow() {
        if let key = l2.activeDockSessionKey {
            AppPanelChatStore.shared.saveSession(l2.chatMessages, for: key)
        }
        l2.currentTask?.cancel()
        l2.currentTask = nil
        l2.isLoading = false
        l2.loadingStatus = nil
        l2.activeRequestID = nil
        exitContextDockChatBackToContext()
        searchState.query = ""
        isSearchFieldFocused = false
        AppDelegate.shared?.hideLauncher(force: true)
    }

    /// The window glyph itself, so every app-scoped chat surface can carry it rather
    /// than only the toolbar one. A conversation the user can hand off in one header
    /// and not in another reads as the feature being broken, not as two surfaces.
    @ViewBuilder
    func chatWindowHandoffControl(bundleId: String, appName: String) -> some View {
        if !bundleId.isEmpty,
            !appName.isEmpty,
            !bundleId.hasPrefix("cli://"),
            !bundleId.hasPrefix("scope://"),
            bundleId != Bundle.main.bundleIdentifier
        {
            let scope = GeneralChatScope.app(bundleId: bundleId)
            let isOpen = GeneralChatWindowModel.shared.sessions.contains { $0.scope == scope }
            Button {
                GeneralChatWindowModel.shared.openSession(
                    scope, title: appName, seed: l2.chatMessages)
                GeneralChatWindowController.shared.show()
                handOffChatToWindow()
            } label: {
                Image(systemName: isOpen ? "macwindow.badge.plus" : "macwindow")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(
                        isOpen
                            ? AnyShapeStyle(Color.green.opacity(0.9))
                            : AnyShapeStyle(.secondary.opacity(0.70)))
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .help(
                isOpen
                    ? "Update the \(appName) thread in the chat window"
                    : "Open \(appName) as a thread in the chat window")
        }
    }

    /// Detaches a CLI tool scope into its own floating window, the way Quick Note works.
    ///
    /// Separate from the pin beside it, which floats the whole dock: this one gives the tool
    /// a window that keeps its transcript after the dock moves on, so `tailscale` can stay
    /// open and answerable while the launcher goes back to being a launcher. Shown only in a
    /// cli:// scope, since that is the only place it means anything.
    @ViewBuilder
    var cliScopeWindowPinControl: some View {
        if let package = activeCLIScopePackage {
            let scope = GeneralChatScope.cli(command: package.command)
            let isOpen = GeneralChatWindowModel.shared.sessions.contains { $0.scope == scope }
            Button {
                // The general chat window is the hub: a tool opens as a thread in its
                // sidebar rather than as another floating panel, so every app and tool the
                // user talks to lives in one place and stays there when the dock moves on.
                GeneralChatWindowModel.shared.openSession(
                    scope, title: package.command, seed: l2.chatMessages)
                GeneralChatWindowController.shared.show()
                // The conversation moved; leaving the sheet showing the same thread would
                // give the user two copies of it, one of which is now stale.
                handOffChatToWindow()
            } label: {
                Image(systemName: isOpen ? "macwindow.badge.plus" : "macwindow")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(
                        isOpen
                            ? AnyShapeStyle(Color.green.opacity(0.9))
                            : AnyShapeStyle(.secondary.opacity(0.70)))
                    .frame(width: 22, height: 22)
                    .background(
                        isOpen ? Color.green.opacity(0.16) : Color.white.opacity(0.07),
                        in: Circle())
            }
            .buttonStyle(.plain)
            .help("Open \(package.command) as a thread in the chat window")
        }
    }

    /// Trailing pin toggle (replaces the old duplicate "−" close button — the scope
    /// chip's "−" already exits the chat). Pinned = launcher floats over every app
    /// and never auto-hides until unpinned.
    var contextDockChatCloseButton: some View {
        Button {
            withAnimation(.dockStandard) {
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

    /// The app capsule is an identity/entry control, never a mode toggle. Clicking it always
    /// restores that app's scoped conversation; closing remains exclusive to the capsule's
    /// minus button or the transcript's Exit Scope button.
    func openAppChatFromScopeCapsule(
        appName: String,
        bundleId: String,
        preserveGlobalContext: Bool
    ) {
        guard !appName.isEmpty, !bundleId.isEmpty else { return }

        _ = activateInlineDockAppScope(
            bundleIdentifier: bundleId,
            appName: appName,
            queryOverride: searchState.query,
            expand: true,
            preserveGlobalContext: preserveGlobalContext
        )

        l2.chatDraftAppName = appName
        l2.chatDraftBundleId = bundleId
        armContextDockChat()
        l2.showChatPopover = true
        l2.chatDismissed = false
        livePanelVisible = false
        showFolderPreview = false
        l2.focusedPillIndex = nil
        focusedAppPillIndex = nil
        syncScopeChatSpaceHold()
        requestWindowSizeUpdate(reason: .panelChanged, animated: true)
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
        // In a Finder window the subject is the folder, not the file manager. "Chat with
        // Finder" names the wrong thing twice over: it is not what the user wants to talk
        // about, and it is not what the answer will be scoped to.
        if bundleId == ChatAppDirectory.finderBundleID, isFinderFrontmostWindowContext() {
            let name = currentFinderAIChatFolderURL.lastPathComponent
            if !name.isEmpty { return name }
        }
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
                        if let scopedTarget {
                            chatWindowHandoffControl(
                                bundleId: scopedTarget.bundleId, appName: scopedTarget.name)
                        }
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
                                    // The on-device provider inserts a streaming placeholder.
                                    // Keep the single live activity row visible during that handoff
                                    // instead of rendering a second, empty assistant bubble.
                                    if message.role == .assistant,
                                        message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                        l2.isLoading
                                    {
                                        EmptyView()
                                    } else if message.role == .approval {
                                        l2InlineApprovalCard(message)
                                            .id(message.id)
                                    } else if message.hasInstallButton {
                                        AIChatMessageView(
                                            message: message,
                                            onInstallExtension: installSuggestedExtension,
                                            onInstallProposal: { json in installFromProposal(json)
                                            },
                                            onRunOnceProposal: { json in runOnceFromProposal(json) },
                                            onPreviewFile: { url in
                                                let scope = currentContextDockChatScope
                                                previewFileInChatWindow(
                                                    url, bundleId: scope.bundleId,
                                                    appName: scope.appName)
                                            },
                                            onPickAction: { choice in
                                                runPickedActionChoice(choice, inDock: true)
                                            },
                                            onReminderAction: { reminder, operation in
                                                offerReminderRowAction(reminder, operation: operation)
                                            },
                                            userAvatarSymbol: providerSymbol,
                                            assistantAvatarImage: scopedAppIcon
                                        )
                                        .id(message.id)
                                    } else {
                                        AIChatMessageView(
                                            message: message,
                                            onPreviewFile: { url in
                                                let scope = currentContextDockChatScope
                                                previewFileInChatWindow(
                                                    url, bundleId: scope.bundleId,
                                                    appName: scope.appName)
                                            },
                                            onPickAction: { choice in
                                                runPickedActionChoice(choice, inDock: true)
                                            },
                                            onReminderAction: { reminder, operation in
                                                offerReminderRowAction(reminder, operation: operation)
                                            },
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
                        // When the scoped terminal opens, chat yields viewport height to it
                        // and stays bottom-anchored, like coding-agent transcript panes.
                        // Scoped chat owns a stable viewport. Intrinsic measurement is still
                        // useful for scrolling, but must not resize the outer dock per token.
                        .frame(height: contextDockChatScrollHeight)
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
                        .onChange(of: cliScopeTerminal.isExpanded) { _, _ in
                            guard let last = l2.chatMessages.last else { return }
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                // CLI tool scopes get an embedded live PTY docked at the bottom —
                // it is a bounded drawer in the chat sheet, not a second window.
                if isInCLIToolScope {
                    CLIScopeTerminalPanel(
                        isDark: isEffectiveDark,
                        accentColor: .green,
                        onLayoutChange: {
                            requestWindowSizeUpdate(reason: .panelChanged, animated: true,
                                                    debounceNanoseconds: 0)
                        }
                    )
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

    var contextDockChatScrollHeight: CGFloat {
        guard isInCLIToolScope, cliScopeTerminal.isExpanded else { return 400 }
        // Leave enough history visible above the terminal while keeping the total sheet compact.
        return 180
    }

    /// Second step of "summarise this and mail it to <address>": the content is written, and
    /// this offers it as a Mail draft. Opens a visible draft — never sends. Sending stays the
    /// user's click inside Mail, which is the only place they can see what goes out.
    @ViewBuilder
    func selectionEmailDraftCard(_ draft: PendingSelectionEmail) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "envelope.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 1) {
                Text("Draft email to \(draft.to)?")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(
                    aiMode.selectionFiles.isEmpty
                        ? "Subject: \(draft.subject) · the answer above becomes the body"
                        : "Subject: \(draft.subject) · body + \(aiMode.selectionFiles.count) attachment(s)"
                )
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button("Cancel") { aiMode.pendingEmailDraft = nil }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("Draft") {
                let d = draft
                aiMode.pendingEmailDraft = nil
                createSelectionEmailDraft(d)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.purple.opacity(0.25)))
    }

    /// Builds the draft in Mail (so the selected files can ride along as attachments) and
    /// reports the real outcome — an AppleScript failure is shown, never swallowed.
    func createSelectionEmailDraft(_ draft: PendingSelectionEmail) {
        let attachments = aiMode.selectionFiles.map(\.path)
        func escaped(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        // An AppleScript string literal cannot contain a raw newline, and a summary is full of
        // them — without this the whole draft fails to compile.
        func escapedBody(_ value: String) -> String {
            escaped(value)
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\n", with: "\" & return & \"")
        }
        var script = """
            tell application "Mail"
                set newMessage to make new outgoing message with properties \
                    {subject:"\(escaped(draft.subject))", content:"\(escapedBody(draft.body))", \
                     visible:true}
                tell newMessage
                    make new to recipient at end of to recipients with properties \
                        {address:"\(escaped(draft.to))"}
            """
        for path in attachments {
            script += """

                    tell content
                        make new attachment with properties \
                            {file name:(POSIX file "\(escaped(path))" as alias)} \
                            at after the last paragraph
                    end tell
            """
        }
        script += """

                end tell
                activate
            end tell
            """

        let outcome = runProposalAppleScript(script)
        let message: AIChatMessage
        if outcome.ok {
            let extra = attachments.isEmpty
                ? ""
                : " with \(attachments.count) attachment\(attachments.count == 1 ? "" : "s")"
            message = AIChatMessage(
                role: .assistant,
                content: "✉️ Draft to **\(draft.to)** opened in Mail\(extra). Review it and press "
                    + "Send there — DoraX does not send mail for you.")
        } else {
            message = AIChatMessage(
                role: .assistant,
                content: "⚠️ Couldn't create the Mail draft:\n\n\(outcome.message)",
                isError: true)
        }
        aiMode.messages.append(message)
        persistGeneralAIConversation()
        requestWindowSizeUpdate(reason: .chatChanged)
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
                                onEnableApp: { req in enableAppForGeneralChat(req) },
                                onPickAction: { choice in runPickedActionChoice(choice) }
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
                        if let pendingCapabilityApproval {
                            InlineCapabilityApprovalCard(pending: pendingCapabilityApproval)
                                .id("capability-approval")
                        }
                        if let pendingAdapterApproval {
                            InlineAdapterApprovalCard(request: pendingAdapterApproval)
                                .id("adapter-approval")
                        }
                        if !aiMode.isLoading, !aiMode.messages.isEmpty,
                            let followUp = ChatFollowUp.suggestion(for: dockChatScope)
                        {
                            // One earned next step, offered where the answer is. Same rule
                            // as the window: nothing while an answer is arriving, and
                            // nothing at all unless the last action earned it.
                            HStack {
                                Button {
                                    searchState.query = followUp.prompt
                                    submitAIQuery()
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "arrow.turn.down.right")
                                            .font(.system(size: 9, weight: .semibold))
                                        Text(followUp.title)
                                            .font(.system(size: 11.5, weight: .medium))
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                                    .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain)
                                Spacer(minLength: 0)
                            }
                            .id("follow-up")
                        }
                        if let pending = aiMode.pendingShare {
                            selectionShareConfirmCard(pending)
                                .id("pending-share")
                        }
                        if let draft = aiMode.pendingEmailDraft {
                            selectionEmailDraftCard(draft)
                                .id("pending-email-draft")
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
            withAnimation(.dockStandard) {
                switchDockWorkspace(
                    to: chatFocusApps + [.init(name: req.name, bundleId: req.bundleId)])
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

        // An answer in flight blocks the next question — but only while it is plausibly
        // still coming. A request that stalled leaves isLoading true for the rest of the
        // session, and every Return after it is discarded without a word, which reads as a
        // dead app rather than a busy one.
        if aiMode.isLoading || aiMode.streamingId != nil {
            let startedAt = aiMode.loadingStartedAt ?? .distantPast
            guard Date().timeIntervalSince(startedAt) > 90 else { return }
            aiMode.messages.append(
                AIChatMessage(
                    role: .assistant,
                    content: "That took too long and was dropped. Asking again.",
                    isError: true))
            aiMode.isLoading = false
            aiMode.streamingId = nil
            aiMode.loadingStatus = nil
        }

        print(
            "🤖 [AI] Submitting query: \"\(query.prefix(60))\" | provider: \(settings.selectedAIProvider.shortName)"
        )

        hasUserSentMessageInCurrentSession = true

        let pendingAttachments = mergedAIRequestAttachments(
            explicitAttachments: aiMode.attachments
        )

        withAnimation {
            aiMode.messages.append(
                // Display the selection's files as chips on the FIRST turn only. They are still
                // sent to the provider on every turn (below), but repeating the chip on each
                // message made a two-line chat look like the user re-attached the file each time
                // — and the selection pill in the header already says what is attached.
                AIChatMessage(
                    role: .user, content: query,
                    attachments: aiMode.messages.count <= 1
                        ? pendingAttachments : aiMode.attachments))
        }
        persistGeneralAIConversation()
        searchState.query = ""

        aiMode.attachments = []

        aiMode.isLoading = true
        let turnStartedAt = Date()
        aiMode.loadingStartedAt = turnStartedAt

        // End the turn if nothing comes back. The hub is bounded and the provider call is
        // not, so a stalled request left "Working…" on screen with no answer, no error and
        // no way to tell a slow turn from a dead one — and because a turn in flight blocks
        // the next question, the surface stopped accepting input entirely.
        //
        // Identified by its start time: a later turn replaces it, and this one then finds a
        // timestamp that is not its own and leaves the newer request alone.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard aiMode.isLoading, aiMode.loadingStartedAt == turnStartedAt else { return }
            aiMode.isLoading = false
            aiMode.streamingId = nil
            aiMode.loadingStatus = nil
            aiMode.messages.append(
                AIChatMessage(
                    role: .assistant,
                    content: "No answer came back after two minutes, so I stopped waiting. "
                        + "Ask again, or try a narrower question.",
                    isError: true))
            persistGeneralAIConversation()
        }
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
                let recentFiles = await MainActor.run {
                    self.generalAIRecentFileActions(for: query)
                }
                await MainActor.run {
                    let enableReq = self.aiMode.pendingEnableApp
                    self.aiMode.pendingEnableApp = nil
                    let choices = self.aiMode.pendingActionChoices
                    self.aiMode.pendingActionChoices = []
                    withAnimation {
                        // Auto-create: if the AI proposed a runnable extension (no route fit),
                        // tag the message so it shows Run once / Save buttons instead of just
                        // describing a script.
                        let baseMsg = AIChatMessage(
                            role: .assistant, content: cleaned, appLaunches: launches,
                            recentFiles: recentFiles,
                            mcpToolsRan: self.aiMode.pendingToolChips,
                            evidenceReceipts: self.aiMode.pendingEvidenceReceipts,
                            subjectiveEvaluation: self.aiMode.pendingSubjectiveEvaluation,
                            enableAppRequest: enableReq,
                            trace: self.aiMode.routerTrace,
                            actionChoices: choices)
                        self.aiMode.messages.append(self.tagMessageWithProposal(baseMsg))
                        self.aiMode.pendingToolChips = []
                        self.aiMode.pendingEvidenceReceipts = []
                        self.aiMode.pendingSubjectiveEvaluation = nil
                        self.aiMode.routerTrace = []
                        self.aiMode.loadingStatus = nil
                        self.aiMode.isLoading = false
                    }
                    self.persistGeneralAIConversation()
                    // Anything the answer built becomes a file the window can already show.
                    // Unlike the dock path, nothing opens on its own here — the composer
                    // grows a button and the user decides.
                    if let artifact = ArtifactStore.extract(
                        from: cleaned, scope: .general
                    ).last {
                        self.generalChatArtifact = artifact
                    }
                    // Two-step: don't send yet — show a confirm card so the user approves the
                    // destination first.
                    if let shareInvocation,
                        let shareDest = shareInvocation.arguments["destination"]
                    {
                        self.aiMode.pendingShare = PendingSelectionShare(
                            text: cleaned, destination: shareDest)
                    }
                    // Second half of a "produce this, then mail it" request: the content now
                    // exists, so offer it as a draft. Still a click away from being sent.
                    if var draft = self.selectionRouterPendingEmail {
                        self.selectionRouterPendingEmail = nil
                        draft.body = cleaned
                        self.aiMode.pendingEmailDraft = draft
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
        ChatAnswerSanitizer.clean(text)
    }

    /// The workspace the dock's general chat is currently in.
    ///
    /// Two or more apps is a combined chat, and a combined chat is a conversation of its
    /// own — the same one the window opens for that membership. Keyed identically, so the
    /// dock and the window are two views of one workspace rather than two chats that happen
    /// to have the same apps attached.
    var dockChatScope: GeneralChatScope {
        let names = chatFocusApps.map(\.name)
        guard names.count > 1 else { return .general }
        return .thread(id: GeneralChatWindowModel.combinedThreadID(for: names))
    }

    func restoreGeneralAIConversationIfNeeded() {
        guard aiMode.messages.isEmpty else { return }
        let restored = GeneralChatSessionStore.load(scope: dockChatScope)
        guard !restored.isEmpty else { return }
        aiMode.messages = restored
        hasUserSentMessageInCurrentSession = true
        requestWindowSizeUpdate(reason: .chatChanged)
    }

    func persistGeneralAIConversation() {
        let scope = dockChatScope
        GeneralChatSessionStore.save(
            aiMode.messages, scope: scope, title: dockWorkspaceTitle)
        if case .thread = scope {
            GeneralChatSessionStore.saveAttachedApps(chatFocusApps.map(\.name), scope: scope)
        }
    }

    func clearGeneralAIConversation() {
        GeneralChatSessionStore.save(
            [], scope: dockChatScope, title: dockWorkspaceTitle)
    }

    private var dockWorkspaceTitle: String {
        let names = chatFocusApps.map(\.name)
        return names.count > 1 ? names.joined(separator: " + ") : "General"
    }

    /// Moves the dock's general chat to the workspace for this membership.
    ///
    /// Changing which apps a chat is about changes which conversation it is. Keeping the
    /// transcript across the move would carry Safari's answers into the Safari + Notes
    /// workspace, where they were never asked.
    func switchDockWorkspace(to apps: [GeneralChatFocusApp]) {
        persistGeneralAIConversation()
        chatFocusApps = apps
        aiMode.messages = GeneralChatSessionStore.load(scope: dockChatScope)
        hasUserSentMessageInCurrentSession = !aiMode.messages.isEmpty
        requestWindowSizeUpdate(reason: .chatChanged)
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

    func appPanelCLIDocumentation(for package: TerminalPackage, query: String = "") -> String {
        var doc = "### \(package.command) [CLI]"
        if let path = package.installedPath, !path.isEmpty {
            doc += " at \(path)"
        }
        if let helpText = package.helpText, !helpText.isEmpty {
            // Relevance-fitted and cut on a line boundary — a prefix cut here left flags
            // half-written, which the model then treats as real flags.
            doc += "\n" + AIContextBudget.fitHelpText(helpText, query: query, budget: 1_000)
        } else if !package.description.isEmpty {
            doc += "\n" + package.description
        } else {
            doc +=
                "\nUNKNOWN: Call run_command(\"\(package.command) --help\") first, read output, then answer."
        }
        if !package.usageExamples.isEmpty {
            doc += "\nExamples: " + package.usageExamples.prefix(4).joined(separator: " | ")
        }
        // Invocations that actually ran here and exited zero. Documentation describes what a
        // tool can do; these are known to work against the installed version, so they settle
        // the flag spellings and argument order help text leaves ambiguous.
        if !package.provenInvocations.isEmpty {
            doc += "\nKnown-good invocations on this Mac (prefer these spellings):\n"
            doc += package.provenInvocations.prefix(5)
                .map { "  \($0)" }
                .joined(separator: "\n")
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

    /// Words the help parser mistakes for subcommands when a description wraps onto its own
    /// line. Listing "pear the" as a runnable subcommand invites the model to try it.
    static let helpNoiseTokens: Set<String> = [
        "the", "to", "a", "an", "and", "or", "for", "with", "at", "in", "of", "on", "by",
        "from", "specified", "available", "all", "only", "add", "them",
    ]

    func dockScopedCLIDocumentation(for package: TerminalPackage, query: String = "") -> String {
        var doc = "### \(package.command) [CLI]"
        if let path = package.installedPath, !path.isEmpty {
            doc += " at \(path)"
        }
        // The subcommand list is the tool's table of contents, and it goes in whether or not
        // help text follows. It used to be an `else` branch: with help text present it was
        // never sent, and the help itself is budget-clipped by relevance to the query — so
        // "clean cache" against pear scored no section containing "clean" or "cache",
        // dropped remove-orphaned and list-orphaned from a 1k slice of 30k, and the model
        // answered, accurately, that the provided help mentioned no way to clean a cache.
        // Nine short tokens are worth far more here than nine hundred characters of prose.
        let subcommands = package.subcommands.filter { !Self.helpNoiseTokens.contains($0.lowercased()) }
        if !subcommands.isEmpty {
            doc += "\nSubcommands (always include a space between command and subcommand):\n"
            doc += subcommands.map { "  \(package.command) \($0)" }.joined(separator: "\n")
        }
        // A short help block usually means the tool documents itself in man instead — `find`
        // prints a usage stub and reserves everything real for its man page. Preferring the
        // longer of the two picks whichever the author actually wrote.
        let help = package.helpText ?? ""
        let man = package.manText ?? ""
        let reference = man.count > help.count * 2 ? man : help
        if !reference.isEmpty {
            doc += "\n" + AIContextBudget.fitHelpText(reference, query: query, budget: 1_000)
        } else if !subcommands.isEmpty {
            if !package.description.isEmpty { doc += "\n" + package.description }
        } else if !package.description.isEmpty {
            doc += "\n" + package.description
        } else {
            doc += "\nIf syntax is unclear, inspect `\(package.command) --help` before acting."
        }
        if !package.usageExamples.isEmpty {
            doc += "\nExamples: " + package.usageExamples.prefix(4).joined(separator: " | ")
        }
        // Invocations that ran here and exited zero. These settle the flag spellings and
        // argument order that documentation leaves ambiguous, against the version installed
        // rather than the one the docs were written for.
        if !package.provenInvocations.isEmpty {
            doc += "\nKnown-good invocations on this Mac (prefer these spellings):\n"
            doc += package.provenInvocations.prefix(5)
                .map { "  \($0)" }
                .joined(separator: "\n")
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

        // The scope's own tool, first. A cli:// scope IS a tool, but documentation was only
        // collected from packages linked to the scope via contextAppBundleIds and from
        // adapter actions attached to it. A globally pinned tool has neither, so scoping
        // "mole" produced an empty block — and the model, given a scope named mole and no
        // facts about it, answered about a different tool entirely. mole's own package
        // already held 30k of help text and 11 subcommands.
        if let scopeOwnCommand = cliScopeToolCommand(for: scopedBundleId) {
            appendCommand(scopeOwnCommand)
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
        // The shape only — never a runnable example. A literal sample command here was
        // copied verbatim by weaker models, so an unrelated tool's command surfaced as an
        // approval card in a scope that never linked it.
        lines.append(
            "IMPORTANT: When the request warrants a CLI command, output one exact JSON line: {\"terminal_call\":{\"command\":\"<the exact command, built from the tools listed above>\",\"purpose\":\"<why it is being run>\"}}. Never place executable requests in prose or code fences, and never emit a command for a tool that is not listed above."
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

    /// What the app itself documents: its homepage, docs, repository and changelog, plus the
    /// current text of whichever one the question is about. Without this a scope answered
    /// version-specific questions from whatever the model remembered, which goes stale the
    /// moment the app ships a release.
    func appReferenceContextPrompt(
        bundleId: String, appName: String, query: String
    ) async -> String {
        guard !bundleId.isEmpty else { return "" }
        let references = await AppReferenceIndex.shared.references(
            bundleId: bundleId, appName: appName)
        guard !references.isEmpty else { return "" }

        var lines = ["## \(appName) references"]
        lines.append(contentsOf: references.map { "- \($0.kind.label): \($0.title) — \($0.url)" })

        // Reading a page costs a network round trip, so only a question that is actually
        // about the product pays for it — and only for the one page it names.
        if AppReferenceIndex.looksLikeReferenceQuestion(query),
            let best = AppReferenceIndex.bestReference(for: query, in: references)
                ?? references.first(where: { $0.kind == .documentation }),
            let snapshot = await AppReferenceIndex.shared.pageSnapshot(
                for: best, bundleId: bundleId, query: query, limit: 4_000)
        {
            lines.append("")
            lines.append("### Current content of \(best.title) (\(best.url))")
            lines.append(snapshot.text)
            lines.append("")
            let age = RelativeDateTimeFormatter().localizedString(
                for: snapshot.syncedAt, relativeTo: Date())
            lines.append("Reference freshness: synced \(age) via \(snapshot.converter).")
            lines.append(
                "Prefer this cached official text over recalled knowledge, and cite "
                + "the link when the answer comes from it.")
        }
        return lines.joined(separator: "\n")
    }

    /// Live state of the workspace this scope is working in — the project, its branch and
    /// changes, the agents running in it. Replaces a keyword-gated `code --status` dump:
    /// a co-worker knows the state of the work before being asked about it.
    func appWorkspaceContextPrompt(
        bundleId: String, appName: String, forceRefresh: Bool = false
    ) async -> String {
        guard !bundleId.isEmpty else { return "" }
        // The window title of the app being asked about. Reading the shared snapshot only
        // when it already belongs to that app meant a workspace could never be resolved for
        // any app that was not frontmost — which is exactly the case in General Chat, where
        // the launcher is in front.
        let windowTitle = await MainActor.run {
            ContextResolver.axContext(for: bundleId, appName: appName).windowTitle
        }
        let finderFolder = bundleId == "com.apple.finder"
            ? AppleAppsAPI.shared.getCurrentFolder() : nil
        let identity = AppWorkspaceService.identity(
            bundleId: bundleId,
            appName: appName,
            windowTitle: windowTitle,
            finderFolder: finderFolder
        )
        let linkedCLIs = await MainActor.run { self.scopeRunnableCommandBinaries() }
        return await AppWorkspaceService.shared.contextBlock(
            for: identity, linkedCLIs: linkedCLIs, forceRefresh: forceRefresh)
    }

    /// Decodes typed `terminal_call` JSON lines, strips them from the displayed message,
    /// and appends inline approval cards that run in the scoped dock terminal.
    @MainActor
    /// Value of a `[KEY: value]` directive line, unquoted. Returns nil when the line is not
    /// that directive, so ordinary prose mentioning the key in passing is left alone.
    static func bracketDirectiveValue(_ line: String, key: String) -> String? {
        guard line.hasPrefix("[\(key):"), line.hasSuffix("]") else { return nil }
        let value = line
            .dropFirst(key.count + 2)
            .dropLast()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        return value.isEmpty ? nil : value
    }

    func extractAndInsertDockApprovalCards(
        from response: String,
        intoMessageAt msgId: UUID
    ) {
        var cleanedLines: [String] = []
        var extractedCmds: [(command: String, purpose: String)] = []
        var lastNonCmdLine = ""

        // A directive carried over two lines: the purpose usually follows the command.
        var pendingBracketPurpose: String?

        for line in response.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let invocation = AITypedInvocationResolver.terminalInvocation(from: trimmed),
                let command = invocation.arguments["command"]
            {
                extractedCmds.append((
                    command,
                    invocation.arguments["purpose"] ?? lastNonCmdLine
                ))
            } else if let purpose = Self.bracketDirectiveValue(trimmed, key: "COMMAND_PURPOSE") {
                // Attach to the command directly above, which is the order the prompt asks for.
                if !extractedCmds.isEmpty {
                    extractedCmds[extractedCmds.count - 1].purpose = purpose
                } else {
                    pendingBracketPurpose = purpose
                }
            } else if let command = Self.bracketDirectiveValue(trimmed, key: "TERMINAL_COMMAND") {
                // The format AITerminalPrompts documents: [TERMINAL_COMMAND: <command>].
                // Only typed invocations were recognised here, so a model that followed the
                // documented instruction had its directive rendered to the user as prose.
                // Apple Intelligence follows it most literally, which is why it showed there
                // first — the models that ignored the convention were accidentally exempt.
                extractedCmds.append((command, pendingBracketPurpose ?? lastNonCmdLine))
                pendingBracketPurpose = nil
            } else {
                cleanedLines.append(line)
                if !trimmed.isEmpty { lastNonCmdLine = trimmed }
            }
        }

        // A scope may only offer to run tools it actually links. Prompt text is not a
        // contract — a weaker model can echo an example command or invent a tool it read
        // about — so the card itself is gated here, where the scope is known.
        extractedCmds = extractedCmds.filter { commandIsRunnableInCurrentScope($0.command) }

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
            withAnimation(.dockStandard) {
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
        handOffArtifactIfProduced()
    }

    /// An answer that built something moves to the window, carrying the conversation.
    ///
    /// The dock is a strip. An artifact is a chart, a table, a diagram — a thing to look at
    /// — and a strip can only show its source, which is the problem artifacts exist to
    /// solve. Rather than render it badly here, the surface that can show it properly is
    /// opened, with the transcript, so the user is not moved away from their conversation
    /// to look at what their conversation produced.
    ///
    /// Every choke point runs through here, so this fires once per turn regardless of which
    /// path answered.
    /// Moves to the window when the answer produced something to *look at*.
    ///
    /// The dock is a strip: it reads a paragraph well and shows a document, a rendered
    /// artifact, a live terminal or a six-step run badly. Those all have somewhere proper to
    /// be — the window's Preview panel, its Artifacts tab, its terminal, its console — and
    /// leaving the user in the strip means the work is finished somewhere they cannot see
    /// it, and they have to know to go looking.
    ///
    /// A long *text* answer is deliberately not a trigger. Prose reads fine in the dock,
    /// and expanding for it would make the window appear on almost every question, which is
    /// the app taking over the screen rather than helping.
    private func handOffArtifactIfProduced() {
        guard let last = l2.chatMessages.last, last.role == .assistant else { return }
        let scopeInfo = currentContextDockChatScope
        let scope: GeneralChatScope = scopeInfo.bundleId.isEmpty
            ? .general : .app(bundleId: scopeInfo.bundleId)

        // A rendered thing, then a file it produced: both belong in Preview, and the
        // handoff carries the file so the window opens on it rather than near it.
        if let artifact = ArtifactStore.extract(from: last.content, scope: scope).last {
            previewFileInChatWindow(
                artifact, bundleId: scopeInfo.bundleId, appName: scopeInfo.appName)
            return
        }
        if let file = last.recentFiles.first?.url,
            FileManager.default.fileExists(atPath: file.path)
        {
            previewFileInChatWindow(
                file, bundleId: scopeInfo.bundleId, appName: scopeInfo.appName)
            return
        }

        // A run worth watching rather than reading: several steps, or a tool drawing its
        // own screen. Three is the point where the receipt stops fitting the strip —
        // one or two steps are legible where they happened.
        let manySteps = last.trace.count >= 3
        let hasTerminal = ChatThreadTerminalManager.shared.hasTerminal(for: scope)
        guard manySteps || hasTerminal else { return }

        GeneralChatWindowModel.shared.openSession(
            scope, title: scopeInfo.appName.isEmpty ? "General" : scopeInfo.appName,
            seed: l2.chatMessages)
        handOffChatToWindow()
        GeneralChatWindowController.shared.show()
    }

    @MainActor
    func setL2LoadingStatus(_ status: String?, requestID: UUID) {
        guard l2.activeRequestID == requestID, l2.isLoading else { return }
        l2.loadingStatus = status
    }

    /// The CLI tool a `cli://` scope is bound to, or nil outside such a scope.
    /// The bundle ID whose scope a linked CLI belongs to right now — the chat's own app,
    /// else the active app scope. Empty in Global Chat, where links are not scoped.
    func currentScopeBundleIDForToolTrust() -> String {
        let chatBundle = l2.chatDraftBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !chatBundle.isEmpty { return chatBundle }
        return currentGlobalScopedBundleID ?? ""
    }

    /// Linked CLIs worth spending prompt space on for this turn: everything trusted (seeded,
    /// catalog-matched, or already used here), plus any provisional guess the question names.
    /// A guessed link stays usable — it just stops taxing every unrelated turn.
    func promptRelevantCLIPackages(
        _ packages: [TerminalPackage], bundleId: String, query: String
    ) -> [TerminalPackage] {
        ScopedAppPromptBuilder.promptRelevantCLIPackages(
            packages, bundleId: bundleId, query: query)
    }

    /// Binaries the CURRENT scope is allowed to propose. Built from the same inventory the
    /// system prompt advertises: the CLI-tool scope's own binary, the scoped app's linked
    /// packages, and its adapter's CLI actions. Empty in Global Chat, where every enabled
    /// package is fair game.
    func scopeRunnableCommandBinaries() -> Set<String> {
        let scopedBundleId =
            l2.chatDraftBundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (currentGlobalScopedBundleID ?? "")
            : l2.chatDraftBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scopedBundleId.isEmpty else { return [] }

        var allowed: Set<String> = []
        if let own = cliScopeToolCommand(for: scopedBundleId) {
            allowed.insert(own.lowercased())
        }
        for package in TerminalPackageManager.shared.packages
        where package.isEnabled && package.contextAppBundleIds.contains(scopedBundleId) {
            allowed.insert(package.command.lowercased())
        }
        if let adapter = adapterManager.adapters.first(where: { $0.bundleId == scopedBundleId }) {
            for action in adapter.actions where action.type == .cliTool {
                let command = (action.cliToolCommand ?? "")
                    .split(separator: " ").first.map(String.init) ?? ""
                if !command.isEmpty { allowed.insert(command.lowercased()) }
            }
        }
        return allowed
    }

    /// True when the scope may surface an approval card for this command.
    func commandIsRunnableInCurrentScope(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let allowed = scopeRunnableCommandBinaries()
        // Global Chat / no scope: the existing classifier and approval card own the risk.
        guard !allowed.isEmpty else { return true }

        // Read the first real binary, skipping env assignments and an absolute path.
        var binary = ""
        for token in trimmed.split(separator: " ").map(String.init) {
            if token.contains("=") { continue }
            binary = token
            break
        }
        guard !binary.isEmpty else { return false }
        let leaf = (binary as NSString).lastPathComponent.lowercased()
        if allowed.contains(leaf) { return true }
        // A shell wrapper hides the real binary — allow only when the scoped tool appears
        // somewhere in the command, so `sh -c "code --status"` still works in a Code scope.
        if ["sh", "bash", "zsh", "env", "sudo"].contains(leaf) {
            let lowered = trimmed.lowercased()
            return allowed.contains { lowered.contains($0) }
        }
        #if DEBUG
        print("🚫 [DockChat] Blocked out-of-scope command card: \(trimmed)")
        #endif
        return false
    }

    func cliScopeToolCommand(for bundleID: String) -> String? {
        ScopedAppPromptBuilder.cliCommand(forScopeBundleID: bundleID)
    }

    /// Narrates each step of a CLI tool scope from the command about to run, so the
    /// session reads like an agent working ("Reading mole --help…", "Running mole scan…")
    /// instead of one generic "Running linked CLI…" for every step. Derived from the real
    /// command string, so it can never claim work that isn't happening.
    func cliAgentStatus(for command: String, tool: String?) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortened = trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
        guard let tool, !tool.isEmpty else { return "Running \(shortened)…" }
        let lower = trimmed.lowercased()
        if lower.contains("--help") || lower.hasSuffix(" -h") || lower.hasSuffix(" help") {
            return "Reading \(tool) --help…"
        }
        if lower.contains("--version") || lower.hasSuffix(" -v") {
            return "Checking the \(tool) version…"
        }
        if lower.hasPrefix("which ") || lower.hasPrefix("command -v ") {
            return "Locating \(tool)…"
        }
        guard lower.hasPrefix(tool.lowercased()) else { return "Running \(shortened)…" }
        let rest = trimmed.dropFirst(tool.count).trimmingCharacters(in: .whitespaces)
        let subcommand = rest.split(separator: " ").first.map(String.init) ?? ""
        if subcommand.isEmpty || subcommand.hasPrefix("-") {
            return "Running \(tool)…"
        }
        return "Running \(tool) \(subcommand)…"
    }

    /// CLI scopes are an executable boundary, not a general shell.  The cloud and
    /// on-device agents both ultimately arrive at this executor, so enforce the boundary
    /// here as well as in the prompt.  This makes a stale package association unable to run
    /// a different command from inside `cli://mole`.
    func command(_ command: String, targetsScopedCLITool tool: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.split(whereSeparator: \.isWhitespace).first else { return false }
        let executable = String(first).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !executable.isEmpty else { return false }
        return executable.caseInsensitiveCompare(tool) == .orderedSame
            || URL(fileURLWithPath: executable).lastPathComponent.caseInsensitiveCompare(tool) == .orderedSame
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

    /// One step of Context Dock chat's live route trace — the same treatment Selection Scope
    /// and General Chat get. Shown beside the typing indicator now, kept on the finished
    /// answer as the "N steps" disclosure. Every line is work the app performed.
    func dockTraceStep(_ text: String) {
        l2.loadingStatus = text
        l2.routerTrace.append(text)
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
        case .linkInstalledTool(let packageID, let command, _, let provisional):
            service.link(packageID: packageID, to: gap.bundleID, provisional: provisional)
            finishCapabilityGap(
                gap,
                note: provisional
                    ? "Linked \(command) to \(gap.appName) for now — it stays only if you use it."
                    : "Linked \(command) to \(gap.appName).")

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
        withAnimation(.dockSoft) {
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
        withAnimation(.dockSoft) {
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

    /// "install this" on a GitHub repository page. Installing belongs to this Mac, not to
    /// the browser, so a browser scope used to refuse it outright ("cannot be done from a
    /// browser script") and stop there. The page URL is the repository, the local toolchain
    /// decides the route, and the user approves the command — no model involved, so the
    /// command can be offered directly.
    @discardableResult
    func tryHandleGitHubInstallRequest(_ query: String, scopedBundleId: String) -> Bool {
        let browserBundle = scopedBundleId.isEmpty ? frontmost.bundleID : scopedBundleId
        guard isContextDockBrowserBundle(browserBundle) else { return false }
        guard GitHubInstallRouter.isInstallIntent(query) else { return false }
        guard let pageURL = currentBrowserPageURL(),
            let repo = GitHubInstallRouter.repository(from: pageURL)
        else { return false }

        l2.chatMessages.append(AIChatMessage(role: .user, content: query))
        l2.isLoading = true
        l2.loadingStatus = "Checking how \(repo.name) installs…"
        let requestID = beginL2AIRequest()

        l2.currentTask = Task {
            let plan = await GitHubInstallRouter.plan(for: repo)
            await MainActor.run {
                l2.isLoading = false
                l2.chatMessages.append(
                    AIChatMessage(
                        role: .assistant,
                        content: "**\(repo.owner)/\(repo.name)**\n\n\(plan.summary)"))
                l2.chatMessages.append(
                    AIChatMessage(
                        role: .approval,
                        content: plan.command,
                        structuredData: "dock_cmd|||\(plan.purpose)"))
                finishL2AIRequest(requestID)
                requestWindowSizeUpdate(reason: .chatChanged, animated: true)
            }
        }
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
                var noteMatches: [NoteMetadata] = []
                if wantsCount && !wantsSearch {
                    // Single Apple Event — no full metadata refresh for a count question.
                    let count = try await AppleNotesMCPServer.shared.noteCount()
                    response = "There are \(count) notes."
                } else {
                    let notes = try await AppleNotesMCPServer.shared.allMetadata()
                    let searchTerm = notesSearchTerm(from: normalized)
                    noteMatches = searchTerm.isEmpty
                        ? notes
                        : try await AppleNotesMCPServer.shared.search(
                            query: searchTerm, maxResults: 8)
                    response = formatNotesSearchResponse(noteMatches, query: searchTerm)
                }
                await MainActor.run {
                    l2.isLoading = false
                    let rows = noteMatches.map {
                        NoteSearchAction(
                            id: $0.id, title: redactNotePreview($0.title),
                            folder: $0.folder, snippet: redactNotePreview($0.snippet),
                            modifiedDate: $0.modifiedDate)
                    }
                    l2.chatMessages.append(
                        AIChatMessage(
                            role: .assistant, content: response,
                            noteResults: rows,
                            mcpToolsRan: ["DoraX Notes MCP · notes.search"])
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
        return "Found \(matches.count) note\(matches.count == 1 ? "" : "s")"
            + (query.isEmpty ? "." : " matching “\(query)”.")
    }

    /// Search metadata is useful UI context but may contain credentials. Redact common
    /// token shapes before a title/snippet reaches the transcript or screenshot surface.
    private func redactNotePreview(_ text: String) -> String {
        let patterns = [
            #"\b(?:sk|ghp|github_pat|xox[baprs]|AIza)[-_A-Za-z0-9]{12,}\b"#,
            #"\b(?:api[_ -]?key|token|secret|password)\s*[:=]\s*\S+"#,
        ]
        return patterns.reduce(text) { value, pattern in
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive])
            else { return value }
            return regex.stringByReplacingMatches(
                in: value, range: NSRange(value.startIndex..., in: value),
                withTemplate: "[redacted]")
        }
    }

    func handleL2Query(_ query: String, skipMenuRouter: Bool) {
        guard !query.isEmpty else { return }
        let wasContextDockChatActive = l2.chatArmed || l2.showChatPopover || !l2.chatMessages.isEmpty
        // The launcher becomes key while the user types, so NSWorkspace/frontmost can now be
        // Context Dock itself. Capture the already-visible chat scope before changing any state;
        // that scope owns the entire turn until the user explicitly exits it.
        let lockedChatScope = currentContextDockChatScope
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
        let resolvedBundleId = dockScope.scopedBundleId.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let resolvedAppName = dockScope.scopedAppName.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let lockedBundleId = lockedChatScope.bundleId.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let lockedAppName = lockedChatScope.appName.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let shouldKeepLockedChatScope = wasContextDockChatActive
            && !lockedBundleId.isEmpty
            && lockedBundleId != Bundle.main.bundleIdentifier
        let scopedBundleId = shouldKeepLockedChatScope ? lockedBundleId : resolvedBundleId
        let scopedAppName = shouldKeepLockedChatScope ? lockedAppName : resolvedAppName
        let isExplicitScopedApp =
            dockScope.isExplicitAppScope
            && !scopedBundleId.isEmpty
            && !scopedAppName.isEmpty

        if let memoryAnswer = MarkdownMemoryStore.shared.cacheFromCommand(query) {
            l2.chatMessages.append(AIChatMessage(role: .user, content: query))
            l2.chatMessages.append(
                AIChatMessage(
                    role: .assistant,
                    content: memoryAnswer,
                    mcpToolsRan: ["Local Markdown cache"]
                )
            )
            l2.isLoading = false
            requestWindowSizeUpdate(reason: .chatChanged)
            return
        }
        if let memoryAnswer = MarkdownMemoryStore.shared.replaceFromCommand(
            query,
            appBundleID: scopedBundleId.isEmpty ? frontmost.bundleID : scopedBundleId
        ) {
            l2.chatMessages.append(AIChatMessage(role: .user, content: query))
            l2.chatMessages.append(
                AIChatMessage(
                    role: .assistant,
                    content: memoryAnswer,
                    mcpToolsRan: ["Local Markdown memory"]
                )
            )
            l2.isLoading = false
            requestWindowSizeUpdate(reason: .chatChanged)
            return
        }
        if let memoryAnswer = MarkdownMemoryStore.shared.forgetFromCommand(
            query,
            appBundleID: scopedBundleId.isEmpty ? frontmost.bundleID : scopedBundleId
        ) {
            l2.chatMessages.append(AIChatMessage(role: .user, content: query))
            l2.chatMessages.append(
                AIChatMessage(
                    role: .assistant,
                    content: memoryAnswer,
                    mcpToolsRan: ["Local Markdown memory"]
                )
            )
            l2.isLoading = false
            requestWindowSizeUpdate(reason: .chatChanged)
            return
        }
        if let memoryAnswer = MarkdownMemoryStore.shared.remember(
            query,
            appBundleID: scopedBundleId.isEmpty ? frontmost.bundleID : scopedBundleId,
            appName: scopedAppName.isEmpty ? frontmost.name : scopedAppName
        ) {
            l2.chatMessages.append(AIChatMessage(role: .user, content: query))
            l2.chatMessages.append(AIChatMessage(role: .assistant, content: memoryAnswer))
            l2.isLoading = false
            requestWindowSizeUpdate(reason: .chatChanged)
            return
        }
        if let memoryURL = MarkdownMemoryStore.shared.requestedMemoryURL(from: query) {
            NSWorkspace.shared.open(memoryURL)
            l2.chatMessages.append(AIChatMessage(role: .user, content: query))
            l2.chatMessages.append(
                AIChatMessage(
                    role: .assistant,
                    content: "Opened \(memoryURL.lastPathComponent) from local Markdown memory.",
                    mcpToolsRan: ["Local Markdown memory"]
                )
            )
            l2.isLoading = false
            requestWindowSizeUpdate(reason: .chatChanged)
            return
        }
        if let memoryAnswer = MarkdownMemoryStore.shared.recallAnswer(
            for: query,
            appBundleID: scopedBundleId.isEmpty ? frontmost.bundleID : scopedBundleId
        ) {
            l2.chatMessages.append(AIChatMessage(role: .user, content: query))
            l2.chatMessages.append(
                AIChatMessage(
                    role: .assistant,
                    content: memoryAnswer,
                    mcpToolsRan: ["Local Markdown memory"]
                )
            )
            l2.isLoading = false
            requestWindowSizeUpdate(reason: .chatChanged)
            return
        }

        // Start this turn's trace, and say which app the request is being resolved against.
        l2.routerTrace = []
        if !scopedAppName.isEmpty {
            dockTraceStep("Scope: \(scopedAppName)")
        } else if !frontmost.name.isEmpty {
            dockTraceStep("Frontmost app: \(frontmost.name)")
        }

        // Capability gap: the request needs a CLI this scope cannot reach. Offer the one action
        // that closes it (link it, or install then link) instead of spending a provider call on
        // an answer that can only say "open Terminal yourself".
        let gapBundleId = scopedBundleId.isEmpty ? frontmost.bundleID : scopedBundleId
        let gapAppName = scopedAppName.isEmpty ? frontmost.name : scopedAppName
        // The gap card REPLACES the answer, so it must only fire when the model genuinely
        // could not have handled the request. That was true when it had no tools: a provider
        // call could only say "open Terminal yourself". It now has run_command,
        // find_capability and run_capability — "convert this page as png" is a screencapture
        // away — so a card that pre-empts the turn is once again a router deciding what may
        // be attempted before the request is read.
        //
        // Under model-first, offer it only when the user actually named a tool ("use yt-dlp
        // to grab this"), where linking is unambiguously what they asked for. Otherwise let
        // the model try; if it truly cannot, it says so, and that is a better answer than a
        // card for a video downloader in response to a screenshot request.
        let gapMayPreemptAnswer = !AppSettings.shared.agentModelFirstRouting
            || CapabilityGapService.shared.queryExplicitlyNamesATool(query: query)
        if gapMayPreemptAnswer,
            pendingCapabilityGap == nil,
            let gap = CapabilityGapService.shared.resolve(
                query: query, bundleID: gapBundleId, appName: gapAppName)
        {
            l2.chatMessages.append(AIChatMessage(role: .user, content: query))
            dockTraceStep("No route in this scope — offering a tool that can close the gap")
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

        if tryHandleGitHubInstallRequest(query, scopedBundleId: scopedBundleId) {
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
                await MainActor.run {
                    dockTraceStep(
                        runningApp == nil
                            ? "\(capturedTarget.appName) isn't running — reading its cached menus"
                            : "Reading \(capturedTarget.appName) menu commands…")
                }
                // A live read when the app is running; otherwise the cached snapshot this
                // branch already confirmed exists. Refusing to use that cache was a
                // contradiction: the guard above requires hasMenuSnapshot, and then the
                // request fell through to a generic AI answer because the app happened to be
                // closed. The click launches the app and verifies the path before pressing it.
                var matched: (
                    path: [String], title: String, pathString: String,
                    shortcutChar: String?, shortcutModifiers: Int, image: NSImage?
                )?
                if let app = runningApp,
                    let live = await MenuIntentRouter.shared.findMatch(query: query, app: app)
                {
                    matched = (
                        live.path, live.title, live.pathString, live.shortcutChar,
                        live.shortcutModifiers, live.image)
                } else if runningApp == nil,
                    let cached = await MenuIntentRouter.shared.findCachedMatch(
                        query: query, bundleId: capturedTarget.bundleId,
                        appName: capturedTarget.appName)
                {
                    matched = (
                        cached.path, cached.title, cached.pathString, cached.shortcutChar,
                        cached.shortcutModifiers, cached.image)
                }
                if let matchedItem = matched {
                    await MainActor.run {
                        l2.isLoading = false
                        dockTraceStep(
                            runningApp == nil
                                ? "Best path: \(matchedItem.pathString) · cached menu, will launch \(capturedTarget.appName)"
                                : "Best path: \(matchedItem.pathString) · menu command")
                        // pid 0 means "launch first" — the execution path resolves the real
                        // process from the bundle id before clicking.
                        let pid = runningApp?.processIdentifier ?? 0
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
                    let (success, output, _) = await TerminalCommandExecutor.shared.run(
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

        // ── Page actions (last routing step before a plain answer) ────────────
        // Nothing above matched, and every route above matches something that already
        // exists. A page request ("dark mode for this page", "hide the sidebar") has no
        // menu item or adapter action anywhere — the capability belongs to the page — so
        // in a browser scope write the userscript instead of explaining how to do it.
        if !isSafariPageUnderstandingReadQuery(query, bundleID: scopedBundleId),
            !isSafariPageLinkOpenQuery(query, bundleID: scopedBundleId),
            tryAuthorBrowserPageAction(
            query: query, scopedBundleId: scopedBundleId, scopedAppName: scopedAppName)
        {
            finishL2AIRequest(l2RequestID)
            return
        }

        // Attachments belong to this submitted turn. Move them out of the composer immediately
        // so a later turn cannot accidentally resend the same capture.
        let submittedContextDockFiles = contextDockChatFiles
        let submittedContextDockText = contextDockChatCapturedText
        contextDockChatFiles = []
        contextDockChatCapturedText = nil
        // Every path from here either reaches the prompt, where the attachment is read, or
        // returns early. Recording what this turn carried lets the early paths say so
        // instead of dropping a file the user watched attach.
        pendingAttachmentTurn = !submittedContextDockFiles.isEmpty || submittedContextDockText != nil

        // Display only the user's actual query in the chat UI (not the full context prompt),
        // with the transferred files visible on that message as proof of what was sent.
        let userMessage = AIChatMessage(
            role: .user,
            content: query,
            attachments: submittedContextDockFiles
        )
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
            l2.chatMessages.append(
                AIChatMessage(
                    role: .assistant,
                    content: pendingAttachmentTurn
                        ? guide + "\n\nYour attachment wasn't read — nothing was sent."
                        : guide,
                    isError: true))
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

                // "test it" is about the user's project, not about the scoped app's
                // capabilities, so it is recognised before the tool loop gets a chance to
                // improvise. Left to that loop, "test it" became `npm test` in the home
                // directory — a project that has no package.json, run somewhere that is not
                // even a repository, reported back as a testing failure.
                //
                // In the dock exactly as in the window: these are two send paths, and the
                // last thing wired to only one of them had to be fixed the same way.
                if let intent = WorkbenchIntent.intent(in: query) {
                    await self.setL2LoadingStatus("Working…", requestID: l2RequestID)
                    let scopeBundle = self.currentContextDockChatScope.bundleId
                    let scope = GeneralChatScope.app(
                        bundleId: scopeBundle.isEmpty ? frontmost.bundleID : scopeBundle)
                    let outcome = await WorkbenchIntent.handle(intent, scope: scope)
                    await MainActor.run {
                        l2.chatMessages.append(
                            AIChatMessage(
                                role: .assistant,
                                content: outcome.text,
                                mcpToolsRan: outcome.chips))
                        finishL2AIRequest(l2RequestID)
                    }
                    return
                }

                // A question aimed at Claude Code runs Claude Code, in the dock exactly as
                // in the window. The dock and the window are two send paths, and wiring
                // only the window meant "ask claude what this screenshot shows" fell
                // through to the ordinary tool loop — which cannot see an image, so it
                // web-searched the question instead, opened Safari to do it, and left the
                // user reading Google results in a chat scoped to their editor.
                if ClaudeCodeBridge.shouldHandle(query) {
                    await self.setL2LoadingStatus("Asking Claude Code…", requestID: l2RequestID)
                    // The chat's own scope, not the frontmost app — the two differ
                    // whenever the user is typing into a chat about something other than
                    // the window in front of them, which is most of the time.
                    let scopeBundle = self.currentContextDockChatScope.bundleId
                    let scope = GeneralChatScope.app(
                        bundleId: scopeBundle.isEmpty ? frontmost.bundleID : scopeBundle)
                    let result = await ClaudeCodeBridge.shared.ask(
                        query: query, scope: scope, attachments: submittedContextDockFiles,
                        onProgress: { activity in
                            Task { @MainActor in
                                self.setL2LoadingStatus(activity, requestID: l2RequestID)
                            }
                        })
                    await MainActor.run {
                        l2.chatMessages.append(
                            AIChatMessage(
                                role: .assistant,
                                content: result.text,
                                isError: !result.success,
                                mcpToolsRan: result.toolsRan.map { "\($0) via Claude Code" },
                                runOutput: result.transcript.isEmpty ? nil : result.transcript))
                        finishL2AIRequest(l2RequestID)
                    }
                    return
                }

                // Browser-library reads must win before page scripts and menu actions. A
                // page-world adapter can inspect one document, but it can never enumerate
                // Safari's browser chrome or other tabs.
                let historyBundle = scopedBundleId.isEmpty
                    ? frontmost.bundleID : scopedBundleId
                // A turn carrying an attachment is a question about that attachment. These
                // routes answer from other sources and never see the file, so letting one
                // win means the user watched a file attach and then be ignored — and it was
                // already cleared from the composer, so it was gone.
                if submittedContextDockFiles.isEmpty,
                    submittedContextDockText == nil,
                    self.isContextDockBrowserBundle(historyBundle),
                    self.isBrowserHistoryReadQuery(query)
                {
                    await self.setL2LoadingStatus(
                        "Reading live browser data…", requestID: l2RequestID)
                    if let historyAnswer = await self.localBrowserHistoryAnswer(
                        query: query,
                        scopedBundleId: historyBundle,
                        requireAppAdapter: false)
                    {
                        await MainActor.run {
                            let browserTabs = self.structuredSafariTabs(
                                for: query, bundleID: historyBundle)
                            l2.chatMessages.append(
                                AIChatMessage(
                                    role: .assistant,
                                    content: browserTabs.isEmpty ? historyAnswer : "",
                                    browserTabs: browserTabs,
                                    mcpToolsRan: browserTabs.isEmpty
                                        ? ["Local browser history"] : []))
                            finishL2AIRequest(l2RequestID)
                        }
                        return
                    }
                }

                // Explicit navigation must be grounded in the current document. Never turn
                // "open the GitHub guide" into a generated web search when the page already
                // contains the destination URL.
                if self.isSafariPageLinkOpenQuery(query, bundleID: historyBundle) {
                    var pageLinks = await MainActor.run(body: {
                        self.structuredSafariPageLinks() ?? []
                    })
                    var source = "Context Dock Safari Extension"
                    if pageLinks.isEmpty {
                        pageLinks = await self.readCurrentSafariPageLinksDirectly()
                        if !pageLinks.isEmpty { source = "Safari current page" }
                    }
                    let matches = self.rankedSafariPageLinks(pageLinks, for: query)
                    await MainActor.run {
                        if let best = matches.first {
                            SafariTabManager.shared.openURL(best.url)
                            l2.chatMessages.append(
                                AIChatMessage(
                                    role: .assistant,
                                    content: "Opened \(best.title) from the current page.",
                                    pageLinks: [best],
                                    trace: [
                                        "Read current page links from \(source)",
                                        "Matched the request to \(best.domain)",
                                        "Opened the exact page link",
                                    ]))
                        } else {
                            l2.chatMessages.append(
                                AIChatMessage(
                                    role: .assistant,
                                    content: pageLinks.isEmpty
                                        ? "Safari did not return current-page links through either the direct reader or the enabled extension bridge. Click Context Dock’s Safari toolbar button once on this page to restart the extension worker, then retry."
                                        : "I couldn’t identify that destination confidently. Here are the links from this page—choose the one you meant.",
                                    pageLinks: Array(pageLinks.prefix(20)),
                                    trace: ["Read current page links", "No confident destination match"]))
                        }
                        finishL2AIRequest(l2RequestID)
                    }
                    return
                }

                if submittedContextDockFiles.isEmpty, submittedContextDockText == nil,
                    self.isSafariPageLinkReadQuery(query, bundleID: historyBundle)
                {
                    var pageLinks = await MainActor.run(body: {
                        self.structuredSafariPageLinks() ?? []
                    })
                    var source = "Context Dock Safari Extension"
                    if pageLinks.isEmpty {
                        pageLinks = await self.readCurrentSafariPageLinksDirectly()
                        if !pageLinks.isEmpty { source = "Safari current page" }
                    }
                    let didReadPageLinks = !pageLinks.isEmpty
                    pageLinks = self.safariPageLinks(pageLinks, relevantTo: query)
                    await MainActor.run {
                        if pageLinks.isEmpty {
                            let bridge = SafariBrowserBridge.shared
                            let message: String
                            if didReadPageLinks {
                                message = "I read the current page, but it doesn’t contain links matching that request."
                            } else if bridge.isExtensionActive {
                                message = "Context Dock’s Safari Extension is enabled, but Safari did not deliver a current-page snapshot and both live recovery readers returned no links. Click the Context Dock toolbar button once on this page to restart Safari’s extension worker, then try again."
                            } else {
                                message = "Safari has not delivered any Context Dock page snapshot yet. Open the Context Dock toolbar button on this page once; that establishes the local page bridge and retries the read without sending page data anywhere by itself."
                            }
                            l2.chatMessages.append(
                                AIChatMessage(
                                    role: .assistant,
                                    content: message,
                                    isError: false,
                                    trace: ["Checked Context Dock Safari Extension", "No fresh page-link payload"]
                                ))
                        } else {
                            let lower = query.lowercased()
                            let asksExistence = lower.contains("any link")
                                || lower.contains("contain") || lower.contains("has link")
                                || lower.contains("have link") || lower.contains("are there")
                            l2.chatMessages.append(
                                AIChatMessage(
                                    role: .assistant,
                                    content: asksExistence
                                        ? "Yes — this page contains \(pageLinks.count) readable link\(pageLinks.count == 1 ? "" : "s")."
                                        : "",
                                    pageLinks: pageLinks,
                                    trace: ["Read current page links from \(source)"]))
                        }
                        finishL2AIRequest(l2RequestID)
                    }
                    return
                }

                // App UI work is proposed as a visible Computer Use action. Resolution is
                // deterministic and local; the user's click is Allow Once. Only after that
                // click may DoraX launch/restore the app and live-verify the cached menu path.
                if submittedContextDockFiles.isEmpty,
                    submittedContextDockText == nil,
                    !self.isGlobalQueryModeActive,
                    !self.isSafariPageUnderstandingReadQuery(query, bundleID: historyBundle),
                    await self.offerScopedNativeAppAction(
                        query: query,
                        bundleId: scopedBundleId,
                        appName: scopedAppName.isEmpty
                            ? (frontmostName ?? frontmost.name) : scopedAppName,
                        requestID: l2RequestID)
                {
                    return
                }

                await self.setL2LoadingStatus(
                    self.cliScopeToolCommand(for: scopedBundleId).map {
                        "Loading what \($0) can do…"
                    } ?? "Checking linked actions, CLI, and MCP…",
                    requestID: l2RequestID)
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
                var browserPageBlock = await MainActor.run {
                    self.browserScopeContextBlock(scopedBundleId: scopedBundleId, query: query)
                }
                // A stale native-message bridge must not leave Safari chat reasoning over an
                // old page. Read the active DOM directly as a recovery path and give the model
                // one Markdown-shaped snapshot containing both visible text and exact hrefs.
                if self.isContextDockBrowserBundle(historyBundle),
                    !SafariBrowserBridge.shared.isFresh,
                    let directBlock = await self.readCurrentSafariPagePromptDirectly(query: query)
                {
                    browserPageBlock = directBlock
                }
                // Adapter Skills — reusable instruction bundles for this app, fed
                // as extra AI context (never executable).
                let skillsBlock = await MainActor.run {
                    SkillStore.shared.instructionsBlock(for: scopedBundleId)
                }
                // Always-present identity + tool inventory: WHICH app this chat is
                // scoped to and every integration it can use. Without this the model
                // claims it "cannot see which app is open".
                // Apple's on-device model has a small context window: the full inventory
                // (every menu path, every rule paragraph, full --help text) overran it, the
                // model produced no token at all, and the chat fell through to the 30s
                // timeout. A frontmost-app question is exactly what on-device should answer,
                // so the scope is described compactly instead of dropping to the cloud.
                let usesOnDeviceModel = provider == .onDevice
                let sourceDecision = AgentSourceAuthority.decide(query: query)
                // What the app is DOING right now — project, branch, changes, running
                // agents. Without this a scope could only describe its own tool inventory.
                let workspaceBlock = await self.appWorkspaceContextPrompt(
                    bundleId: scopedBundleId,
                    appName: scopedAppName.isEmpty
                        ? (frontmostName ?? frontmost.name) : scopedAppName,
                    forceRefresh: sourceDecision.requiresFreshRead)
                // What the vendor documents about this app, fetched fresh when the question
                // is about the product rather than the machine.
                let referenceBlock = await self.appReferenceContextPrompt(
                    bundleId: scopedBundleId,
                    appName: scopedAppName.isEmpty
                        ? (frontmostName ?? frontmost.name) : scopedAppName,
                    query: query)
                // The same resolution the window runs: window, document, selection, page and
                // capability counts as named slots, with the ones that could not be filled
                // recorded. Context Dock's whole job is knowing what "this" means, so it
                // resolves that explicitly rather than inferring it from whatever readers
                // happened to fire.
                let resolvedContextBlock = await MainActor.run { () -> String in
                    ContextResolver.resolve(
                        scope: .app(bundleId: scopedBundleId),
                        appName: scopedAppName.isEmpty
                            ? (frontmostName ?? frontmost.name) : scopedAppName
                    ).promptBlock()
                }
                let identityBlock = await MainActor.run {
                    self.scopedAppIdentityBlock(
                        bundleId: scopedBundleId,
                        appName: scopedAppName.isEmpty
                            ? (frontmostName ?? frontmost.name) : scopedAppName,
                        compact: usesOnDeviceModel
                    )
                }
                // Capture Text / screenshots / uploaded files attached via the + menu — inject
                // so the scoped agentic model actually receives what the user captured (images
                // are OCR'd since sendWithTools can't send vision). Without this the chip showed
                // but the content never reached the model.
                let attachmentBlock = contextDockChatAttachmentPromptBlock(
                    files: submittedContextDockFiles,
                    capturedText: submittedContextDockText
                )
                let memoryBlock = sourceDecision.allowsMemoryEvidence
                    ? MarkdownMemoryStore.shared.contextBlock(
                        query: query,
                        appBundleID: scopedBundleId.isEmpty ? frontmost.bundleID : scopedBundleId)
                    : ""
                var memoryToolChips: [String] = []
                if sourceDecision.requiresFreshRead, !workspaceBlock.isEmpty {
                    let lowerQuery = query.lowercased()
                    if lowerQuery.contains("commit") {
                        memoryToolChips.append("Git CLI · log -1 · just now")
                    }
                    if ["branch", "uncommitted", "working tree", "git status", "changed"]
                        .contains(where: lowerQuery.contains)
                    {
                        memoryToolChips.append("Git CLI · status · just now")
                    }
                    if memoryToolChips.isEmpty {
                        memoryToolChips.append("Live workspace reader · just now")
                    }
                }
                if sourceDecision.requiresFreshRead, !appleData.isEmpty {
                    memoryToolChips.append("Live app data · just now")
                }
                if sourceDecision.primary == .officialReference,
                    referenceBlock.contains("Current content of")
                {
                    let converter = referenceBlock.contains("via MarkItDown")
                        ? "MarkItDown" : "HTML fallback"
                    memoryToolChips.append("Official app reference · \(converter) · fresh")
                }
                if sourceDecision.allowsMemoryEvidence {
                    memoryToolChips += MarkdownMemoryStore.shared.relevantSourceChips(
                        query: query,
                        appBundleID: scopedBundleId.isEmpty ? frontmost.bundleID : scopedBundleId)
                }
                // Image captures/uploads go to the model as REAL vision (not just OCR) for
                // vision-capable cloud providers via sendWithTools(imageAttachments:).
                let scopedImageExts: Set<String> = [
                    "png", "jpg", "jpeg", "gif", "bmp", "tiff", "heic", "webp",
                ]
                let scopedImageAttachments = submittedContextDockFiles.filter {
                    scopedImageExts.contains($0.pathExtension.lowercased())
                }
                let activeContextPrompt: String = {
                    let parts = [
                        sourceDecision.promptRule, resolvedContextBlock, identityBlock,
                        workspaceBlock, referenceBlock,
                        finalContextPrompt,
                        runtimeCLIContextPrompt, appleData, mcpBlock, browserPageBlock,
                        skillsBlock, attachmentBlock, memoryBlock,
                    ]
                    guard usesOnDeviceModel else {
                        return parts
                            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                            .joined(separator: "\n\n")
                    }
                    // Ordered by what the answer actually needs: who the scope is, then the
                    // live data, then reference material. Reference is cut first.
                    let prioritised = [
                        sourceDecision.promptRule, resolvedContextBlock, identityBlock,
                        workspaceBlock, referenceBlock,
                        browserPageBlock,
                        attachmentBlock, finalContextPrompt, appleData, mcpBlock, skillsBlock,
                        memoryBlock, runtimeCLIContextPrompt,
                    ]
                    return Self.budgetedContextPrompt(prioritised)
                }()

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
                    let complexityRoute = TaskComplexityRouter.route(query)
                    await MainActor.run {
                        self.dockTraceStep("Complexity: \(complexityRoute.rawValue)")
                    }
                    // Collects MCP tools the model invokes via the tool loop, for the chip.
                    let mcpRan = MCPRunCollector()
                    // In a CLI tool scope every status names the tool and the step, so the
                    // user can follow the agent: help probe → chosen subcommand → result.
                    let cliTool = self.cliScopeToolCommand(for: scopedBundleId)
                    let commandExecutor: (String, String, Bool) async -> (Bool, String, Int32) = {
                        command, purpose, modelRequiresApproval in
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
                                return (false, "No menu path given.", -1)
                            }
                            await self.setL2LoadingStatus(
                                "Running \(path.joined(separator: " ▸ "))…", requestID: l2RequestID)
                            let (ok, out) = await AppAdapterManager.shared.runMenuPath(
                                path, targetBundleId: bundle,
                                appName: scopedAppName.isEmpty
                                    ? (frontmostName ?? frontmost.name) : scopedAppName)
                            return (ok, out.isEmpty ? "Ran \(path.joined(separator: " ▸ "))" : out, ok ? 0 : -1)
                        }
                        if let invocation = AITypedInvocationResolver.invocation(from: command),
                           invocation.kind == .adapterAction {
                            let actionId = invocation.arguments["actionId"] ?? ""
                            let bundle = (invocation.arguments["bundleId"].flatMap {
                                $0.isEmpty ? nil : $0 }) ?? scopedBundleId
                            guard let adapter = AppAdapterManager.shared.adapter(for: bundle),
                                let action = adapter.actions.first(where: { $0.id == actionId })
                            else {
                                return (false, "No adapter action '\(actionId)' is installed for this app.", -1)
                            }
                            await self.setL2LoadingStatus(
                                "Running \(action.name)…", requestID: l2RequestID)
                            let ctx = self.sanitizedAXContextForScope(
                                self.axContext, scopedBundleId: bundle)
                            let (ok, out) = await AppAdapterManager.shared.execute(
                                action, context: ctx, targetBundleId: bundle,
                                query: invocation.arguments["query"] ?? purpose)
                            return (ok, out.isEmpty ? "Ran \(action.name)" : out, ok ? 0 : -1)
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
                                return (false, error.localizedDescription, -1)
                            }
                            guard MCPToolSafety.isClearlyReadOnly(name: invocation.capabilityID) else {
                                return (
                                    false,
                                    "MCP tool \(invocation.capabilityID) is write/unknown risk and requires an approved app capability route.",
                                    -1
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
                            return (true, result, 0)
                        }
                        await self.setL2LoadingStatus(
                            cliTool == nil
                                ? "Running linked CLI…"
                                : self.cliAgentStatus(for: command, tool: cliTool),
                            requestID: l2RequestID)
                        if let cliTool, !self.command(command, targetsScopedCLITool: cliTool) {
                            return (
                                false,
                                "This chat is scoped to \(cliTool). Commands for other executables are not allowed in this scope.",
                                -1
                            )
                        }
                        // NOTE: a blanket veto used to live here. It refused run_command
                        // whenever the scoped app had ANY non-shell adapter action, and
                        // returned "use that route instead" without naming one — because it
                        // did not know one. It only knew that *something* existed.
                        //
                        // With VS Code scoped that meant ~40 auto-scraped menu items vetoed
                        // every terminal command, so "what is the recent commit I did?" was
                        // refused even though no menu item can show a git log and
                        // run_command was the only tool that could answer.
                        //
                        // Preferring native routes is good guidance and it stays in the
                        // system prompt, where the model can weigh it against the actual
                        // question. It is not a rule the executor can enforce, because the
                        // executor sees a command string and cannot know whether some other
                        // capability would have answered. Offering a tool and then refusing
                        // the model's use of it is not a safety boundary — it is a guess,
                        // and this one was wrong more often than it was right.
                        //
                        // Real boundaries remain: the CLI-scope check above, the argv gate,
                        // the classifier, and the approval sheet.
                        return await TerminalCommandExecutor.shared.run(
                            command, purpose: purpose,
                            modelRequiresApproval: modelRequiresApproval,
                            // Same thread the general chat window shows for this scope, so
                            // its console holds what the dock ran, not only what the window
                            // ran. One record of the work, two views of it.
                            consoleScope: GeneralChatScope(dockBundleId: scopedBundleId))
                    }
                    let toolQuery = activeContextPrompt.isEmpty
                        ? query
                        : "\(activeContextPrompt)\n\nUser request: \(query)"
                    await self.setL2LoadingStatus(
                        cliTool.map { "Working out the right \($0) command…" }
                            ?? "Choosing the best available capability…",
                        requestID: l2RequestID)
                    // `executed` was discarded here. That is the record of what actually ran,
                    // and without it the app had no way to notice the model reporting work it
                    // never did — "minimize" answered "The window has been minimized" with no
                    // tool call and no audit entry.
                    var (finalResponse, executed) = try await AIProviderService.shared.sendWithTools(
                        toolQuery,
                        context: scopedConversationContext,
                        provider: provider,
                        apiKey: apiKey,
                        conversationHistory: chatHistory,
                        commandExecutor: commandExecutor,
                        maxIterations: complexityRoute.maxToolIterations,
                        additionalSystemPrompt: [activeContextPrompt, complexityRoute.instruction]
                            .filter { !$0.isEmpty }.joined(separator: "\n\n"),
                        imageAttachments: scopedImageAttachments
                    )
                    if Task.isCancelled {
                        await MainActor.run { finishL2AIRequest(l2RequestID) }
                        return
                    }

                    if AgentAnswerVerifier.claimsUnperformedWork(
                        answer: finalResponse, executed: executed) {
                        await self.setL2LoadingStatus(
                            "Checking that actually happened…", requestID: l2RequestID)
                        let correction = AgentAnswerVerifier.correctionPrompt(
                            originalQuery: query, answer: finalResponse, executed: executed)
                        if let (corrected, correctionExecuted) = try? await AIProviderService.shared
                            .sendWithTools(
                                correction,
                                context: scopedConversationContext,
                                provider: provider,
                                apiKey: apiKey,
                                conversationHistory: chatHistory,
                                commandExecutor: commandExecutor,
                                additionalSystemPrompt: activeContextPrompt.isEmpty
                                    ? nil : activeContextPrompt
                            ) {
                            finalResponse = corrected
                            executed += correctionExecuted
                        }
                    }
                    if AgentAnswerVerifier.claimsUnverifiedWork(
                        answer: finalResponse, executed: executed)
                    {
                        await self.setL2LoadingStatus(
                            "Verifying the result…", requestID: l2RequestID)
                        let verification = AgentAnswerVerifier.verificationPrompt(
                            originalQuery: query, answer: finalResponse)
                        if let (verified, verificationExecuted) = try? await AIProviderService.shared
                            .sendWithTools(
                                verification,
                                context: scopedConversationContext,
                                provider: provider,
                                apiKey: apiKey,
                                conversationHistory: chatHistory,
                                commandExecutor: commandExecutor,
                                additionalSystemPrompt: activeContextPrompt.isEmpty
                                    ? nil : activeContextPrompt
                            ) {
                            finalResponse = verified
                            executed += verificationExecuted
                        }
                    }
                    if AgentAnswerVerifier.explicitVerificationIsMissingOrMismatched(
                        query: query, executed: executed)
                    {
                        await self.setL2LoadingStatus(
                            "Checking the requested criterion…", requestID: l2RequestID)
                        if let verification = await AgentAnswerVerifier.executeRequiredVerification(
                            query: query, commandExecutor: commandExecutor
                        ) {
                            finalResponse = verification.answer
                            executed.append(verification.receipt)
                        }
                    }
                    if AgentAnswerVerifier.explicitExecutionIsMissing(
                        query: query, executed: executed)
                    {
                        await self.setL2LoadingStatus(
                            "Running the requested command…", requestID: l2RequestID)
                        if let repair = await AgentAnswerVerifier.executeMissingExplicitContract(
                            query: query, executed: executed, commandExecutor: commandExecutor
                        ) {
                            finalResponse = repair.answer
                            executed += repair.additions
                        }
                    }

                    await self.setL2LoadingStatus(
                        "Reviewing result independently…", requestID: l2RequestID)
                    let subjectiveEvaluation = await FreshResultEvaluator.evaluate(
                        request: query,
                        result: finalResponse,
                        evidence: executed,
                        provider: provider,
                        apiKey: apiKey
                    )

                    var toolsRan = memoryToolChips + (await mcpRan.tools)
                        + executed.map(\.command)
                    await self.setL2LoadingStatus(
                        cliTool.map { "Reading the \($0) output…" } ?? "Checking the result…",
                        requestID: l2RequestID)
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
                    if let applied = await self.resolveTypedAppInvocation(
                        in: finalResponse,
                        scopedBundleId: scopedBundleId,
                        scopeName: scopedAppName.isEmpty
                            ? (frontmostName ?? frontmost.name) : scopedAppName,
                        userQuery: query,
                        requestID: l2RequestID)
                    {
                        finalResponse = applied.answer
                        toolsRan += applied.toolsRan
                    }
                    await MainActor.run {
                        var msg = AIChatMessage(
                            role: .assistant, content: finalResponse, mcpToolsRan: toolsRan,
                            evidenceReceipts: executed.map(EvidenceReceipt.init),
                            subjectiveEvaluation: subjectiveEvaluation,
                            trace: self.l2.routerTrace)
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
                    let cliCommand: String? = scopedBundleId.hasPrefix("cli://")
                        ? String(scopedBundleId.dropFirst("cli://".count))
                        : nil
                    await self.setL2LoadingStatus(
                        cliCommand.map { "Checking \($0) --help and available subcommands…" }
                            ?? "Reading app context and live capabilities…",
                        requestID: l2RequestID)
                    // On-device Apple Intelligence: trim history + use minimal context for scoped apps
                    // to avoid "Exceeded model context window size" from Foundation Models.
                    let onDeviceHistory = Array(chatHistory.suffix(4))
                    let placeholder = AIChatMessage(
                        role: .assistant, content: "", mcpToolsRan: memoryToolChips)
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
                    // A CLI scope already has a strict, help-grounded system prompt. Adding
                    // date/time there encouraged the on-device model to call `date` for a
                    // confirmation such as "yes", instead of continuing the scoped tool flow.
                    let dateHeader = cliCommand == nil
                        ? await MainActor.run { self.currentDateTimeContextBlock() }
                        : ""
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
                            imageURLs: scopedImageAttachments,
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
                                            content: self.l2.chatMessages[idx].content + token,
                                            mcpToolsRan: memoryToolChips
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
                                                id: msgId, role: .assistant, content: rawContent,
                                                mcpToolsRan: memoryToolChips)
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
                    let onDeviceScopeName = scopedAppName.isEmpty
                        ? (frontmostName ?? frontmost.name) : scopedAppName
                    if let resolved = await self.resolveMCPToolCall(
                        in: onDeviceReply, bundleId: scopedBundleId, userQuery: query,
                        provider: provider, apiKey: apiKey, history: onDeviceHistory,
                        systemPrompt: activeContextPrompt,
                        appName: onDeviceScopeName)
                    {
                        await MainActor.run {
                            if let idx = self.l2.chatMessages.firstIndex(where: { $0.id == msgId }) {
                                self.l2.chatMessages[idx] = AIChatMessage(
                                    id: msgId, role: .assistant, content: resolved.answer,
                                    mcpToolsRan: memoryToolChips + resolved.toolsRan)
                            }
                        }
                    } else if let applied = await self.resolveTypedAppInvocation(
                        in: onDeviceReply,
                        scopedBundleId: scopedBundleId,
                        scopeName: onDeviceScopeName,
                        userQuery: query,
                        requestID: l2RequestID)
                    {
                        // The on-device model routes actions as plain-text directives; without
                        // this the raw {"adapter_call":…} line was printed to the user.
                        await MainActor.run {
                            if let idx = self.l2.chatMessages.firstIndex(where: { $0.id == msgId }) {
                                self.l2.chatMessages[idx] = AIChatMessage(
                                    id: msgId, role: .assistant, content: applied.answer,
                                    mcpToolsRan: memoryToolChips + applied.toolsRan)
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
                        var toolsRan: [String] = memoryToolChips
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
                            toolsRan += resolved.toolsRan
                        } else if let applied = await self.resolveTypedAppInvocation(
                            in: reply,
                            scopedBundleId: scopedBundleId,
                            scopeName: scopedAppName.isEmpty
                                ? (frontmostName ?? frontmost.name) : scopedAppName,
                            userQuery: query,
                            requestID: l2RequestID)
                        {
                            finalReply = applied.answer
                            toolsRan += applied.toolsRan
                        }
                        await MainActor.run {
                            var msg = AIChatMessage(
                                role: .assistant,
                                content: finalReply.trimmingCharacters(in: .whitespacesAndNewlines)
                                    .isEmpty ? "The Shortcut returned no output." : finalReply,
                                mcpToolsRan: toolsRan,
                                trace: self.l2.routerTrace)
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
        await AppleLiveDataContext.appleAppsContextBlock(for: query)
    }

    /// Combined Apple-apps data + live weather for a query, ready to append to any chat
    /// system prompt. Used by both General Chat and Context Dock chat so both answer with
    /// real Calendar/Reminders/Contacts/Photos/Notes/Mail/Music/Safari/Weather data.
    func appleAppsAndWeatherContext(for query: String) async -> String {
        await AppleLiveDataContext.appleAppsAndWeatherContext(for: query)
    }

    /// Reads the app back after an action and reports what actually moved.
    ///
    /// "Done" is a claim about the model's intent; this is a claim about the machine. An
    /// action that succeeds mechanically while nothing changes — a menu item that was
    /// disabled, a command that hit the wrong window — is exactly the case a user cannot
    /// spot from a confident reply.
    static func verify(
        ran: Bool, label: String, bundleId: String, appName: String,
        before: ResolvedContext
    ) async -> String {
        guard ran else { return "Couldn't run \(label)." }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let changes = await MainActor.run { () -> [String] in
            ContextResolver.resolve(scope: .app(bundleId: bundleId), appName: appName)
                .changes(since: before)
        }
        guard !changes.isEmpty else {
            return "Ran \(label), but nothing observable changed in \(appName)."
        }
        return "Done — \(label).\n\n" + changes.map { "· \($0)" }.joined(separator: "\n")
    }

    /// Runs a `menu_call` / `adapter_call` the model emitted as plain text and returns the
    /// confirmation that replaces the JSON. Every provider path needs this: only the cloud
    /// tool loop used to execute these, so an on-device or Shortcuts reply printed the raw
    /// `{"adapter_call":…}` blob into the chat and the action never ran.
    /// Returns nil when the reply carries no such directive.
    func resolveTypedAppInvocation(
        in response: String,
        scopedBundleId: String,
        scopeName: String,
        userQuery: String,
        requestID: UUID
    ) async -> (answer: String, toolsRan: [String])? {
        guard let invocation = AITypedInvocationResolver.invocation(from: response) else {
            return nil
        }
        let bundle = (invocation.arguments["bundleId"].flatMap { $0.isEmpty ? nil : $0 })
            ?? scopedBundleId

        switch invocation.kind {
        case .menuAction:
            let path = (invocation.arguments["path"] ?? "")
                .components(separatedBy: "\u{1F}").filter { !$0.isEmpty }
            guard !path.isEmpty else { return nil }
            let label = path.joined(separator: " ▸ ")
            await setL2LoadingStatus("Running \(label)…", requestID: requestID)
            let before = await MainActor.run {
                ContextResolver.resolve(scope: .app(bundleId: bundle), appName: scopeName)
            }
            let (ok, out) = await AppAdapterManager.shared.runMenuPath(
                path, targetBundleId: bundle, appName: scopeName)
            let verdict = await Self.verify(
                ran: ok, label: label, bundleId: bundle, appName: scopeName, before: before)
            return (
                ok ? verdict : (out.isEmpty ? "Couldn't run \(label)." : out),
                [label]
            )

        case .adapterAction:
            let actionId = invocation.arguments["actionId"] ?? ""
            guard let adapter = AppAdapterManager.shared.adapter(for: bundle),
                let action = adapter.actions.first(where: { $0.id == actionId })
            else {
                // A hallucinated action id must not reach the user as JSON.
                return (
                    "That action isn’t available in \(scopeName). Add it in Settings → App "
                        + "Adapters → \(scopeName), or ask for something its current tools cover.",
                    []
                )
            }
            await setL2LoadingStatus("Running \(action.name)…", requestID: requestID)
            let ctx = await MainActor.run {
                self.sanitizedAXContextForScope(self.axContext, scopedBundleId: bundle)
            }
            let beforeAction = await MainActor.run {
                ContextResolver.resolve(scope: .app(bundleId: bundle), appName: scopeName)
            }
            let (ok, out) = await AppAdapterManager.shared.execute(
                action, context: ctx, targetBundleId: bundle,
                query: invocation.arguments["query"] ?? userQuery)
            let actionVerdict = await Self.verify(
                ran: ok, label: action.name, bundleId: bundle, appName: scopeName,
                before: beforeAction)
            return (
                ok
                    ? (out.isEmpty ? actionVerdict : "\(out)\n\n\(actionVerdict)")
                    : (out.isEmpty ? "Couldn't run \(action.name)." : out),
                [action.name]
            )

        default:
            return nil
        }
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
                commandExecutor: { _, _, _ in (false, "", -1) },
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

    /// Answer browser history / bookmark / open-tab questions from the same local URL
    /// library that powers Context Dock search rows. The data never enters a provider
    /// prompt — the answer is formatted here and returned as the assistant message.
    @MainActor
    func isBrowserHistoryReadQuery(_ query: String) -> Bool {
        LauncherView.isBrowserLibraryReadPhrase(
            query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// True when the phrase asks to SEE local browser data (history, bookmarks, open
    /// tabs) rather than to act on the browser. Kept `static` so the executable-intent
    /// resolver can consult it without a view instance — a read like "show all opened
    /// tabs" starts with the verb "show " and used to route to an app action.
    static func isBrowserLibraryReadPhrase(_ normalized: String) -> Bool {
        // "open <x> history page" is navigation, owned by SafariCapabilityRouter.
        guard !normalized.hasPrefix("open ") else { return false }
        if normalized.contains("browser history") || normalized.contains("browsing history") {
            return true
        }
        // Acting ON the data, not reading it.
        let actionWords = [
            "clear ", "delete ", "remove ", "erase ", "close ", "new tab", "new window",
            "bookmark this", "bookmark the", "add bookmark", "save bookmark",
        ]
        if actionWords.contains(where: normalized.contains) { return false }
        // "visit" unsuffixed, because visit/visited/visiting/visite are all the same
        // question and a trailing space made "did i visite any website today?" match none
        // of them. "website" and friends were missing outright, so the most ordinary way to
        // ask this — naming the thing rather than the log it lives in — was never
        // recognised, and the question fell through to a generic answer that reported
        // finding nothing while Safari sat enabled two inches away.
        let dataWords = [
            "history", "visit", "bookmark", "opened tab", "open tab", "tabs",
            "website", "web site", "webpage", "web page", "browse", "browsing", "url",
        ]
        guard dataWords.contains(where: normalized.contains) else { return false }
        let readShapes = [
            "what", "which", "show", "list", "find", "search", "how many", "give me",
            "all ", "any ", "recent", "did i", "have i", "tell me",
        ]
        return readShapes.contains(where: normalized.contains)
    }

    @MainActor
    private func structuredSafariTabs(for query: String, bundleID: String) -> [BrowserTabAction] {
        let lower = query.lowercased()
        guard bundleID == "com.apple.Safari" || bundleID.hasPrefix("com.apple.Safari.WebApp"),
            lower.contains("tab")
        else { return [] }
        return ContextDetector.shared.getAllSafariTabs().prefix(40).map {
            BrowserTabAction(
                title: $0.title, url: $0.url,
                windowIndex: $0.windowIndex, tabIndex: $0.tabIndex)
        }
    }

    private func isSafariPageLinkReadQuery(_ query: String, bundleID: String) -> Bool {
        guard bundleID == "com.apple.Safari" || bundleID.hasPrefix("com.apple.Safari.WebApp")
        else { return false }
        let lower = query.lowercased()
        let asksForLinks = lower.contains("link") || lower.contains("urls on")
        let reads = [
            "show", "list", "find", "extract", "what", "which", "contain", "contains",
            "has", "have", "any", "are there", "is there", "does", "tell me"
        ].contains {
            lower.contains($0)
        }
        return asksForLinks && reads
    }

    private func isSafariPageLinkOpenQuery(_ query: String, bundleID: String) -> Bool {
        guard bundleID == "com.apple.Safari" || bundleID.hasPrefix("com.apple.Safari.WebApp")
        else { return false }
        let lower = query.lowercased()
        guard lower.contains("open") || lower.contains("go to") || lower.contains("visit")
        else { return false }
        // A page-relative phrase is ideal, but named destinations such as GitHub, Twitter,
        // documentation, guide, pricing, etc. are also resolved against the live link set.
        return lower.contains("link") || lower.contains("this page") || lower.contains("from page")
            || lower.contains("guide") || lower.contains("github") || lower.contains("twitter")
            || lower.contains("documentation") || lower.contains("docs")
    }

    private func rankedSafariPageLinks(
        _ links: [PageLinkAction], for query: String
    ) -> [PageLinkAction] {
        let ignored: Set<String> = [
            "open", "visit", "this", "that", "page", "link", "links", "from", "the", "please",
            "guide", "site", "website", "want", "think",
        ]
        let tokens = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !ignored.contains($0) }
        guard !tokens.isEmpty else { return [] }

        return links.compactMap { link -> (PageLinkAction, Int)? in
            let title = link.title.lowercased()
            let domain = link.domain.lowercased()
            let url = link.url.lowercased()
            let score = tokens.reduce(0) { total, token in
                total
                    + (title.contains(token) ? 4 : 0)
                    + (domain.contains(token) ? 5 : 0)
                    + (url.contains(token) ? 2 : 0)
            }
            return score > 0 ? (link, score) : nil
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.title.count < $1.0.title.count
        }
        .map(\.0)
    }

    private func safariPageLinks(
        _ links: [PageLinkAction], relevantTo query: String
    ) -> [PageLinkAction] {
        let lower = query.lowercased()
        if lower.contains("social") {
            let socialHosts = [
                "github.", "twitter.", "x.com", "mastodon.", "patreon.", "facebook.",
                "instagram.", "linkedin.", "youtube.", "discord.", "reddit.", "threads.",
            ]
            return links.filter { link in
                let haystack = "\(link.title) \(link.url)".lowercased()
                return socialHosts.contains(where: haystack.contains)
            }
        }
        let namedHosts = ["github", "twitter", "mastodon", "patreon", "instagram", "linkedin"]
            .filter(lower.contains)
        guard !namedHosts.isEmpty else { return links }
        return links.filter { link in
            let haystack = "\(link.title) \(link.url)".lowercased()
            return namedHosts.contains(where: haystack.contains)
        }
    }

    private func isSafariPageUnderstandingReadQuery(_ query: String, bundleID: String) -> Bool {
        guard bundleID == "com.apple.Safari" || bundleID.hasPrefix("com.apple.Safari.WebApp")
        else { return false }
        if isSafariPageLinkReadQuery(query, bundleID: bundleID) { return true }
        let lower = query.lowercased()
        let pageReference = lower.contains("this page") || lower.contains("current page")
            || lower.contains("article") || lower.contains("website")
        let readIntent = [
            "summarize", "summarise", "explain", "what is", "what does", "tell me",
            "key points", "main points", "read", "analyse", "analyze", "compare"
        ].contains { lower.contains($0) }
        return pageReference && readIntent
    }

    @MainActor
    private func structuredSafariPageLinks() -> [PageLinkAction]? {
        guard SafariBrowserBridge.shared.isFresh,
            let context = SafariBrowserBridge.shared.currentContext()
        else { return nil }
        var seen = Set<String>()
        return context.links.compactMap { link in
            guard !link.url.isEmpty, seen.insert(link.url).inserted else { return nil }
            return PageLinkAction(
                title: link.text.isEmpty ? link.url : link.text,
                url: link.url,
                pageTitle: context.title)
        }
    }

    /// Read-only recovery path when Safari's passive native-message payload is stale. This
    /// executes Context Dock-owned JavaScript directly in the current Safari tab; it does not
    /// open an Extension Actions menu, run a user adapter, or mutate the page.
    private func readCurrentSafariPageLinksDirectly() async -> [PageLinkAction] {
        let script = #"""
        (function() { return JSON.stringify(Array.from(document.querySelectorAll('a[href]')).map(function(a) {
          var text = (a.innerText || a.getAttribute('aria-label') || a.title || '').replace(/\s+/g, ' ').trim();
          var url = '';
          try { url = new URL(a.getAttribute('href'), location.href).href; } catch (_) { return null; }
          if (!text) {
            var image = a.querySelector('img');
            text = image ? (image.getAttribute('alt') || '') : '';
          }
          if (!text) {
            try { text = new URL(url).hostname.replace(/^www\./, '').split('.')[0]; } catch (_) {}
          }
          if (!text || !/^https?:/i.test(url)) return null;
          return { title: text.slice(0, 100), url: url, pageTitle: document.title || '' };
        }).filter(Boolean).filter(function(item, index, rows) {
          return rows.findIndex(function(other) { return other.url === item.url; }) === index;
        }).slice(0, 60)); })()
        """#
        guard let raw = await executeCurrentSafariReadJavaScript(expression: script),
            !raw.hasPrefix("JS error:"),
            let data = raw.data(using: .utf8),
            let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
        else { return [] }
        return rows.compactMap { row in
            guard let url = row["url"], !url.isEmpty else { return nil }
            return PageLinkAction(
                title: row["title"]?.isEmpty == false ? row["title"]! : url,
                url: url,
                pageTitle: row["pageTitle"] ?? "")
        }
    }

    /// Full live-page recovery used for model context when the Safari extension payload is
    /// stale. It preserves exact anchors in Markdown form; MarkItDown's query-aware compactor
    /// then keeps the most relevant sections inside the provider's token budget.
    private func readCurrentSafariPagePromptDirectly(query: String) async -> String? {
        let script = #"""
        (function() {
          var root = document.querySelector('article') || document.querySelector('main') || document.body;
          var rows = Array.from(document.querySelectorAll('a[href]')).map(function(a) {
            var url = '';
            try { url = new URL(a.getAttribute('href'), location.href).href; } catch (_) { return null; }
            if (!/^https?:/i.test(url)) return null;
            var text = (a.innerText || a.getAttribute('aria-label') || a.title || '').replace(/\s+/g, ' ').trim();
            if (!text) { var image = a.querySelector('img'); text = image ? (image.getAttribute('alt') || '') : ''; }
            if (!text) { try { text = new URL(url).hostname.replace(/^www\./, '').split('.')[0]; } catch (_) {} }
            return text ? { text: text.slice(0, 100), url: url } : null;
          }).filter(Boolean).filter(function(item, index, all) {
            return all.findIndex(function(other) { return other.url === item.url; }) === index;
          }).slice(0, 60);
          return JSON.stringify({
            title: document.title || '', url: location.href,
            text: (root ? root.innerText : '').trim().slice(0, 12000), links: rows
          });
        })()
        """#
        guard let raw = await executeCurrentSafariReadJavaScript(expression: script),
            !raw.hasPrefix("JS error:"), let data = raw.data(using: .utf8),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let title = payload["title"] as? String ?? ""
        let url = payload["url"] as? String ?? ""
        let text = payload["text"] as? String ?? ""
        let compacted = MarkItDownService.compact(text, for: query, limit: 5_000)
        let links = (payload["links"] as? [[String: Any]] ?? []).compactMap { row -> String? in
            guard let target = row["url"] as? String, !target.isEmpty else { return nil }
            let label = (row["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return "- [\((label?.isEmpty == false ? label : target) ?? target)](\(target))"
        }.joined(separator: "\n")
        guard !compacted.isEmpty || !url.isEmpty || !links.isEmpty else { return nil }
        return """
            CURRENT PAGE TITLE: \(title.isEmpty ? "(unknown)" : title)
            CURRENT PAGE URL: \(url.isEmpty ? "(unknown)" : url)
            PAGE MARKDOWN EXCERPT:
            \(compacted.isEmpty ? "(visible text unavailable)" : compacted)

            PAGE LINKS:
            \(links.isEmpty ? "(no readable links)" : links)
            Use only these exact URLs for page-relative answers and navigation.
            """
    }

    /// Read-only DOM execution with honest fallback semantics. The Safari extension can be
    /// enabled while its passive native payload is stale (Safari may keep an older service
    /// worker alive). First use Safari's direct read path; if that is unavailable, wake the
    /// already-enabled extension and run the same expression in its isolated world.
    private func executeCurrentSafariReadJavaScript(expression: String) async -> String? {
        if let direct = await SafariTabManager.shared.executeJS(expression),
            !direct.hasPrefix("JS error:"), !direct.isEmpty
        {
            return direct
        }
        guard let safari = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.Safari" && !$0.isTerminated
        }) else { return nil }
        let extensionCode = "return " + expression
        guard let bridged = try? await SafariExtensionCommandBridge.shared.runJavaScript(
            extensionCode, in: safari),
            !bridged.hasPrefix("JS error:"), !bridged.isEmpty
        else { return nil }
        return bridged
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

        // What the question actually asks for — parsed by the on-device model, else the
        // user's selected provider, else a deterministic heuristic. Only the sentence is
        // parsed; the library rows below never reach a model.
        let intent = await BrowserLibraryIntentParser.shared.intent(for: normalized)

        // Open tabs are live app state, not library data — answer them from the browser
        // itself. "show all opened tabs" used to reach the executable planner and open a
        // NEW tab instead of listing the existing ones.
        if intent.source == .tabs {
            return openBrowserTabsAnswer(intent: intent, bundleId: requestedBundle)
        }
        let wantsBookmarks = intent.source == .bookmarks
        let wantsHistory = !wantsBookmarks

        let searchTerm = intent.subject
        let wantsSingleLatest = intent.wantsLatest
        let dateWindow = intent.dateWindow
        // A date-bounded question ("yesterday") needs the whole window, not the top few.
        let fetchLimit = dateWindow != nil ? 400 : (requireAppAdapter && requestedBundle == nil ? 200 : 40)
        let libraryQuery = searchTerm.isEmpty ? (wantsBookmarks ? "bookmarks" : "history") : searchTerm
        var unmatchedSubject = ""
        var entries = await BrowserURLLibraryService.shared.refreshedEntries(
            matching: libraryQuery,
            bundleId: requestedBundle,
            limit: fetchLimit)
        // A subject that matches nothing is still a real question about the library
        // ("what did I read about swiftui?" with no swiftui visit). Fall back to the
        // recency listing so the answer describes what IS there instead of stopping at
        // a bare "nothing matching".
        if entries.isEmpty, !searchTerm.isEmpty {
            entries = await BrowserURLLibraryService.shared.refreshedEntries(
                matching: wantsBookmarks ? "bookmarks" : "history",
                bundleId: requestedBundle,
                limit: fetchLimit)
            unmatchedSubject = searchTerm
        }
        if requireAppAdapter, requestedBundle == nil {
            entries = entries.filter { allowedBrowserBundles.contains($0.browserBundleId) }
        }
        // Bookmarks carry no visit date, so a date window implies history only.
        if wantsBookmarks, !wantsHistory {
            entries = entries.filter { $0.kind == .bookmark }
        } else if dateWindow != nil || (wantsHistory && !wantsBookmarks) {
            entries = entries.filter { $0.kind == .history }
        }
        if let dateWindow {
            entries = entries.filter { entry in
                guard let visited = entry.visitDate else { return false }
                return visited >= dateWindow.start && visited < dateWindow.end
            }
        }

        let subjectLabel = wantsBookmarks && !wantsHistory ? "bookmarks" : "history"
        guard !entries.isEmpty else {
            if BrowserURLLibraryService.shared.refreshInProgress {
                return "Your local browser \(subjectLabel) is still refreshing. Please try again in a moment."
            }
            // Empty because it could not be read is not empty because nothing is there.
            // Safari keeps its history in a database DoraX can only open with Full Disk
            // Access, and reporting "no visits" for a missing permission is a lie the user
            // has no way to diagnose.
            let safariDB = NSHomeDirectory() + "/Library/Safari/History.db"
            if !FileManager.default.isReadableFile(atPath: safariDB) {
                var reply =
                    "I can't read Safari's history database — that needs Full Disk Access "
                    + "for Context-Dock in System Settings → Privacy & Security."
                if let menuFallback = AppScopedChatService.browserHistoryFacts(
                    bundleID: "com.apple.Safari", appName: "Safari")
                {
                    reply += "\n\nFrom Safari's own History menu I can still see:\n\n"
                        + menuFallback
                }
                return reply
            }
            if dateWindow != nil {
                return "I checked the local browser-\(subjectLabel) cache and found no visits in that time range."
            }
            let subject = searchTerm.isEmpty ? "that" : "“\(searchTerm)”"
            return "I checked the local browser-\(subjectLabel) cache and found nothing matching \(subject)."
        }

        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        func row(_ entry: BrowserURLLibraryEntry) -> String {
            let rawTitle = entry.title.isEmpty ? entry.domain : entry.title
            let title = rawTitle
                .replacingOccurrences(of: "[", with: "(")
                .replacingOccurrences(of: "]", with: ")")
            if entry.kind == .bookmark {
                return "[\(title)](\(entry.url.absoluteString)) — \(entry.browserName) bookmark"
            }
            let date = entry.visitDate.map(formatter.string(from:)) ?? "date unavailable"
            return "[\(title)](\(entry.url.absoluteString)) — \(entry.browserName), \(date)"
        }

        // "what is my last visited site?" wants one row, not a list.
        if wantsSingleLatest, unmatchedSubject.isEmpty, let newest = entries.first {
            let copied = copyBrowserLinks(
                requested: intent.copyToClipboard, urls: [newest.url.absoluteString])
            return "Your most recent visit: \(row(newest))" + copied
        }

        let shown = Array(entries.prefix(dateWindow != nil ? 25 : 8))
        let lines = shown.map { "- " + row($0) }
        let noun = wantsBookmarks && !wantsHistory ? "bookmark" : "visit"
        let countLabel =
            entries.count == 1 ? "one matching \(noun)" : "\(entries.count) matching \(noun)s"
        let more = entries.count > shown.count ? "\n…and \(entries.count - shown.count) more." : ""
        let copied = copyBrowserLinks(
            requested: intent.copyToClipboard, urls: shown.map(\.url.absoluteString))
        let lead =
            unmatchedSubject.isEmpty
            ? "I checked the local browser-\(subjectLabel) cache and found \(countLabel):"
            : "Nothing in the local browser-\(subjectLabel) cache matches “\(unmatchedSubject)”. "
                + "The most recent entries are:"
        return lead + "\n\n" + lines.joined(separator: "\n") + more + copied
    }

    /// Every open tab of the scoped browser (or Safari when unscoped), read live via the
    /// same AppleScript readers the dock already uses.
    @MainActor
    private func openBrowserTabsAnswer(
        intent: BrowserLibraryIntent, bundleId: String?
    ) -> String {
        let detector = ContextDetector.shared
        let target = bundleId ?? "com.apple.Safari"
        let tabs: [BrowserTab]
        let browserName: String
        switch target {
        case "com.google.Chrome", "com.brave.Browser", "org.chromium.Chromium",
            "com.microsoft.edgemac":
            tabs = detector.getAllChromeTabs()
            browserName = "Chrome"
        case "company.thebrowser.Browser":
            tabs = detector.getAllArcTabs()
            browserName = "Arc"
        default:
            tabs = detector.getAllSafariTabs()
            browserName = "Safari"
        }
        guard !tabs.isEmpty else {
            return "\(browserName) has no open tabs I can read right now."
        }
        let lines = tabs.prefix(40).map { tab -> String in
            let title = tab.title.isEmpty ? tab.url : tab.title
            return "- [\(title)](\(tab.url))"
        }
        let more = tabs.count > 40 ? "\n…and \(tabs.count - 40) more." : ""
        let copied = copyBrowserLinks(
            requested: intent.copyToClipboard, urls: tabs.map(\.url))
        let countLabel = tabs.count == 1 ? "one open tab" : "\(tabs.count) open tabs"
        return "\(browserName) has \(countLabel):\n\n" + lines.joined(separator: "\n") + more
            + copied
    }

    /// "…copy to clipboard" is part of the same read request — honour it here instead of
    /// letting the executable planner take over the whole query.
    @MainActor
    private func copyBrowserLinks(requested: Bool, urls: [String]) -> String {
        guard requested, !urls.isEmpty else { return "" }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.joined(separator: "\n"), forType: .string)
        return "\n\nCopied \(urls.count) link\(urls.count == 1 ? "" : "s") to the clipboard."
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

    /// Supplies interactive rows only when the user has explicitly enabled the named
    /// app for this General Chat and the shared Global Context semantic parser says the
    /// request is about recency. The service is already TTL-cached, so this is a cheap
    /// snapshot taken once after the answer—not work performed while typing.
    func generalAIRecentFileActions(for query: String) -> [RecentFileAction] {
        guard currentAISelectionSnapshot.isEmpty,
              finderSemanticProfile(for: query).wantsRecent,
              let namedApp = GeneralAIActionResolver.shared.namedInstalledApp(in: query),
              chatFocusApps.contains(where: {
                  $0.bundleId.caseInsensitiveCompare(namedApp.bundleId) == .orderedSame
              })
        else { return [] }

        return RecentItemsService.shared.recentDocuments()
            .prefix(12)
            .map { RecentFileAction(url: $0.url) }
    }

    func sendToAIProvider(
        query: String,
        attachments: [URL] = [],
        providerSelection capturedSelection: AIProviderSelection? = nil
    ) async throws -> String {
        // Settings can change while the shared Chat shell remains open. Refresh dynamic
        // capability families for every request so added/edited/disabled Global Commands
        // and MCP toggles cannot leave classification and execution using different views.
        CapabilityRegistry.shared.refreshGlobalCommands()
        CapabilityRegistry.shared.refreshBuiltInMCPs()

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
        // Decide evidence authority before any memory lookup or provider prompt is built.
        // General Chat previously skipped this rule even though Context Dock chat used it,
        // allowing a saved preference to answer a question about mutable live state.
        let sourceDecision = AgentSourceAuthority.decide(query: query)
        let requestLiveContext = generalChatPolicy.includesLiveContext(
            explicitlyRequested: false
        ) ? ContextCollector.shared.snapshot() : nil

        // Capability-first system reads. This runs before Markdown memory so a saved
        // preference ("I like dark mode") cannot masquerade as current Mac state. Explicit
        // changes still continue to the normal approval-backed action router below.
        if sourceDecision.primary == .liveState,
           currentAISelectionSnapshot.isEmpty,
           let liveSystemState = await GlobalCommandCapabilities.liveStateAnswer(for: query) {
            await MainActor.run {
                aiMode.loadingStatus = nil
                aiMode.pendingToolChips = [liveSystemState.label]
            }
            return liveSystemState.answer
        }

        // Exact Global Command names are deterministic installed capabilities. Execute them
        // directly instead of asking a language model whether it feels like calling the tool.
        // This also ensures the approval card and evidence receipts describe real work.
        if currentAISelectionSnapshot.isEmpty,
           let match = GlobalCommandCapabilities.explicitRunMatch(for: query) {
            let plan = AIActionPlan(
                capability: match.id, input: [:],
                explanation: "Run the installed Global Command \(match.command.name)")
            let result = try await AIExecutionEngine.shared.executeWithApproval(
                plan, context: .none)
            var executed = [AIProviderService.ExecutedCommand(
                command: "run_capability(\(match.id))",
                output: result.output,
                success: result.success,
                isVerification: false
            )]
            var answer = result.success
                ? (result.output.isEmpty ? "Ran \(match.command.name)." : result.output)
                : "\(match.command.name) did not run: \(result.output)"

            if result.success,
               let verification = await AgentAnswerVerifier.executeRequiredVerification(
                    query: query,
                    commandExecutor: { _, _, _ in (false, "Not used for typed read-back.", -1) }
               ) {
                answer += "\n\n" + verification.answer
                executed.append(verification.receipt)
            }
            await MainActor.run {
                aiMode.loadingStatus = nil
                aiMode.pendingToolChips = executed.map(\.command)
                aiMode.pendingEvidenceReceipts = executed.map(EvidenceReceipt.init)
            }
            return answer
        }

        if let memoryAnswer = MarkdownMemoryStore.shared.cacheFromCommand(query) {
            await MainActor.run {
                aiMode.loadingStatus = nil
                aiMode.pendingToolChips = ["Local Markdown cache"]
            }
            return memoryAnswer
        }
        if let memoryAnswer = MarkdownMemoryStore.shared.replaceFromCommand(query) {
            await MainActor.run {
                aiMode.loadingStatus = nil
                aiMode.pendingToolChips = ["Local Markdown memory"]
            }
            return memoryAnswer
        }
        if let memoryAnswer = MarkdownMemoryStore.shared.forgetFromCommand(query) {
            await MainActor.run {
                aiMode.loadingStatus = nil
                aiMode.pendingToolChips = ["Local Markdown memory"]
            }
            return memoryAnswer
        }
        if let memoryAnswer = MarkdownMemoryStore.shared.remember(query) {
            await MainActor.run {
                aiMode.loadingStatus = nil
                aiMode.pendingToolChips = ["Local Markdown memory"]
            }
            return memoryAnswer
        }
        if let memoryURL = MarkdownMemoryStore.shared.requestedMemoryURL(from: query) {
            await MainActor.run {
                NSWorkspace.shared.open(memoryURL)
                aiMode.loadingStatus = nil
                aiMode.pendingToolChips = ["Local Markdown memory"]
            }
            return "Opened \(memoryURL.lastPathComponent) from local Markdown memory."
        }
        if let memoryAnswer = MarkdownMemoryStore.shared.recallAnswer(for: query) {
            await MainActor.run {
                aiMode.loadingStatus = nil
                aiMode.pendingToolChips = ["Local Markdown memory"]
            }
            return memoryAnswer
        }

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
            }),
            !CapabilityRegistry.shared.all.contains(where: {
                $0.appBundleID?.caseInsensitiveCompare(namedApp.bundleId) == .orderedSame
                    && $0.riskLevel == .low
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
            A tool call and an answer are separate replies — never mix them in one message.
            To call a tool, reply with ONLY the tool-call JSON described below and nothing
            else: no greeting, no explanation, no code fence around it. To answer the user,
            reply with prose only, containing no tool-call JSON and no <function>/<invoke>
            XML. Scaffolding leaking into a prose answer is the thing to avoid; emitting a
            lone tool call is how you use the tools at all.
            \(currentDateTimeContextBlock())
            """
        sysContent += "\n\n" + sourceDecision.promptRule
        let memoryBlock = sourceDecision.allowsMemoryEvidence
            ? MarkdownMemoryStore.shared.contextBlock(query: query) : ""
        let memoryToolChips = sourceDecision.allowsMemoryEvidence
            ? MarkdownMemoryStore.shared.relevantSourceChips(query: query) : []
        if !memoryBlock.isEmpty { sysContent += "\n\n" + memoryBlock }
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
            let focusedContext = await selectedGeneralChatAppContext(query: query)
            if focusedContext.cancelled {
                return "Cancelled — selected app context was not read."
            }
            if !focusedContext.block.isEmpty {
                sysContent += "\n\n" + focusedContext.block
            }
        }

        // Model-first: the keyword routers below stop being able to answer, and become a
        // hint instead. See AppSettings.agentModelFirstRouting for why.
        let modelFirst = AppSettings.shared.agentModelFirstRouting
        if modelFirst {
            let hints = await routerCandidateHints(query: query)
            if !hints.isEmpty {
                sysContent += "\n\n" + hints
            }
        }

        // Read-only capability router first. Queries like "show Salman Khan email" are
        // contact lookups, not Mail/share commands. Run this before executable routing so
        // personal-data reads don't get misclassified as actions.
        let hasDeterministicReadDomain = readOnlyDataDomain(for: query) != nil
        if (!modelFirst || hasDeterministicReadDomain),
           attachments.isEmpty, currentAISelectionSnapshot.isEmpty,
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

        let exactSelectedAdapterAction = hasExactSelectedAdapterAction(query: actionQuery)
        if (!modelFirst || exactSelectedAdapterAction),
           attachments.isEmpty, currentAISelectionSnapshot.isEmpty,
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

        if !modelFirst, currentAISelectionSnapshot.isEmpty,
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
            // Bounded, as the window's identical call already is. The hub reaches into the
            // MCP actor and across every enabled adapter; one unreachable server there used
            // to hold this turn open indefinitely, and because a turn in flight blocks the
            // next question, every Return afterwards was swallowed in silence. Losing the
            // tool block costs the model its catalogue for one answer. Losing the turn costs
            // the user the surface.
            let appToolsBlock = await AsyncTimeout.run(
                seconds: 8, fallback: "", label: "general chat capability block"
            ) {
                await GeneralChatCapabilityHub.shared.capabilityPromptBlock(
                    compact: toolProvider == .onDevice,
                    query: query,
                    scope: executionScope,
                    // Per-provider budget. On-device Apple Intelligence gets a fraction of
                    // the cloud allowance — its window is small enough that an unbudgeted
                    // capability block alone overflowed it.
                    characterBudget: AIContextBudget.characterBudget(for: toolProvider))
            }
            if !appToolsBlock.isEmpty {
                let toolSystemPrompt = sysContent + "\n\n" + appToolsBlock

                // Providers with real function calling get the same path Context Dock uses:
                // schemas from AgentToolRegistry, a structured tool call back, dispatch by
                // name. The prose protocol below stays only for Apple Intelligence, which
                // has no function-calling API at all.
                //
                // General Chat previously used the prose protocol for EVERY provider, so
                // run_command, find_capability and run_capability were unreachable here —
                // the model could only ask for a tool by writing JSON into its answer, and
                // the same system prompt told it never to do that.
                if toolProvider.supportsNativeTools {
                    let complexityRoute = TaskComplexityRouter.route(query)
                    await MainActor.run {
                        aiMode.routerTrace.append("Complexity: \(complexityRoute.rawValue)")
                    }
                    let rawKey = toolProvider.requiresAPIKey
                        ? AppSettings.shared.getAPIKey(for: toolProvider) : ""
                    let toolAPIKey: String? = rawKey.isEmpty ? nil : rawKey
                    let generalCommandExecutor:
                        (String, String, Bool) async -> (Bool, String, Int32) = { command, purpose, needsApproval in
                            await TerminalCommandExecutor.shared.run(
                                command, purpose: purpose,
                                modelRequiresApproval: needsApproval,
                                consoleScope: .general)
                        }
                    await MainActor.run { aiMode.loadingStatus = "Working…" }
                    var (finalResponse, executed) = try await AIProviderService.shared.sendWithTools(
                        query,
                        context: .none,
                        provider: toolProvider,
                        apiKey: toolAPIKey,
                        conversationHistory: history,
                        commandExecutor: generalCommandExecutor,
                        maxIterations: complexityRoute.maxToolIterations,
                        additionalSystemPrompt: toolSystemPrompt + "\n\n" + complexityRoute.instruction
                    )

                    // Verification. The app knows which tools ran; the model does not get to
                    // assert otherwise. An answer claiming completed work when nothing
                    // executed is corrected against that record, once.
                    if AgentAnswerVerifier.claimsUnperformedWork(
                        answer: finalResponse, executed: executed) {
                        await MainActor.run { aiMode.loadingStatus = "Checking that actually happened…" }
                        let correction = AgentAnswerVerifier.correctionPrompt(
                            originalQuery: query, answer: finalResponse, executed: executed)
                        let (corrected, correctionExecuted) =
                            try await AIProviderService.shared.sendWithTools(
                                correction,
                                context: .none,
                                provider: toolProvider,
                                apiKey: toolAPIKey,
                                conversationHistory: history,
                                commandExecutor: generalCommandExecutor,
                                additionalSystemPrompt: toolSystemPrompt
                            )
                        finalResponse = corrected
                        executed += correctionExecuted
                    }
                    if AgentAnswerVerifier.claimsUnverifiedWork(
                        answer: finalResponse, executed: executed)
                    {
                        await MainActor.run { aiMode.loadingStatus = "Verifying the result…" }
                        let verification = AgentAnswerVerifier.verificationPrompt(
                            originalQuery: query, answer: finalResponse)
                        let (verified, verificationExecuted) =
                            try await AIProviderService.shared.sendWithTools(
                                verification,
                                context: .none,
                                provider: toolProvider,
                                apiKey: toolAPIKey,
                                conversationHistory: history,
                                commandExecutor: generalCommandExecutor,
                                additionalSystemPrompt: toolSystemPrompt
                            )
                        finalResponse = verified
                        executed += verificationExecuted
                    }
                    if AgentAnswerVerifier.explicitVerificationIsMissingOrMismatched(
                        query: query, executed: executed)
                    {
                        await MainActor.run {
                            aiMode.loadingStatus = "Checking the requested criterion…"
                        }
                        if let verification = await AgentAnswerVerifier.executeRequiredVerification(
                            query: query, commandExecutor: generalCommandExecutor
                        ) {
                            finalResponse = verification.answer
                            executed.append(verification.receipt)
                        }
                    }
                    if AgentAnswerVerifier.explicitExecutionIsMissing(
                        query: query, executed: executed)
                    {
                        await MainActor.run {
                            aiMode.loadingStatus = "Running the requested command…"
                        }
                        if let repair = await AgentAnswerVerifier.executeMissingExplicitContract(
                            query: query, executed: executed,
                            commandExecutor: generalCommandExecutor
                        ) {
                            finalResponse = repair.answer
                            executed += repair.additions
                        }
                    }

                    await MainActor.run {
                        aiMode.loadingStatus = FreshResultEvaluator.shouldEvaluate(query)
                            ? "Reviewing result independently…" : nil
                    }
                    let subjectiveEvaluation = await FreshResultEvaluator.evaluate(
                        request: query,
                        result: finalResponse,
                        evidence: executed,
                        provider: toolProvider,
                        apiKey: toolAPIKey
                    )

                    await MainActor.run {
                        aiMode.loadingStatus = nil
                        // Chips report what actually ran. They used to be derived from words
                        // in the query, which meant asking about "uncommitted changes" showed
                        // a `git log -1` chip because the string contained "commit" — the chip
                        // described the question, not the work.
                        //
                        // An empty row now says so explicitly: nothing reads as "no detail"
                        // when it should read as "nothing happened".
                        aiMode.pendingToolChips = memoryToolChips + executed.map(\.command)
                            + (AgentAnswerVerifier.noActionChip(executed: executed).map { [$0] } ?? [])
                        aiMode.pendingEvidenceReceipts = executed.map(EvidenceReceipt.init)
                        aiMode.pendingSubjectiveEvaluation = subjectiveEvaluation
                    }
                    return finalResponse
                }

                var loopHistory = history
                var loopQuery = query
                var toolChips: [String] = memoryToolChips
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
        let answer = try await AIOrchestrationEngine.shared.submit(
            AIOrchestrationRequest(
                providerRequest: request,
                scope: currentAISelectionSnapshot.isEmpty
                    ? .general : .selection(currentAISelectionSnapshot),
                policy: .generalChat,
                providerSelection: providerSelection,
                contextPrompt: sysContent
            )
        ).text
        await MainActor.run { aiMode.pendingToolChips = memoryToolChips }
        return answer
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

        guard let match = bestMenuMatch(
            intent: query,
            bundleId: bundleId,
            appName: appName,
            processIdentifier: app.processIdentifier
        ) else {
            // A configured integration remains preferable to weak menu suggestions. A CLI
            // never suppresses an exact native menu, but it may handle requests for which the
            // app exposes no matching menu at all.
            if !matchingActions.isEmpty || matchingMCP || !matchingCLI.isEmpty { return nil }
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

        // A saved adapter action is a user-authored workflow and wins over a menu with a
        // coincidental text match. Otherwise the live, enabled native command is the most
        // faithful implementation of an app-UI request. In particular, Notes' built-in MCP
        // exports Markdown data, while File → Export To → PDF is the correct visible PDF flow.
        if !matchingActions.isEmpty { return nil }
        let result = await AppAdapterManager.shared.runMenuPath(
            match.path, targetBundleId: bundleId, appName: appName)
        if result.0 {
            return "Done — used **\(path)**\(shortcutHint)."
        }
        return result.1.isEmpty
            ? "I found **\(path)**, but \(appName) did not confirm the command. Nothing was reported as completed."
            : result.1
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
                Prefer, in order: exact saved adapter action; verified app menu for visible UI commands; MCP/API for app data; macOS Shortcut; linked CLI fallback.
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
