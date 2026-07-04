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

extension LauncherView {
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
        lines.append(
            actions.isEmpty
                ? "- Actions: none"
                : "- Actions: " + actions.prefix(10).map(\.name).joined(separator: ", "))
        lines.append(
            clis.isEmpty
                ? "- CLI tools: none linked"
                : "- CLI tools (run via CMD: lines): "
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
        lines.append("")
        lines.append(
            "Tool choice order: MCP tool → linked CLI (CMD:) → adapter action → answer from "
            + "the live context. If no linked integration can do what the user asks, say what "
            + "IS possible now and suggest linking the right tool in Settings → App Adapters → "
            + "\(appName) (Tools tab: CLI, MCP, API, Shortcuts).")
        return lines.joined(separator: "\n")
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
            lockedFindToken == nil
        else { return false }

        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !shouldUseFinderSearchPopover(for: q) else { return false }
        if !finderSemanticResults.isEmpty { return false }

        let finderSearchPopoverActive = shouldUseFinderSearchPopover(for: q)
        let pillQuery = finderSearchPopoverActive ? "" : q
        let pills = currentVisibleDockPills(for: pillQuery)
        return !pills.contains { !$0.isSeparator }
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
        let existingName = l2.chatDraftAppName.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingBundleId = l2.chatDraftBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        if (l2.chatArmed || l2.showChatPopover || !l2.chatMessages.isEmpty),
            !existingName.isEmpty,
            !existingBundleId.isEmpty
        {
            l2.chatArmed = true
            l2.chatDismissed = false
            requestWindowSizeUpdate(reason: .panelChanged, animated: animated)
            return
        }
        let scopedName = l2.targetApp?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let scopedBundleId = l2.targetApp?.bundleId.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackName = frontmost.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackBundleId = frontmost.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        l2.chatArmed = true
        l2.chatDismissed = false
        l2.chatDraftAppName = scopedName.isEmpty ? fallbackName : scopedName
        l2.chatDraftBundleId = scopedBundleId.isEmpty ? fallbackBundleId : scopedBundleId
        requestWindowSizeUpdate(reason: .panelChanged, animated: animated)
    }

    func disarmContextDockChat() {
        l2.showChatPopover = false
        l2.chatArmed = false
        l2.chatDismissed = true
        l2.chatDraftAppName = ""
        l2.chatDraftBundleId = ""
        requestWindowSizeUpdate(reason: .panelChanged)
    }

    func exitContextDockChatSheet() {
        if let key = l2.activeDockSessionKey {
            AppPanelChatStore.shared.save(l2.chatMessages, for: key)
        }
        l2.showChatPopover = false
        l2.chatArmed = false
        l2.chatDismissed = true
        l2.chatDraftAppName = ""
        l2.chatDraftBundleId = ""
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
        let chatApp = l2.chatDraftBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        let frontApp = frontmost.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let boundToFrontmost =
            !frontApp.isEmpty
            && l2.targetApp == nil
            && (chatApp.isEmpty || chatApp == frontApp)
        if boundToFrontmost {
            exitContextDockChatSheet()
            // Force the frontmost app's Context Dock, not Global Context.
            globalContextActivation = nil
            showContextInDock = true
            scheduleDockPillRebuild(query: "", delayNanoseconds: 0, refreshContext: true)
        } else {
            exitContextDockChatAndScope()
        }
    }

    func exitContextDockChatAndScope() {
        exitContextDockChatSheet()
        clearSearchContext()
        remPanelIsProcessing = false
        remIsInstalled = nil
        systemDataResults = []
        searchState.lastSmartQuery = ""
        globalContextActivation = GlobalContextActivation(autoActivated: false)
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

    /// Trailing pin toggle (replaces the old duplicate "−" close button — the scope
    /// chip's "−" already exits the chat). Pinned = launcher floats over every app
    /// and never auto-hides until unpinned.
    var contextDockChatCloseButton: some View {
        Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
                settings.launcherPinned.toggle()
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
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Chat with \(contextDockChatTitle(appName: scopedTarget.name, bundleId: scopedTarget.bundleId))")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text(contextDockChatUsingSummary(
                                    bundleId: scopedTarget.bundleId, appName: scopedTarget.name))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        Spacer()
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                l2.chatMessages = []
                                if let key = l2.activeDockSessionKey {
                                    AppPanelChatStore.shared.clear(for: key)
                                }
                                l2.isLoading = false
                                l2.activeRequestID = nil
                                l2.currentTask?.cancel()
                                l2.currentTask = nil
                                updateL2Results([])
                            }
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
                                exitContextDockChatAndScope()
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
                                            onRunOnceProposal: { json in runOnceFromProposal(json) }
                                        )
                                        .id(message.id)
                                    } else {
                                        AIChatMessageView(message: message)
                                            .id(message.id)
                                    }
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
                                    AILoadingView().id("l2loading")
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
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
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
                        ForEach(aiMode.messages) { message in
                            AIChatMessageView(
                                message: message,
                                isStreaming: message.id == aiMode.streamingId
                            )
                            .id(message.id)
                        }
                        if aiMode.isLoading {
                            HStack(spacing: 8) {
                                AILoadingView()
                                if let status = aiMode.loadingStatus {
                                    Text(status)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .transition(.opacity)
                                        .id(status)
                                }
                                Spacer()
                            }
                            .animation(.easeInOut(duration: 0.18), value: aiMode.loadingStatus)
                            .padding(.horizontal, 4)
                            .id("loading")
                        }
                        if let pending = aiMode.pendingShare {
                            selectionShareConfirmCard(pending)
                                .id("pending-share")
                        }
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
    func submitAIQuery() {
        let query = searchState.query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        guard !aiMode.isLoading && aiMode.streamingId == nil else { return }

        print(
            "🤖 [AI] Submitting query: \"\(query.prefix(60))\" | provider: \(settings.selectedAIProvider.shortName)"
        )

        hasUserSentMessageInCurrentSession = true

        let pendingAttachments = aiMode.attachments

        withAnimation {
            aiMode.messages.append(
                AIChatMessage(role: .user, content: query, attachments: pendingAttachments))
        }
        searchState.query = ""

        aiMode.attachments = []

        aiMode.isLoading = true
        aiMode.currentTask?.cancel()

        // Every provider, including on-device, uses the same context-aware router pipeline.
        aiMode.currentTask = Task {
            do {
                let response: String
                response = try await sendToAIProvider(
                    query: query,
                    attachments: pendingAttachments
                )
                let launches = self.referencedAppLaunches(for: query)
                // SHARE_VIA directive → send the AI result (+ any selected files) through the
                // native Share service. Strip the directive line from the visible message.
                let shareDest = self.parseShareViaDirective(response)
                let cleaned = self.stripShareViaDirective(response)
                await MainActor.run {
                    withAnimation {
                        self.aiMode.messages.append(
                            AIChatMessage(
                                role: .assistant, content: cleaned, appLaunches: launches,
                                mcpToolsRan: self.aiMode.pendingToolChips))
                        self.aiMode.pendingToolChips = []
                        self.aiMode.loadingStatus = nil
                        self.aiMode.isLoading = false
                    }
                    // Two-step: don't send yet — show a confirm card so the user approves the
                    // destination first.
                    if let shareDest {
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
                    self.requestWindowSizeUpdate(reason: .chatChanged)
                }
            }
        }
    }

    /// Extract `SHARE_VIA: <dest>` from an AI reply (the model emits it when the user asked to
    /// send/share the result). Returns the destination name, or nil.
    func parseShareViaDirective(_ response: String) -> String? {
        guard let range = response.range(of: "SHARE_VIA:") else { return nil }
        let tail = response[range.upperBound...]
            .prefix(while: { $0 != "\n" })
            .trimmingCharacters(in: CharacterSet(charactersIn: " .<>"))
        return tail.isEmpty ? nil : tail
    }

    func stripShareViaDirective(_ response: String) -> String {
        response
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("SHARE_VIA:") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
            "IMPORTANT: When the user's request warrants running one or more CLI commands, output each exact ready-to-run command on its own line prefixed with CMD: (example: CMD: pear list-orphaned). Do not put CMD: lines inside code blocks. Emit only real actionable commands the user should approve and run, never informational examples."
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
            let result = await TerminalAIBridge.shared.processAICommand(command, purpose: purpose)
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

    /// Scans AI response for `CMD: <command>` lines, strips them from the displayed message,
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
            if trimmed.hasPrefix("CMD:") {
                let cmd = String(trimmed.dropFirst(4)).trimmingCharacters(
                    in: .whitespacesAndNewlines)
                if !cmd.isEmpty {
                    extractedCmds.append((cmd, lastNonCmdLine))
                }
            } else {
                cleanedLines.append(line)
                if !trimmed.isEmpty { lastNonCmdLine = trimmed }
            }
        }

        guard !extractedCmds.isEmpty else { return }

        // Strip CMD: lines from the displayed message; keep explanation if any
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
        l2.currentTask = nil
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
                let result = await TerminalAIBridge.shared.processAICommand(
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
        // Global context + live selection or clipboard → query is about the content; skip app routing
        let globalSelectionActive =
            dockScope.isGlobalScope
            && hasSelectionScopeSurface

        // Does the user have meaningful selected content to talk about?
        let hasActiveSelection = activeSelection != nil

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
                    let (success, output) = await TerminalAIBridge.shared.processAICommand(
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

        // When no CLI tools are configured for the scoped app, offer to auto-create an extension.
        let proposalAppendix: String = {
            guard !dockScope.isGlobalScope, dockCLIContextPrompt.isEmpty else { return "" }
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
            let liveURL = axContext.currentURL ?? frontmost.bundleID
            if case .url = currentContext { /* already set */
            } else {
                currentContext = .url(liveURL)
            }
            // Prime the AXWebReader cache for on-device AI if needed
            if let browser = AppDelegate.shared?.previousFrontmostApp, !liveURL.isEmpty {
                let pid = browser.processIdentifier
                if AXWebReader.shared.cachedSnapshot(for: pid)?.text.isEmpty != false {
                    Task { @MainActor in
                        AXWebReader.shared.refresh(pid: pid, currentURL: liveURL)
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

                let runtimeCLIContextPrompt = await self.runtimeAppCLIContextPrompt(
                    bundleId: scopedBundleId,
                    appName: scopedAppName.isEmpty ? (frontmostName ?? frontmost.name) : scopedAppName,
                    query: query
                )
                // Real Apple-apps data + weather, so Context Dock chat answers these like
                // General Chat does (alongside its menu/AX/terminal-tool capabilities).
                let appleData = await self.appleAppsAndWeatherContext(for: query)
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
                let activeContextPrompt = [
                    identityBlock, finalContextPrompt, runtimeCLIContextPrompt, appleData,
                    mcpBlock, browserPageBlock, skillsBlock,
                ]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")

                if provider != .onDevice && provider != .shortcuts {
                    // Collects MCP tools the model invokes via the tool loop, for the chip.
                    let mcpRan = MCPRunCollector()
                    let commandExecutor: (String, String) async -> (Bool, String) = {
                        command, purpose in
                        // The model often wraps an mcp_call inside a TERMINAL_COMMAND tag — route
                        // it to the MCP server instead of running it as a shell command (which
                        // would open Safari / do the wrong thing).
                        if let call = self.parseMCPCall(from: command) {
                            let result = (try? await MCPRuntime.shared.callTool(
                                bundleId: scopedBundleId, server: call.server, tool: call.tool,
                                arguments: call.arguments)) ?? "MCP tool failed"
                            await mcpRan.add(
                                "\(call.tool) via \(call.server.isEmpty ? "MCP" : call.server)")
                            return (true, result)
                        }
                        return await TerminalAIBridge.shared.processAICommand(
                            command, purpose: purpose)
                    }
                    let toolQuery = activeContextPrompt.isEmpty
                        ? query
                        : "\(activeContextPrompt)\n\nUser request: \(query)"
                    var (finalResponse, _) = try await AIProviderService.shared.sendWithTools(
                        toolQuery,
                        context: scopedConversationContext,
                        provider: provider,
                        apiKey: apiKey,
                        conversationHistory: chatHistory,
                        commandExecutor: commandExecutor,
                        additionalSystemPrompt: activeContextPrompt.isEmpty ? nil : activeContextPrompt
                    )
                    if Task.isCancelled {
                        await MainActor.run { finishL2AIRequest(l2RequestID) }
                        return
                    }
                    var toolsRan = await mcpRan.tools
                    // Fallback: model emitted a raw mcp_call as its final text (not via the loop).
                    if let resolved = await self.resolveMCPToolCall(
                        in: finalResponse, bundleId: scopedBundleId, userQuery: query,
                        provider: provider, apiKey: apiKey, history: chatHistory,
                        systemPrompt: activeContextPrompt)
                    {
                        finalResponse = resolved.answer
                        toolsRan += resolved.toolsRan
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
                                cont.resume()
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
                                cont.resume()
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
                        systemPrompt: activeContextPrompt)
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
                        await MainActor.run {
                            var msg = AIChatMessage(
                                role: .assistant,
                                content: reply.trimmingCharacters(in: .whitespacesAndNewlines)
                                    .isEmpty ? "The Shortcut returned no output." : reply)
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

        if ["reminder", "task", "todo", "to-do", "to do", "due"].contains(where: q.contains) {
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
            // Use the longest capitalized token as the name to search.
            let nameGuess = query.split(separator: " ").map(String.init)
                .filter { $0.first?.isUppercase ?? false }
                .max(by: { $0.count < $1.count }) ?? ""
            let contacts: [[String: Any]] = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let result =
                        nameGuess.isEmpty
                        ? api.getContacts(limit: 20)
                        : api.searchContacts(query: nameGuess)
                    continuation.resume(returning: result)
                }
            }
            if !contacts.isEmpty {
                let lines = contacts.prefix(10).map { c -> String in
                    let name = (c["fullName"] as? String)?.trimmingCharacters(
                        in: .whitespaces) ?? ""
                    let phone = (c["phone"] as? String) ?? ""
                    let email = (c["email"] as? String) ?? ""
                    var parts = [name.isEmpty ? "(no name)" : name]
                    if !phone.isEmpty { parts.append("📞 \(phone)") }
                    if !email.isEmpty { parts.append("✉️ \(email)") }
                    return "- " + parts.joined(separator: " — ")
                }.joined(separator: "\n")
                blocks.append("## Contacts — matches:\n\(lines)")
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
        provider: AIProvider, apiKey: String?, history: [ChatMessage], systemPrompt: String
    ) async -> (answer: String, toolsRan: [String])? {
        guard parseMCPCall(from: response) != nil else { return nil }

        let maxSteps = 5
        var transcript = history
        var current = response
        var toolsRan: [String] = []

        for _ in 0..<maxSteps {
            guard let call = parseMCPCall(from: current) else {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : (answer: trimmed, toolsRan: toolsRan)
            }
            let result: String
            do {
                result = try await MCPRuntime.shared.callTool(
                    bundleId: bundleId, server: call.server, tool: call.tool,
                    arguments: call.arguments)
            } catch {
                return (
                    answer: "MCP tool “\(call.tool)” failed: \(error.localizedDescription)",
                    toolsRan: toolsRan)
            }
            toolsRan.append("\(call.tool) via \(call.server.isEmpty ? "MCP" : call.server)")
            transcript.append(ChatMessage(role: .assistant, content: current))
            let followup =
                "Tool \"\(call.tool)\" returned:\n\(result)\n\n"
                + "If you need another MCP tool, reply with the same single-line JSON. "
                + "Otherwise answer the user's request in plain language: \(userQuery)"
            transcript.append(ChatMessage(role: .user, content: followup))
            let next = (try? await AIProviderService.shared.sendWithTools(
                followup, context: .none, provider: provider, apiKey: apiKey,
                conversationHistory: transcript,
                commandExecutor: { _, _ in (false, "") },
                additionalSystemPrompt: systemPrompt.isEmpty ? nil : systemPrompt
            ))?.finalResponse ?? ""
            if next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (answer: "MCP tool “\(call.tool)” result:\n\(result)", toolsRan: toolsRan)
            }
            current = next
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : (answer: trimmed, toolsRan: toolsRan)
    }

    /// Parse a `{"mcp_call": {"server","tool","arguments"}}` directive out of an AI reply —
    /// even when the model wraps it in a ```json fence or a [TERMINAL_COMMAND: …] tag. Finds
    /// the balanced JSON object that encloses the "mcp_call" key.
    func parseMCPCall(from response: String)
        -> (server: String, tool: String, arguments: [String: Any])?
    {
        guard let keyRange = response.range(of: "\"mcp_call\"") else { return nil }
        // Nearest '{' before the key opens the wrapper object.
        guard let open = response[..<keyRange.lowerBound].lastIndex(of: "{") else { return nil }
        // Balance-match to its closing '}'.
        var depth = 0
        var end: String.Index?
        var i = open
        while i < response.endIndex {
            switch response[i] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { end = response.index(after: i) }
            default: break
            }
            if end != nil { break }
            i = response.index(after: i)
        }
        guard let endIdx = end else { return nil }
        let slice = String(response[open..<endIdx])
        guard let data = slice.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let call = root["mcp_call"] as? [String: Any],
            let tool = call["tool"] as? String
        else { return nil }
        let server = (call["server"] as? String) ?? ""
        let args = (call["arguments"] as? [String: Any]) ?? [:]
        return (server: server, tool: tool, arguments: args)
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
        add(["reminder", "task", "todo", "to-do", "to do", "due"],
            "Open Reminders", "checklist", "com.apple.reminders")
        add(["contact", "phone number", "email of", "number of", "call ", "phone of"],
            "Open Contacts", "person.crop.circle", "com.apple.AddressBook")
        add(["photo", "picture", "screenshot"], "Open Photos", "photo", "com.apple.Photos")
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

    func sendToAIProvider(query: String, attachments: [URL] = []) async throws -> String {
        // Build context from previous messages (uses aiMode.messages for global AI mode)
        let history = aiMode.messages.map { msg in
            ChatMessage(
                role: msg.role == .user ? .user : .assistant,
                content: msg.content
            )
        }

        // Lightweight system message for standalone AI chat — no menu/AX overhead
        var sysContent = """
            You are a helpful AI assistant. Provide concise, accurate answers.
            Keep responses brief and to the point.
            This is General Chat mode. Do not use frontmost app, browser page, Finder selection, menu commands, or Context Dock scope unless the user explicitly attached that item in this chat. However, when the user asks about one of their apps and an App Tools section is provided below, use those tools to answer.
            \(currentDateTimeContextBlock())
            """
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

        if let mcpAnswer = try await directGeneralAppMCPAnswer(
            query: query,
            history: history,
            baseSystemPrompt: sysContent
        ) {
            return mcpAnswer
        }

        // Inject real Apple-apps data + live weather when the query is about them.
        let appleData = await appleAppsAndWeatherContext(for: query)
        if !appleData.isEmpty {
            sysContent += "\n\n" + appleData
        }

        // Selection Scope: ground the whole conversation in the user's current selection
        // (text / page URL / files) so every turn answers about their actual content.
        if let selText = aiMode.selectionText, !selText.isEmpty {
            sysContent +=
                "\n\nThe user is working with this SELECTED CONTENT — base your answers on it:\n"
                + "\"\"\"\n\(String(selText.prefix(8000)))\n\"\"\""
        }
        if let pageURL = aiMode.selectionURL, !pageURL.isEmpty {
            sysContent += "\n\nThe selection is from this page: \(pageURL)"
        }
        if !aiMode.selectionFiles.isEmpty {
            let analyzed = ContextDetector.shared.analyzeFiles(aiMode.selectionFiles)
            let blocks = analyzed.compactMap { item -> String? in
                guard let c = item.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !c.isEmpty
                else { return nil }
                return "### \(item.url.lastPathComponent) (\(item.type))\n\(c)"
            }
            if !blocks.isEmpty {
                sysContent +=
                    "\n\nSelected file contents — use these:\n\n" + blocks.joined(separator: "\n\n")
            }
        }
        // The model can send results through macOS Share (Mail/Messages/Notes/…) — when the
        // user asks to send/share/email, finish with: SHARE_VIA: <destination>.
        if aiMode.selectionText != nil || !aiMode.selectionFiles.isEmpty {
            sysContent +=
                "\n\nIf the user asks to send/share/email/message the result (e.g. \"summarize this"
                + " and send to mail\"), produce the content, then append a final line exactly:"
                + " SHARE_VIA: <Mail|Messages|Notes|Reminders|AirDrop|Freeform>."
        }

        // Agentic path: give General Chat the same tool power Context Dock chat has, but with
        // a CROSS-APP catalog — every enabled adapter's MCP tools plus saved app-scoped chat
        // histories. Uses the JSON tool-call protocol via plain sendPrepared, so it works for
        // EVERY provider including on-device Apple Intelligence (which has no native function
        // calling). Attachments stay on the plain path so vision payloads keep flowing.
        let toolProvider = settings.selectedAIProvider
        if attachments.isEmpty, toolProvider != .shortcuts {
            await MainActor.run { aiMode.loadingStatus = "Checking app tools…" }
            let appToolsBlock = await GeneralChatCapabilityHub.shared.capabilityPromptBlock(
                compact: toolProvider == .onDevice)
            if !appToolsBlock.isEmpty {
                let toolSystemPrompt = sysContent + "\n\n" + appToolsBlock
                var loopHistory = history
                var loopQuery = query
                var toolChips: [String] = []
                for _ in 0..<4 {
                    await MainActor.run {
                        aiMode.loadingStatus = toolChips.isEmpty
                            ? "Thinking…" : "Reading tool result…"
                    }
                    let loopRequest = AIRequestBuilder.aiChat(text: loopQuery, history: loopHistory)
                    let response = try await AIProviderRouter.shared.sendPrepared(
                        request: loopRequest,
                        provider: toolProvider,
                        contextPrompt: toolSystemPrompt
                    )
                    // Tool call? Execute, feed the result back, and go around again.
                    await MainActor.run { aiMode.loadingStatus = "Checking for tool calls…" }
                    let call = await GeneralChatCapabilityHub.shared.execute(response)
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
                    loopQuery = """
                    Tool result (\(call.label))\(call.success ? "" : " — FAILED"):
                    \(String(call.output.prefix(8_000)))

                    Using this result, answer the user's original question: "\(query)"
                    If the user asks "how many", count the returned items. If you still need \
                    another tool, reply with ONLY the tool-call JSON again.
                    """
                }
                // Loop budget exhausted — one final forced plain answer.
                await MainActor.run { aiMode.loadingStatus = "Writing answer…" }
                let finalRequest = AIRequestBuilder.aiChat(
                    text: loopQuery + "\n\nAnswer in plain language now. Do NOT call any more tools.",
                    history: loopHistory
                )
                let finalAnswer = try await AIProviderRouter.shared.sendPrepared(
                    request: finalRequest,
                    provider: toolProvider,
                    contextPrompt: toolSystemPrompt
                )
                await MainActor.run {
                    aiMode.loadingStatus = nil
                    aiMode.pendingToolChips = toolChips
                }
                return finalAnswer
            }
            await MainActor.run { aiMode.loadingStatus = nil }
        }

        let request = AIRequestBuilder.aiChat(
            text: query,
            history: history,
            attachments: attachments
        )
        return try await AIProviderRouter.shared.sendPrepared(
            request: request,
            provider: settings.selectedAIProvider,
            contextPrompt: sysContent
        )
    }

    func directGeneralAppMCPAnswer(
        query: String,
        history: [ChatMessage],
        baseSystemPrompt: String
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
        let toolResult = try await MCPRuntime.shared.callTool(
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
        let request = AIRequestBuilder.aiChat(
            text: query,
            history: history
        )
        return try await AIProviderRouter.shared.sendPrepared(
            request: request,
            provider: settings.selectedAIProvider,
            contextPrompt: prompt
        )
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
            let prefixes = ["notes.", "calendar.", "contacts.", "reminders.", "github."]
            let caps = CapabilityRegistry.shared.all.filter { cap in
                prefixes.contains(where: cap.id.hasPrefix)
            }
            guard !caps.isEmpty else { return "" }
            var lines = [
                "## Built-in App Tools",
                "You can also call these built-in tools with the same single-line JSON format, using server \"builtin\":",
                "{\"mcp_call\": {\"server\": \"builtin\", \"tool\": \"<tool id>\", \"arguments\": { … }}}",
                "",
                "Available built-in tools:",
            ]
            for cap in caps {
                let fields = cap.inputSchema.fields.map { f in
                    "\(f.name)\(f.required ? "" : "?")"
                }.joined(separator: ", ")
                lines.append("- \(cap.id): \(cap.title) | input: [\(fields)]")
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
        let input = arguments.mapValues { value -> String in
            if let s = value as? String { return s }
            return "\(value)"
        }
        let plan = AIActionPlan(
            capability: tool, input: input, explanation: "Requested from AI chat"
        )
        do {
            let result = try await AIExecutionEngine.shared.executeWithApproval(
                plan, context: .none
            )
            return result.output
        } catch {
            return "Tool \(tool) failed: \(error.localizedDescription)"
        }
    }

    /// Like `resolveMCPToolCall` but dispatches globally (no bundleId scope).
    func resolveMCPToolCallGlobally(
        in response: String, userQuery: String,
        provider: AIProvider, apiKey: String?, history: [ChatMessage], systemPrompt: String
    ) async -> (answer: String, toolsRan: [String])? {
        guard parseMCPCall(from: response) != nil else { return nil }
        let maxSteps = 5
        var transcript = history
        var current = response
        var toolsRan: [String] = []
        for _ in 0..<maxSteps {
            guard let call = parseMCPCall(from: current) else {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : (answer: trimmed, toolsRan: toolsRan)
            }
            let result: String
            if let builtinOutput = await executeBuiltInCapability(
                tool: call.tool, arguments: call.arguments)
            {
                result = builtinOutput
                toolsRan.append("\(call.tool) via built-in")
            } else {
                do {
                    result = try await MCPRuntime.shared.callToolGlobally(
                        server: call.server, tool: call.tool, arguments: call.arguments)
                } catch {
                    return (
                        answer: "MCP tool “\(call.tool)” failed: \(error.localizedDescription)",
                        toolsRan: toolsRan)
                }
                toolsRan.append("\(call.tool) via \(call.server.isEmpty ? "MCP" : call.server)")
            }
            transcript.append(ChatMessage(role: .assistant, content: current))
            let followup =
                "Tool \"\(call.tool)\" returned:\n\(result)\n\n"
                + "If you need another tool, reply with the same single-line JSON. "
                + "Otherwise answer the user's request in plain language: \(userQuery)"
            transcript.append(ChatMessage(role: .user, content: followup))
            let next = (try? await AIProviderService.shared.sendWithTools(
                followup, context: .none, provider: provider, apiKey: apiKey,
                conversationHistory: transcript,
                commandExecutor: { _, _ in (false, "") },
                systemPromptOverride: systemPrompt.isEmpty ? nil : systemPrompt
            ))?.finalResponse ?? ""
            if next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (answer: "MCP tool “\(call.tool)” result:\n\(result)", toolsRan: toolsRan)
            }
            current = next
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : (answer: trimmed, toolsRan: toolsRan)
    }

    func sendToAIProviderWithContext(query: String, messageHistory: [AIChatMessage])
        async throws -> String
    {
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
        let isCloudProvider = settings.selectedAIProvider != .onDevice
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

        return try await sendToProvider(query: query, context: context, imageFiles: imageFiles)
    }

    // Direct provider sender that accepts pre-built context (used by L2 for custom prompts)
    // Common provider router
    func sendToProvider(query: String, context: [[String: String]]) async throws -> String {
        return try await sendToProvider(query: query, context: context, imageFiles: [])
    }

    // Common provider router with image support
    func sendToProvider(query: String, context: [[String: String]], imageFiles: [URL])
        async throws -> String
    {
        var systemPrompt = context
            .filter { $0["role"] == "system" }
            .compactMap { $0["content"] }
            .joined(separator: "\n\n")
        // Context Dock chat answers with real Apple-apps data + weather too (same as General
        // Chat), on top of its menu/AX/terminal-tool capabilities.
        let appleData = await appleAppsAndWeatherContext(for: query)
        if !appleData.isEmpty {
            systemPrompt += "\n\n" + appleData
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
        let capabilityPlanningRequested = [
            "run ", "execute ", "rename ", "reveal ", "open ", "close ",
            "summarize this page", "create ", "delete ", "update ", "send ",
            "compose ", "call ", "use ", "do "
        ].contains { lowerQuery.contains($0) }
        let planningBundleID = isGlobalQueryModeActive
            ? nil
            : (l2.targetApp?.bundleId ?? AXContextReader.shared.current.bundleId)
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
        let response = try await AIProviderRouter.shared.sendPrepared(
            request: request,
            provider: settings.selectedAIProvider,
            contextPrompt: systemPrompt
        )
        guard capabilityPlanningRequested else { return response }
        do {
            let plan = try AIResponseParser.shared.parseActionPlan(response)
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
                provider: settings.selectedAIProvider
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
