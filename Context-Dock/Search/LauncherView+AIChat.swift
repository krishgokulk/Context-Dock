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

    var shouldShowContextDockChatSheet: Bool {
        showContextInDock
            && !showMediaLayer
            && (l2.showChatPopover || l2.isLoading || !l2.chatMessages.isEmpty)
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

    func armContextDockChat() {
        let existingName = l2.chatDraftAppName.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingBundleId = l2.chatDraftBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        if (l2.chatArmed || l2.showChatPopover || !l2.chatMessages.isEmpty),
            !existingName.isEmpty,
            !existingBundleId.isEmpty
        {
            l2.chatArmed = true
            updateWindowSize()
            return
        }
        let scopedName = l2.targetApp?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let scopedBundleId = l2.targetApp?.bundleId.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackName = frontmost.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackBundleId = frontmost.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        l2.chatArmed = true
        l2.chatDraftAppName = scopedName.isEmpty ? fallbackName : scopedName
        l2.chatDraftBundleId = scopedBundleId.isEmpty ? fallbackBundleId : scopedBundleId
        updateWindowSize()
    }

    func disarmContextDockChat() {
        l2.showChatPopover = false
        l2.chatArmed = false
        l2.chatDraftAppName = ""
        l2.chatDraftBundleId = ""
        updateWindowSize()
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

    var contextDockChatCloseButton: some View {
        Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
                disarmContextDockChat()
            }
            isSearchFieldFocused = true
        } label: {
            Image(systemName: "minus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary.opacity(0.70))
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(0.07), in: Circle())
        }
        .buttonStyle(.plain)
        .help("Close AI conversation")
    }

    func toggleInlineAIChatPanel() {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
            if l2.showChatPopover {
                disarmContextDockChat()
            } else {
                if l2.chatArmed {
                    disarmContextDockChat()
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
                            AppBundleIconView(
                                bundleId: scopedTarget.bundleId,
                                fallbackSymbol: "bubble.left.and.text.bubble.right",
                                size: 20, cornerRadius: 5
                            )
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Chat with \(scopedTarget.name)")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
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
                            Button("Exit Scope") { clearSearchContext() }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                        }
                    }
                    .padding(.horizontal, 14)
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
                        }
                        .frame(maxHeight: 460)
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
                            HStack {
                                AILoadingView()
                                Spacer()
                            }
                            .padding(.horizontal, 4)
                            .id("loading")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                }
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

        withAnimation {
            aiMode.messages.append(AIChatMessage(role: .user, content: query))
        }
        searchState.query = ""

        let pendingAttachments = aiMode.attachments
        aiMode.attachments = []

        aiMode.isLoading = true
        aiMode.currentTask?.cancel()

        // Every provider, including on-device, uses the same context-aware router pipeline.
        aiMode.currentTask = Task {
            do {
                let response: String
                if !pendingAttachments.isEmpty {
                    let history = self.aiMode.messages.map { msg in
                        [
                            "role": msg.role == .user ? "user" : "assistant",
                            "content": msg.content,
                        ]
                    }
                    let systemMsg: [String: String] = [
                        "role": "system", "content": "You are a helpful AI assistant.",
                    ]
                    let imageFiles = pendingAttachments.filter {
                        ["jpg", "jpeg", "png", "gif", "heic", "webp"].contains(
                            $0.pathExtension.lowercased())
                    }
                    response = try await sendToProvider(
                        query: query, context: [systemMsg] + history, imageFiles: imageFiles)
                } else {
                    response = try await sendToAIProvider(query: query)
                }
                await MainActor.run {
                    withAnimation {
                        self.aiMode.messages.append(
                            AIChatMessage(role: .assistant, content: response))
                        self.aiMode.isLoading = false
                    }
                    self.updateWindowSize()
                }
            } catch {
                await MainActor.run {
                    withAnimation {
                        self.aiMode.messages.append(
                            AIChatMessage(
                                role: .assistant,
                                content: "Error: \(error.localizedDescription)",
                                isError: true))
                        self.aiMode.isLoading = false
                    }
                    self.updateWindowSize()
                }
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
        return lines.joined(separator: "\n")
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

        guard let (bestRule, _) = candidates.first else { return false }

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

        // Conditions didn't pass — tell the user what context is needed.
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

    func handleL2Query(_ query: String, skipMenuRouter: Bool) {
        guard !query.isEmpty else { return }
        let wasContextDockChatActive = l2.chatArmed || l2.showChatPopover || !l2.chatMessages.isEmpty
        armContextDockChat()
        l2.showChatPopover = true
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
            && (activeSelection != nil || (showGlobalClipboardPill && !globalClipboardText.isEmpty))

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
            updateWindowSize()
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
            if case .filesSelected(let urls) = effectiveConversationUserContext {
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
            case .filesSelected(let urls) = effectiveConversationUserContext,
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
                await executeL2Extension(top.ilExtension, context: effectiveConversationUserContext)
                await MainActor.run { finishL2AIRequest(l2RequestID) }
            }
            return
        }

        if matches.isEmpty { updateL2Results([]) }

        // ── Ensure browser context is set correctly for Safari / Chrome ──────
        // If frontmost app is a browser but currentContext isn't .url yet, fix it now.
        let browserBundles = [
            "com.apple.Safari", "com.google.Chrome", "com.brave.Browser",
            "org.chromium.Chromium", "com.microsoft.edgemac",
        ]
        let shouldUseFrontmostBrowserContext =
            !isExplicitScopedApp || browserBundles.contains(scopedBundleId)
        if shouldUseFrontmostBrowserContext,
            !dockScope.isGlobalScope,
            browserBundles.contains(frontmost.bundleID)
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
        if !shouldStayInScopedAIChat,
            frontmost.bundleID == "com.apple.Safari"
            || SafariBrowserBridge.shared.safariContextIfFresh() != nil,
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

                if provider != .onDevice && provider != .shortcuts {
                    let commandExecutor: (String, String) async -> (Bool, String) = { command, purpose in
                        await TerminalAIBridge.shared.processAICommand(command, purpose: purpose)
                    }
                    let toolQuery = finalContextPrompt.isEmpty
                        ? query
                        : "\(finalContextPrompt)\n\nUser request: \(query)"
                    let (finalResponse, _) = try await AIProviderService.shared.sendWithTools(
                        toolQuery,
                        context: effectiveConversationUserContext,
                        provider: provider,
                        apiKey: apiKey,
                        conversationHistory: chatHistory,
                        commandExecutor: commandExecutor,
                        additionalSystemPrompt: finalContextPrompt.isEmpty ? nil : finalContextPrompt
                    )
                    if Task.isCancelled {
                        await MainActor.run { finishL2AIRequest(l2RequestID) }
                        return
                    }
                    await MainActor.run {
                        var msg = AIChatMessage(role: .assistant, content: finalResponse)
                        msg = self.tagMessageWithProposal(msg)
                        l2.chatMessages.append(msg)
                        if !finalContextPrompt.isEmpty {
                            extractAndInsertDockApprovalCards(
                                from: msg.content, intoMessageAt: msg.id)
                        }
                        finishL2AIRequest(l2RequestID)
                    }
                    // Dispatch any Safari browser control tags embedded in the response
                    if case .safariCommand(let cmd) = parseL2AIResponse(finalResponse) {
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
                        if isExplicitScopedApp && !scopedBundleId.isEmpty {
                            return .appFocused(name: scopedAppName, bundleID: scopedBundleId)
                        }
                        return effectiveConversationUserContext
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
                            additionalContextPrompt: finalContextPrompt,
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
                                        if !finalContextPrompt.isEmpty {
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
                    await MainActor.run {
                        finishL2AIRequest(l2RequestID)
                    }
                } else {
                    await MainActor.run {
                        l2.chatMessages.append(
                            AIChatMessage(
                                role: .assistant,
                                content:
                                    "This AI provider is not supported in L2 mode. Please select OpenAI, Anthropic, Gemini, Ollama, or On-Device in Settings.",
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

    func sendToAIProvider(query: String) async throws -> String {
        // Build context from previous messages (uses aiMode.messages for global AI mode)
        var context = aiMode.messages.map { msg in
            ["role": msg.role == .user ? "user" : "assistant", "content": msg.content]
        }

        // Lightweight system message for standalone AI chat — no menu/AX overhead
        let sysContent = """
            You are a helpful AI assistant. Provide concise, accurate answers.
            Keep responses brief and to the point.
            \(currentDateTimeContextBlock())
            """
        let systemMessage: [String: String] = ["role": "system", "content": sysContent]

        // Insert system message at the beginning
        context.insert(systemMessage, at: 0)

        return try await sendToProvider(query: query, context: context)
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
        let axL2 = effectiveAXContextForConversation()
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
            || SafariBrowserBridge.shared.safariContextIfFresh() != nil
        let isCloudProvider = settings.selectedAIProvider != .onDevice
        if safariCommandsAvailable && isCloudProvider {
            sysL2 += "\n\n" + SafariCommandBridge.compactSystemPromptBlock
        }
        let systemMessage: [String: String] = ["role": "system", "content": sysL2]

        // Insert system message at the beginning
        context.insert(systemMessage, at: 0)

        // Check if we have image files selected (for vision support)
        var imageFiles: [URL] = []
        if case .filesSelected(let urls) = effectiveConversationUserContext {
            imageFiles = urls.filter { url in
                let ext = url.pathExtension.lowercased()
                return ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "heic"].contains(ext)
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
        let systemPrompt = context
            .filter { $0["role"] == "system" }
            .compactMap { $0["content"] }
            .joined(separator: "\n\n")
        let history = context.compactMap { item -> ChatMessage? in
            guard let roleValue = item["role"],
                  roleValue != "system",
                  let role = ChatMessage.MessageRole(rawValue: roleValue),
                  let content = item["content"]
            else { return nil }
            return ChatMessage(role: role, content: content)
        }
        let capabilityPlanningRequested = !isGlobalQueryModeActive
            && ["run ", "execute ", "rename ", "reveal ", "open ", "close ", "summarize this page"]
                .contains(where: query.lowercased().contains)
        let request = isGlobalQueryModeActive
            ? AIRequestBuilder.globalContext(
                text: query,
                context: effectiveConversationUserContext,
                history: history,
                attachments: imageFiles
            )
            : AIRequestBuilder.contextDock(
                text: query,
                context: effectiveConversationUserContext,
                history: history,
                attachments: imageFiles,
                mode: capabilityPlanningRequested ? .plan : .answer,
                capabilityPrompt: capabilityPlanningRequested
                    ? AIActionPlanner.shared.capabilityPlanningPrompt(
                        bundleID: AXContextReader.shared.current.bundleId
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
                context: effectiveConversationUserContext
            )
            return await AIResultExplanationService.shared.explain(
                plan: plan,
                result: result,
                context: effectiveConversationUserContext,
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
