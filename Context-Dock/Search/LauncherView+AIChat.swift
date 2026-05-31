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
    // MARK: - Inline Dock Terminal (shown below l2ChatSection for CLI-linked apps)
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
    @ViewBuilder
    var l2ChatSection: some View {
        let hasConversation = !l2.chatMessages.isEmpty || l2.isLoading
        let scopedTarget = l2.targetApp
        if hasConversation {
            VStack(spacing: 0) {
                // Minimal header — app name + Clear + Exit Scope only (icon already in search bar)
                HStack(spacing: 8) {
                    if let scopedTarget {
                        Text(scopedTarget.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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
                } else if let scopedTarget {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(scopedTarget.name) workspace ready")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(
                            "Use the pills above to trigger app-specific actions, menu items, or approved CLI tools without switching to a separate panel."
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 4)
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
        print("🔧 [ContentView] Loading AI extension suggestions...")
        print("🔧 [ContentView] Current context: \(currentContext.description)")

        Task {
            let matcher = IntelligentExtensionMatcher.shared
            let detectedContext = convertUserContextToDetectedContext(currentContext)

            print("🔧 [ContentView] Converted to DetectedContext: \(detectedContext)")

            // Get suggestions from matcher
            var newSuggestions = matcher.suggestExtensions(for: detectedContext)
            print("🔧 [ContentView] Got \(newSuggestions.count) suggestions from matcher")

            // If no suggestions from matcher, load default built-in extensions
            if newSuggestions.isEmpty {
                print("⚠️ [ContentView] No suggestions from matcher, loading defaults...")
                let allExtensions = ExtensionManager.shared.getEnabledExtensions()
                print("📦 [ContentView] Found \(allExtensions.count) total extensions")

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

            print("🔧 [ContentView] Sorted suggestions: \(newSuggestions.count)")
            for (index, suggestion) in newSuggestions.prefix(6).enumerated() {
                print(
                    "🔧 [ContentView]   \(index + 1). \(suggestion.scriptExtension.displayName) (score: \(suggestion.relevanceScore))"
                )
            }

            await MainActor.run {
                aiExtensionSuggestions = newSuggestions
                print("✅ [ContentView] AI extension suggestions updated!")
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

        if settings.selectedAIProvider == .onDevice {
            // Direct Foundation Models — fresh session per message, zero hidden context
            AIProviderService.shared.sendPureChat(
                message: query,
                onComplete: { text in
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.2)) {
                            self.aiMode.messages.append(
                                AIChatMessage(role: .assistant, content: text))
                            self.aiMode.isLoading = false
                        }
                        self.updateWindowSize()
                    }
                },
                onError: { errorText in
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.2)) {
                            self.aiMode.messages.append(
                                AIChatMessage(role: .assistant, content: errorText, isError: true))
                            self.aiMode.isLoading = false
                        }
                        self.updateWindowSize()
                    }
                }
            )
        } else {
            // Cloud provider — include any attached images/files in the request
            aiMode.currentTask = Task {
                do {
                    let response: String
                    if !pendingAttachments.isEmpty {
                        // Build plain context without AX overhead, include image attachments
                        let history = self.aiMode.messages.map { msg in
                            [
                                "role": msg.role == .user ? "user" : "assistant",
                                "content": msg.content,
                            ]
                        }
                        let systemMsg: [String: String] = [
                            "role": "system", "content": "You are a helpful AI assistant.",
                        ]
                        var ctx = [systemMsg] + history
                        let imageFiles = pendingAttachments.filter {
                            ["jpg", "jpeg", "png", "gif", "heic", "webp"].contains(
                                $0.pathExtension.lowercased())
                        }
                        response = try await sendToProvider(
                            query: query, context: ctx, imageFiles: imageFiles)
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
        let scopedPackages = terminalPackageManager.packages(
            forContextBundleId: scopedBundleId,
            query: scopedQuery,
            maxResults: scopedQuery.isEmpty ? 6 : 4
        )
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

    // MARK: - rem-powered Reminders panel chat

    /// Appends a message to the panel chat and immediately persists it to disk.
    func appendPanelMessage(_ msg: AIChatMessage) {
        remPanelChatMessages.append(msg)
        if let key = searchState.activeSmartQueryKey ?? searchState.contextApp?.key {
            AppPanelChatStore.shared.save(remPanelChatMessages, for: key)
        }
    }

    func handleRemPanelQuery() {
        let query = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        remPanelAITask?.cancel()
        appendPanelMessage(AIChatMessage(role: .user, content: query))
        remPanelIsProcessing = true
        // Add a separator between query sessions so history is readable
        let ck = prepareScopedWorkspaceTerminal()
        if !(panelConsoleLinesMap[ck]?.isEmpty ?? true) {
            panelConsoleLinesMap[ck, default: []].append(
                (line: "────────────────────", isCommand: false))
        }
        searchState.query = ""

        // Wire live streaming into this panel's terminal drawer
        TerminalAIBridge.shared.streamLineHandler = { line in
            DispatchQueue.main.async {
                // Streaming lines go into the drawer live as they arrive
                self.panelConsoleLinesMap[ck, default: []].append((line: line, isCommand: false))
                self.panelShowConsoleMap[ck] = true
            }
        }

        let provider = settings.selectedAIProvider
        let rawKey = AppSettings.shared.getAPIKey(for: provider)
        let apiKey: String? = rawKey.isEmpty ? nil : rawKey

        if provider == .shortcuts {
            remPanelChatMessages.append(
                AIChatMessage(
                    role: .assistant,
                    content:
                        "This panel doesn't support the Shortcuts provider. Select On-Device, OpenAI, Anthropic, Gemini, or Ollama in Settings → AI Provider.",
                    isError: true))
            remPanelIsProcessing = false
            return
        }

        // Only OpenAI / Anthropic / Gemini require an API key (Ollama is local)
        let requiresKey = provider == .openAI || provider == .anthropic || provider == .googleGemini
        if requiresKey && apiKey == nil {
            remPanelChatMessages.append(
                AIChatMessage(
                    role: .assistant,
                    content:
                        "No API key found for \(provider.displayName). Add your key in Settings → AI Provider.",
                    isError: true))
            remPanelIsProcessing = false
            return
        }

        // Build system prompt dynamically — Reminders uses hard-coded rem knowledge,
        // Build system prompt — covers reminders, apps, files, contacts, etc.
        // searchState.activeSmartQueryKey is set when user explicitly opens an app panel;
        // fall back to autoDetectedAppKey (set from NSWorkspace app-switch observer).
        let activeKey =
            searchState.activeSmartQueryKey ?? settings.autoDetectedAppKey ?? "reminders"

        let ctx = searchState.contextApp
        let appLabel =
            ctx?.name ?? settings.customAppEntries.first(where: { $0.key == activeKey })?.label
            ?? activeKey.capitalized
        if executeScopedMenuIntentIfAvailable(
            query: query,
            activeKey: activeKey,
            contextApp: ctx,
            appLabel: appLabel
        ) {
            return
        }
        // For file/folder contexts, also include "Files & Folders" (finder) extensions
        let isFileContext =
            ctx?.resultType == .folder || ctx?.resultType == .file || ctx?.resultType == .document
        // Use scored + installed-only extensions (top 5 most relevant to the query)
        let _userQuery = query  // captured before closures
        let toolExts =
            settings.topExtensions(for: activeKey, query: _userQuery, maxCount: 5)
            + (isFileContext
                ? settings.topExtensions(for: "finder", query: _userQuery, maxCount: 3).filter {
                    ext in
                    !settings.topExtensions(for: activeKey, query: _userQuery, maxCount: 5)
                        .contains(where: { $0.toolName == ext.toolName })
                } : [])
        let contextualCliPackages = contextualCLIPackages(for: ctx, query: _userQuery)

        // AI Prompt extensions — always active. For file/folder contexts also include "finder" prompts.
        let promptExts: [AppToolExtension] = {
            var exts = settings.activePromptExtensions(for: activeKey)
            if isFileContext && activeKey != "finder" {
                let finderPrompts = settings.activePromptExtensions(for: "finder")
                    .filter { fp in !exts.contains(where: { $0.id == fp.id }) }
                exts += finderPrompts
            }
            return exts
        }()

        let systemPrompt: String
        // Generic context for non-app results (files, folders, contacts, etc.)
        let isGenericContext =
            ctx != nil && ctx?.resultType != .application && activeKey != "reminders"
        // Core tool rules — appended to every system prompt
        let toolRules = """

            ══ EXECUTION RULES — READ CAREFULLY ══
            You have exactly THREE callable tools: run_command, spawn_worker, send_keys.
            DO NOT invent other tool names. DO NOT call "reminders", "remind", "notes", or any
            tool name from the AVAILABLE TOOLS section — those are shell commands to run INSIDE run_command.

            ✅ CORRECT — silently invoke the tool:
               run_command(command: "osascript -l JavaScript /path/script.js \\"list today\\"")
            ❌ WRONG — writing JSON or describing what you'll do:
               {"name": "reminders", "parameters": {...}}
               "I will call the reminders tool with..."
               "Here is the function call: ..."

            RULE: ACT FIRST, EXPLAIN AFTER. Never explain a tool call before making it.
            RULE: run_command for any non-interactive shell command or script.
            RULE: For DESTRUCTIVE actions (delete/remove/overwrite) — preview first, confirm, then execute.
            RULE: Summarise output in plain English. Never dump raw output at the user.
            RULE: STAY ON TOPIC — politely decline unrelated requests.

            ══ ERROR DETECTION — CRITICAL ══
            After EVERY run_command, read the output before responding.
            A command FAILED if its output contains ANY of: "Error:", "error:", "Unknown option",
            "Unknown subcommand", "Missing expected", "Invalid", "not found", "Usage:", "USAGE:".
            ▸ NEVER claim an operation succeeded when the output shows an error.
            ▸ NEVER fabricate results — only report what the actual output says.
            ▸ If a command fails with "Unknown subcommand" or similar, IMMEDIATELY run
              run_command("<tool> --help") to get the real subcommand list, then pick the correct one.
            ▸ NEVER guess or invent subcommands from general knowledge — only use what --help shows.
            ▸ If the error output shows a correct usage line, retry with that exact syntax.
            ▸ Only after 2 failed retries should you report the error to the user verbatim.
            """

        // CLI tool panel — build system prompt from the tool's --help text and subcommands
        if ctx?.resultType == .cliTool, let ctx = ctx {
            let toolCmd = ctx.name
            let toolPath = ctx.filePath ?? ctx.appPath
            let pkg = TerminalPackageManager.shared.packages.first(where: {
                $0.name == ctx.name || $0.command == ctx.name
            })
            let isTUI = TerminalAIBridge.shared.isTUICommand(toolCmd)
            // Inject the FULL scanned help tree — this is what prevents hallucination.
            // The AI must only use commands that appear here.
            let helpSnippet: String = {
                guard let ht = pkg?.helpText, !ht.isEmpty else { return "" }
                return
                    "\n\n══ TOOL REFERENCE (exact output of \(toolCmd) --help) ══\n\(String(ht.prefix(4000)))\n══ END TOOL REFERENCE ══"
            }()
            let subcommandList: String = {
                guard let subs = pkg?.subcommands, !subs.isEmpty else { return "" }
                let list = subs.prefix(30).joined(separator: ", ")
                return
                    "\n\n⚠️ VERIFIED SUBCOMMANDS (from --help scan): \(list)\nDO NOT use any subcommand not in this list. If unsure, run `\(toolCmd) --help` first."
            }()
            let launchNote =
                isTUI
                ? """

                This is a full-screen TUI app (ncurses). The embedded terminal panel on the right is where it runs.

                HOW TO CONTROL THIS TUI:
                1. Launch: spawn_worker(command="\(toolCmd)", purpose="Launch TUI")
                2. After launching, wait ~1s for the TUI to draw its first screen, then navigate using send_keys.
                3. Menu selection: send_keys(keys="5\\r") sends key "5" then Enter.
                4. Arrow keys: "\\u{1B}[A"=up, "\\u{1B}[B"=down, "\\u{1B}[C"=right, "\\u{1B}[D"=left, "\\r"=Enter.
                5. Exit: send_keys(keys="q") or send_keys(keys="\\u{03}") for Ctrl-C.

                RULES:
                - NEVER call run_command('\(toolCmd)') — requires PTY, will fail.
                - NEVER call run_command('\(toolCmd) --help') — same reason.
                - Use ONLY the stored TOOL REFERENCE below to know menus/options.
                - Chain: spawn_worker → (brief pause) → send_keys to automate the TUI for the user.
                """
                : "\nUse run_command for all operations. Pass flags and subcommands as part of the command string."
            // Always inject real home directory — prevents AI from using placeholder /Users/username
            let homeDir = NSHomeDirectory()
            let folderAccessEnabled = settings.isFolderAccessEnabled(for: toolCmd)
            let folderSection: String = {
                if folderAccessEnabled {
                    return """

                        FOLDER ACCESS: Granted by user.
                        HOME: \(homeDir)
                        Downloads: \(homeDir)/Downloads
                        Documents: \(homeDir)/Documents
                        Desktop:   \(homeDir)/Desktop
                        Pictures:  \(homeDir)/Pictures
                        Movies:    \(homeDir)/Movies
                        Music:     \(homeDir)/Music
                        ALWAYS use these exact absolute paths. NEVER use /Users/username or placeholder paths.
                        """
                } else {
                    return """

                        HOME DIRECTORY: \(homeDir)
                        ALWAYS use this exact home path in commands. NEVER use /Users/username or placeholder paths.
                        NOTE: User has not granted folder access for \(toolCmd). Avoid reading or writing ~/Documents, ~/Downloads etc. unless the user explicitly asks.
                        """
                }
            }()
            systemPrompt = """
                You are an expert AI assistant for the TUI app '\(toolCmd)' inside ILauncher.
                The embedded terminal on the right is where '\(toolCmd)' runs.\(folderSection)\(launchNote)\(helpSnippet)\(subcommandList)
                \(toolRules)
                """
        } else if isGenericContext, let ctx = ctx {
            // Build the explicit path line so AI always knows exactly where to look
            let contextPath: String = ctx.filePath ?? ctx.subtitle
            let isFolder = ctx.resultType == .folder
            let pathDirective: String = {
                if isFolder && !contextPath.isEmpty {
                    return
                        "\nCURRENT FOLDER: \(contextPath)\nALWAYS use this absolute path in every command. Never use relative paths like './' or '~' — use the full path above."
                } else if let fp = ctx.filePath, !fp.isEmpty {
                    return
                        "\nFILE PATH: \(fp)\nAlways reference this exact absolute path in commands."
                }
                return ""
            }()

            let fileToolDocs: String = {
                guard !toolExts.isEmpty else { return "" }
                let pkgs = TerminalPackageManager.shared.packages
                let docs = toolExts.map { ext -> String in
                    if ext.kind == .script, let lang = ext.scriptLanguage, !ext.toolPath.isEmpty {
                        let runCmd = lang.runCommand(scriptPath: ext.toolPath)
                        var doc = "### \(ext.toolName) [SCRIPT – \(lang.rawValue)]"
                        doc +=
                            "\nInvoke: run_command(\"\(runCmd) \\\"<full user query>\\\"\") — pass entire query as one arg"
                        let cap = ext.effectiveHint.isEmpty ? ext.aiHint : ext.effectiveHint
                        if !cap.isEmpty { doc += "\n" + String(cap.prefix(400)) }
                        return doc
                    }
                    let pkg = pkgs.first(where: { $0.command == ext.toolName })
                    var doc = "### \(ext.toolName) [CLI]"
                    if let helpText = pkg?.helpText, !helpText.isEmpty {
                        doc += "\n" + String(helpText.prefix(600))
                    } else if !ext.aiHint.isEmpty {
                        doc += "\n" + ext.aiHint
                    }
                    return doc
                }.joined(separator: "\n\n")
                return "\n\nAvailable tools (use via run_command):\n\(docs)"
            }()
            // Inject file-type tool registry snippet for file/folder contexts
            let registrySnippet: String = {
                guard isFileContext else { return "" }
                let registry = FileTypeToolRegistry.shared
                var snippet = ""
                if !isFolder, let filePath = ctx.filePath {
                    let ext = (filePath as NSString).pathExtension
                    snippet = registry.systemPromptSnippet(for: ext)
                    // If no installed tool handles this file type, suggest what to install
                    if snippet.isEmpty {
                        let missing = registry.suggestMissingTools(
                            for: _userQuery.isEmpty ? ext : _userQuery, maxCount: 2)
                        if !missing.isEmpty {
                            let suggestions = missing.map { "brew install \($0.toolName)" }.joined(
                                separator: "  or  ")
                            snippet =
                                "\n\nNo installed tool found for .\(ext) files. Tell the user to install one: \(suggestions)"
                        }
                    }
                } else if isFolder, !contextPath.isEmpty {
                    let fm = FileManager.default
                    var seenExts = Set<String>()
                    if let contents = try? fm.contentsOfDirectory(atPath: contextPath) {
                        for name in contents {
                            let e = (name as NSString).pathExtension.lowercased()
                            if !e.isEmpty { seenExts.insert(e) }
                        }
                    }
                    snippet = registry.systemPromptSnippet(forAnyOf: Array(seenExts))
                    // Suggest missing tools based on query intent (e.g. "compress video" → ffmpeg)
                    if snippet.isEmpty {
                        let missing = registry.suggestMissingTools(for: _userQuery, maxCount: 2)
                        if !missing.isEmpty {
                            let suggestions = missing.map {
                                "  brew install \($0.toolName)  — \($0.description)"
                            }.joined(separator: "\n")
                            snippet =
                                "\n\nNo installed tool matches this request. Suggest the user install:\n\(suggestions)"
                        }
                    }
                }
                return snippet
            }()
            systemPrompt = """
                You are a focused macOS assistant inside ILauncher. \
                The user is working with: \(ctx.aiContextDescription).\(pathDirective)
                Answer ONLY questions about this specific item. \
                Use run_command to inspect or act on it. Be concise.\(fileToolDocs)\(registrySnippet)
                \(toolRules)
                """
        } else if activeKey == "homebrew" {
            let brewBin =
                FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew")
                ? "/opt/homebrew/bin/brew" : "/usr/local/bin/brew"
            systemPrompt = """
                You are a Homebrew package manager assistant inside ILauncher.
                Homebrew is installed at: \(brewBin)
                Always run brew commands via run_command. Chain multiple commands when needed.

                PACKAGE MANAGEMENT:
                - Install:      brew install <formula>
                - Install cask: brew install --cask <app>        (GUI apps like Chrome, VS Code)
                - Uninstall:    brew uninstall <formula>
                - Upgrade one:  brew upgrade <formula>
                - Upgrade all:  brew upgrade
                - Update brew:  brew update
                - Search:       brew search <term>
                - Info:         brew info <formula>
                - List all:     brew list
                - Top-level:    brew leaves                      (installed, not as deps)
                - Outdated:     brew outdated

                CASK (GUI APPS):
                - List casks:   brew list --cask
                - Outdated:     brew outdated --cask
                - Info:         brew info --cask <app>

                SERVICES (daemons):
                - List:         brew services list
                - Start:        brew services start <formula>
                - Stop:         brew services stop <formula>
                - Restart:      brew services restart <formula>

                MAINTENANCE:
                - Doctor:       brew doctor                       (diagnose issues)
                - Cleanup:      brew cleanup                      (remove old versions, free disk)
                - Cleanup dry:  brew cleanup -n                   (preview what would be removed)
                - Cache size:   du -sh $(brew --cache)
                - Disk usage:   brew list | xargs brew info --json | jq '.[].installed[].installed_on_request'

                TAPS (third-party repos):
                - Add tap:      brew tap <user/repo>
                - Remove tap:   brew untap <user/repo>
                - List taps:    brew tap

                VERSIONS & PINNING:
                - Pin version:  brew pin <formula>               (stops auto-upgrade)
                - Unpin:        brew unpin <formula>
                - Dependencies: brew deps <formula>
                - What uses it: brew uses --installed <formula>

                BREWFILE (backup/restore):
                - Export:       brew bundle dump --file=~/Brewfile --force
                - Restore:      brew bundle install --file=~/Brewfile
                - List:         brew bundle list --file=~/Brewfile

                WORKFLOW RULES:
                - Always run brew update before major installs/upgrades.
                - Use run_command for each brew step; show output to user.
                - For multi-step tasks (update + upgrade + cleanup), chain with &&.
                - When user asks to "install X", first run brew search X to confirm exact name.
                - When listing packages, use brew list --versions for cleaner output.
                - For disk cleanup suggestions, run brew cleanup -n first so user can approve.
                \(toolRules)
                """
        } else if activeKey == "amphetamine" {
            systemPrompt = """
                You are an Amphetamine assistant inside ILauncher.
                Amphetamine is a macOS app that prevents the Mac from sleeping.
                Control it using osascript (AppleScript) via run_command. Never use caffeinate.

                FULL APPLESCRIPT API (always wrap with: osascript -e '...'):

                START SESSION:
                - Default: osascript -e 'tell application "Amphetamine" to start new session'
                - Timed:   osascript -e 'tell application "Amphetamine" to start new session with options {duration:30, interval:minutes, displaySleepAllowed:false}'
                - Hours:   osascript -e 'tell application "Amphetamine" to start new session with options {duration:2, interval:hours, displaySleepAllowed:true}'
                - interval is either: minutes  OR  hours

                END SESSION:
                - osascript -e 'tell application "Amphetamine" to end session'

                DISPLAY SLEEP:
                - osascript -e 'tell application "Amphetamine" to allow display sleep'
                - osascript -e 'tell application "Amphetamine" to prevent display sleep'

                SCREEN SAVER:
                - osascript -e 'tell application "Amphetamine" to allow screen saver'
                - osascript -e 'tell application "Amphetamine" to prevent screen saver'

                CLOSED DISPLAY MODE:
                - osascript -e 'tell application "Amphetamine" to enable closed display mode'
                - osascript -e 'tell application "Amphetamine" to disable closed display mode'

                QUERY STATUS (run_command, read the output):
                - Is active?:       osascript -e 'tell application "Amphetamine" to return session is active'
                - Time remaining:   osascript -e 'tell application "Amphetamine" to return session time remaining'
                  (returns seconds; 0=infinite, -1=trigger, -2=app/date-based, -3=no session)
                - Display sleep?:   osascript -e 'tell application "Amphetamine" to return display sleep allowed'
                - Is trigger?:      osascript -e 'tell application "Amphetamine" to return session is Trigger'

                RULES:
                - ALWAYS use osascript -e '...' via run_command. Never use caffeinate.
                - To check if Amphetamine is running: run_command(command="pgrep -x Amphetamine")
                - If not running, tell user to open it first (open -a Amphetamine).
                - After "notify when ends": after starting a timed session, also call:
                  run_command(command="osascript -e 'tell application \\"Amphetamine\\" to start new session with options {duration:N, interval:minutes, displaySleepAllowed:false}' && sleep Ns && osascript -e 'display notification \\"Amphetamine session ended\\" with title \\"Amphetamine\\"'")
                - Convert natural language time: "1 hour" → duration:1, interval:hours; "45 minutes" → duration:45, interval:minutes
                - Give a short friendly confirmation after each action.
                \(toolRules)
                """
        } else if !promptExts.isEmpty && toolExts.isEmpty && contextualCliPackages.isEmpty {
            // ── PURE PROMPT EXTENSION — no CLI/script tools, AI answers directly ──
            // Render the first prompt's template; subsequent prompts are appended.
            let rendered = promptExts.map { ext in
                PromptRunner.shared.render(
                    template: ext.promptTemplate, query: query, appLabel: appLabel)
            }.joined(separator: "\n\n---\n\n")
            systemPrompt = rendered

        } else if !toolExts.isEmpty || !contextualCliPackages.isEmpty {
            // USER-SET AI EXTENSIONS — always take priority over built-in hardcoded prompts.
            // Supports CLI tools (binaries on $PATH) AND user scripts (JXA, bash, Python, AppleScript, Lua).
            // If prompt extensions also exist, their rendered template becomes the persona/intro.
            let pkgs = TerminalPackageManager.shared.packages

            let extensionDocs = toolExts.map { ext -> String in
                if ext.kind == .script, let lang = ext.scriptLanguage, !ext.toolPath.isEmpty {
                    // ── SCRIPT EXTENSION ───────────────────────────────────────
                    let runCmd = lang.runCommand(scriptPath: ext.toolPath)
                    var doc = "### \(ext.toolName) [SCRIPT – \(lang.rawValue)]"
                    if ext.profile.isDestructive { doc += " ⚠️ DESTRUCTIVE" }
                    doc +=
                        "\nInvoke with: run_command(\"\(runCmd) \\\"<full user query as one arg>\\\"\")"
                    doc +=
                        "\nPASS THE ENTIRE user query as a single quoted argument — the script handles all parsing internally."
                    // Capability description from aiHint / profile
                    let cap = ext.effectiveHint.isEmpty ? ext.aiHint : ext.effectiveHint
                    if !cap.isEmpty { doc += "\nCapabilities: " + String(cap.prefix(500)) }
                    if !ext.profile.exampleCommands.isEmpty {
                        doc += "\nExamples: " + ext.profile.exampleCommands.joined(separator: " | ")
                    }
                    return doc
                } else {
                    // ── CLI TOOL EXTENSION ─────────────────────────────────────
                    let cmd = ext.effectiveCommand  // "memo notes" or "memo rem" — scoped per app
                    let base = ext.toolName  // "memo" — binary name for package lookup
                    let pkg = pkgs.first(where: { $0.command == base })
                    var doc = "### \(cmd) [CLI]"
                    if cmd != base { doc += "  (binary: \(base))" }
                    if let path = pkg?.installedPath ?? (ext.toolPath.isEmpty ? nil : ext.toolPath)
                    {
                        doc += " at \(path)"
                    }
                    if ext.profile.isDestructive { doc += " ⚠️ DESTRUCTIVE" }
                    doc += "\n"
                    // Prefer scoped subcommand help; fall back to full help or hints
                    let scopedHelp = TerminalPackageManager.shared.helpText(
                        for: cmd, baseCommand: base)
                    let helpSource: String
                    if let sh = scopedHelp, !sh.isEmpty {
                        helpSource = String(sh.prefix(1000))
                    } else if ext.aiHint.contains("--help output:") {
                        helpSource = String(ext.aiHint.prefix(1000))
                    } else if !ext.effectiveHint.isEmpty {
                        helpSource = ext.effectiveHint
                    } else {
                        helpSource = ""
                    }
                    if !helpSource.isEmpty {
                        doc += helpSource
                    } else {
                        doc +=
                            "UNKNOWN: Call run_command(\"\(cmd) --help\") first, read output, then answer."
                    }
                    // Context flag — always append this flag to every command for this app panel
                    if !ext.appContextFlag.isEmpty {
                        doc +=
                            "\n⚑ CONTEXT FLAG: You MUST append `\(ext.appContextFlag)` to EVERY \(base) command for \(appLabel)."
                        doc += "\n  Example: run_command(\"\(cmd) list \(ext.appContextFlag)\")"
                        doc +=
                            "\n  Example: run_command(\"\(cmd) add \(ext.appContextFlag) \\\"Buy milk\\\"\")"
                    }
                    if !ext.profile.exampleCommands.isEmpty {
                        doc += "\nExamples: " + ext.profile.exampleCommands.joined(separator: " | ")
                    }
                    return doc
                }
            }
            let packageDocs = contextualCliPackages.map(appPanelCLIDocumentation(for:))
            let toolDocs = (extensionDocs + packageDocs).joined(separator: "\n\n---\n\n")

            // Intent → invocation hints per tool
            let extensionIntentLines = toolExts.map { ext -> String in
                if ext.kind == .script, let lang = ext.scriptLanguage, !ext.toolPath.isEmpty {
                    let runCmd = lang.runCommand(scriptPath: ext.toolPath)
                    return "• \(ext.toolName): run_command(\"\(runCmd) \\\"<full user query>\\\"\")"
                }
                let cmd = ext.effectiveCommand
                let ctxFlag = ext.appContextFlag.isEmpty ? "" : " \(ext.appContextFlag)"
                if !ext.profile.capabilities.isEmpty {
                    return "• \(cmd): "
                        + ext.profile.capabilities.prefix(4).joined(separator: " | ")
                        + (ctxFlag.isEmpty ? "" : "  [always append \(ext.appContextFlag)]")
                }
                return
                    "• \(cmd): list → \(cmd) list\(ctxFlag)  |  add → \(cmd) add\(ctxFlag) \"<title>\"  |  delete → \(cmd) delete\(ctxFlag) <id>"
            }
            let packageIntentLines = contextualCliPackages.map(appPanelCLIIntentLine(for:))
            let intentLines = (extensionIntentLines + packageIntentLines).joined(separator: "\n")

            let hasDestructiveTool =
                toolExts.contains { $0.profile.isDestructive }
                || contextualCliPackages.contains {
                    let warningWords = ["delete", "remove", "uninstall", "erase", "purge"]
                    let corpus =
                        ($0.taskCategories + $0.subcommands + $0.usageExamples + [$0.description])
                        .joined(separator: " ")
                        .lowercased()
                    return warningWords.contains(where: { corpus.contains($0) })
                }
            let destructiveWarning =
                hasDestructiveTool
                ? "\n- ⚠️ One or more tools are DESTRUCTIVE. Always confirm with the user before running delete/remove/overwrite operations."
                : ""

            // If user has a prompt extension too, its rendered template becomes the persona intro.
            // Strip any "User's question: {{query}}" lines — the query is already the user message.
            let promptPersona: String =
                promptExts.isEmpty
                ? ""
                : {
                    let rendered = promptExts.map { ext in
                        var t = PromptRunner.shared.render(
                            template: ext.promptTemplate, query: query, appLabel: appLabel)
                        // Remove lines that redundantly embed the query — causes AI to answer in text instead of tool-calling
                        t = t.split(separator: "\n", omittingEmptySubsequences: false).filter {
                            line in
                            let l = line.lowercased()
                            return !l.hasPrefix("user's question:")
                                && !l.hasPrefix("user question:")
                                && !l.contains(query.lowercased().prefix(20))
                        }.joined(separator: "\n")
                        return t.trimmingCharacters(in: .whitespacesAndNewlines)
                    }.joined(separator: "\n\n")
                    return rendered.isEmpty ? "" : rendered + "\n\n"
                }()

            systemPrompt = """
                \(promptPersona)You are an AI assistant for \(appLabel) inside ILauncher.
                Only help with tasks related to \(appLabel).
                Use run_command for attached CLI/script tools. The embedded terminal drawer may appear for live output when commands run.
                Their output is returned to you; always summarise it in plain English.

                AVAILABLE TOOLS (user-configured for \(appLabel)):
                \(toolDocs)

                HOW TO INVOKE EACH TOOL:
                \(intentLines)

                RULES:
                - For SCRIPT tools: always pass the user's FULL original query as a single argument in quotes.
                - For CLI tools: use ONLY the exact flags and subcommands documented in AVAILABLE TOOLS above.
                  Never guess flags. If you're unsure of exact syntax, run "<tool> help <subcommand>" first.
                - The AVAILABLE TOOLS section contains the full --help tree (all subcommand levels).
                  Always check the relevant subcommand section before forming a command.
                - For "find/search X": use the search or list subcommand as shown in help.
                - For "create/add X": always check the correct add subcommand syntax before running.
                - Never dump raw output — always give a clean plain-English summary.\(destructiveWarning)
                \(toolRules)
                """
        } else if activeKey == "safari" {
            let safariTab = AppleAppsAPI.shared.getCurrentTab()
            let pageURL =
                (safariTab["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let pageTitle =
                (safariTab["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? ""
            let pageText = fetchSafariPageText() ?? ""
            let pageLinks = fetchSafariPageLinks()
            let pageImages = fetchSafariPageImages()
            let lowerQuery = query.lowercased()
            let selectedText =
                AXContextReader.shared.current.selectedText?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let shouldIncludeLinks =
                lowerQuery.contains("link")
                || lowerQuery.contains("url")
                || lowerQuery.contains("href")
            let shouldIncludeImages =
                lowerQuery.contains("image")
                || lowerQuery.contains("photo")
                || lowerQuery.contains("picture")
                || lowerQuery.contains("logo")
            let pageTextSection =
                pageText.isEmpty
                ? "\nPAGE TEXT: (unavailable — Safari page content could not be read)"
                : "\nPAGE TEXT EXCERPT:\n\(String(pageText.prefix(5000)))"
            let selectedTextSection =
                selectedText.isEmpty
                ? ""
                : "\nSELECTED TEXT:\n\(String(selectedText.prefix(1500)))"
            let linksSection =
                shouldIncludeLinks && !pageLinks.isEmpty
                ? "\nPAGE LINKS:\n"
                    + pageLinks.prefix(40).map { "  • \($0)" }.joined(separator: "\n")
                : ""
            let imagesSection =
                shouldIncludeImages && !pageImages.isEmpty
                ? "\nPAGE IMAGE URLS:\n"
                    + pageImages.prefix(40).map { "  • \($0)" }.joined(separator: "\n")
                : ""
            systemPrompt = """
                You are a Safari page assistant inside ILauncher.
                Answer questions about the CURRENT Safari page using the provided page context.
                Do not say you cannot see the page if page context is present below.
                If the user asks what the page is about, summarize the page text.
                If the user asks for images or links, use the provided PAGE IMAGE URLS or PAGE LINKS sections.
                If the requested data is unavailable, say exactly what is missing.

                CURRENT TAB TITLE: \(pageTitle.isEmpty ? "(unknown)" : pageTitle)
                CURRENT TAB URL: \(pageURL.isEmpty ? "(unknown)" : pageURL)\(selectedTextSection)\(pageTextSection)\(linksSection)\(imagesSection)

                RULES:
                - Stay focused on the current Safari page.
                - Prefer the page text and tab metadata over generic guesses.
                - If the user asks for a list of images or links, return the actual URLs you were given.
                - Be concise and directly answer the question.
                """
        } else if activeKey == "finder" {
            let finderDir = ContextDetector.shared.getCurrentFinderDirectory() ?? NSHomeDirectory()
            let selectedFiles = ContextDetector.shared.getFinderSelectedFiles()
            let selectedNote =
                selectedFiles.isEmpty
                ? ""
                : "\nSELECTED FILES:\n"
                    + selectedFiles.prefix(5).map { "  • \($0)" }.joined(separator: "\n")
            let toolContext = FinderToolkit.shared.systemPromptContext()
            systemPrompt = """
                You are a Finder file management assistant inside ILauncher.
                You help users organize, find, rename, and manage files using shell commands and installed scripts.

                CURRENT FINDER DIRECTORY: \(finderDir)\(selectedNote)

                \(toolContext)

                CRITICAL RULES:
                - You are a FILE MANAGER assistant. Do NOT search contacts, photos, or calendars.
                - ALWAYS use run_command to execute operations — never just describe what to do.
                - For destructive operations (sort/organize/rename/delete): ALWAYS run the --dry-run version first,
                  show the output to the user, and ask "Shall I proceed?" before running for real.
                - When user asks "show all PDFs" / "list files": run a find command immediately.
                - When user asks "how do I X": use the Find Cmd script to search for the right command.
                - Summarize command output in plain English — never dump raw terminal output.
                - Home directory is: \(NSHomeDirectory())
                \(toolRules)
                """

        } else if activeKey == "clipboard" {
            let clipboardContext = relevantClipboardHistory().prefix(20).enumerated().map {
                index, entry in
                "\(index + 1). \(entry.preview) — \(clipboardEntrySubtitle(entry))\n\(String(entry.text.prefix(600)))"
            }.joined(separator: "\n\n")
            systemPrompt = """
                You are a Clipboard assistant inside ILauncher.
                The user is asking about their recent clipboard history. Use ONLY the clipboard entries below.
                You can summarize, compare, find, explain, or tell the user which item to paste/open.
                Do not claim to know clipboard items not shown here.

                CLIPBOARD HISTORY:
                \(clipboardContext.isEmpty ? "No clipboard items stored." : clipboardContext)
                \(toolRules)
                """
        } else if activeKey == "reminders" {
            // Fallback: no user extensions set — use built-in rem CLI if installed
            let remPath = ["/opt/homebrew/bin/rem", "/usr/local/bin/rem"]
                .first { FileManager.default.fileExists(atPath: $0) }
            let remNote =
                remPath != nil
                ? "rem is installed at \(remPath!)."
                : "The `rem` CLI is not installed. Tell the user to run: brew install rem"
            systemPrompt = """
                You are a Reminders assistant inside ILauncher.
                \(remNote)
                You manage macOS Reminders using the `rem` CLI via run_command (runs silently, no terminal).

                rem examples:
                - rem add "call mom" --due "tomorrow at 5pm"
                - rem list
                - rem complete "call mom"
                - rem delete "call mom"
                - rem search "mom"

                Natural language dates work: "tomorrow at 3pm", "next friday", "in 2 hours".
                TIP: User can assign a different CLI (e.g. memo) in Settings → App Shortcuts → Reminders → AI Extensions.
                After actions, give a short friendly confirmation. Summarise lists — don't dump raw JSON.
                \(toolRules)
                """
        } else {
            // Generic fallback — no user extensions, no built-in CLI known
            systemPrompt = """
                You are an AI assistant for \(appLabel) inside ILauncher.
                Only help with tasks related to \(appLabel).
                Run shell commands via run_command (runs silently in the background — no terminal shown).
                TIP: Assign CLI tools in Settings → App Shortcuts → \(appLabel) → AI Extensions to unlock more actions.
                \(toolRules)
                """
        }

        // Build history from chat for multi-turn context (exclude .tool command chips — visual only)
        let history: [ChatMessage] = remPanelChatMessages.dropLast()
            .filter { $0.role != .tool }
            .map { ChatMessage(role: $0.role == .user ? .user : .assistant, content: $0.content) }

        // Capture folder path for command fixup (folder panel context)
        let contextFolderPath: String? = {
            guard let ctx = ctx, ctx.resultType == .folder else { return nil }
            let p = ctx.filePath ?? ctx.subtitle
            return p.isEmpty ? nil : p
        }()

        // Check prompt extension cache — if we get a hit, skip the full AI round-trip
        if let cacheHit = promptExts.first.flatMap({
            PromptRunner.shared.cachedResponse(for: $0, query: query)
        }) {
            remPanelChatMessages.append(AIChatMessage(role: .assistant, content: cacheHit))
            remPanelIsProcessing = false
            return
        }

        if provider == .onDevice {
            guard let scopedIdentity = scopedWorkspaceIdentity() else {
                remPanelChatMessages.append(
                    AIChatMessage(
                        role: .assistant,
                        content:
                            "I couldn't resolve a scoped app context for on-device execution. Re-open the app scope and try again.",
                        isError: true
                    ))
                remPanelIsProcessing = false
                return
            }

            let placeholder = AIChatMessage(role: .assistant, content: "")
            remPanelChatMessages.append(placeholder)
            let messageID = placeholder.id

            remPanelAITask = Task { @MainActor in
                await withCheckedContinuation { continuation in
                    #if canImport(FoundationModels)
                        if #available(macOS 26.0, *) {
                            OnDeviceToolSession.shared.stream(
                                to: query,
                                systemPrompt: systemPrompt,
                                bundleId: scopedIdentity.bundleId,
                                axContext: scopedIdentity.axContext,
                                onPartial: { token in
                                    DispatchQueue.main.async {
                                        if let index = self.remPanelChatMessages.firstIndex(where: {
                                            $0.id == messageID
                                        }) {
                                            self.remPanelChatMessages[index] = AIChatMessage(
                                                id: messageID,
                                                role: .assistant,
                                                content: self.remPanelChatMessages[index].content
                                                    + token
                                            )
                                        }
                                    }
                                },
                                onComplete: { response in
                                    DispatchQueue.main.async {
                                        if let index = self.remPanelChatMessages.firstIndex(where: {
                                            $0.id == messageID
                                        }), self.remPanelChatMessages[index].content.isEmpty {
                                            self.remPanelChatMessages[index] = AIChatMessage(
                                                id: messageID,
                                                role: .assistant,
                                                content: response
                                            )
                                        }
                                        self.remPanelIsProcessing = false
                                    }
                                    continuation.resume()
                                },
                                onError: { errorText in
                                    DispatchQueue.main.async {
                                        if let index = self.remPanelChatMessages.firstIndex(where: {
                                            $0.id == messageID
                                        }) {
                                            self.remPanelChatMessages[index] = AIChatMessage(
                                                id: messageID,
                                                role: .assistant,
                                                content: errorText,
                                                isError: true
                                            )
                                        }
                                        self.remPanelIsProcessing = false
                                    }
                                    continuation.resume()
                                }
                            )
                        } else {
                            DispatchQueue.main.async {
                                if let index = self.remPanelChatMessages.firstIndex(where: {
                                    $0.id == messageID
                                }) {
                                    self.remPanelChatMessages[index] = AIChatMessage(
                                        id: messageID,
                                        role: .assistant,
                                        content:
                                            "On-device AI requires macOS 26.0 or later with Apple Silicon.",
                                        isError: true
                                    )
                                }
                                self.remPanelIsProcessing = false
                            }
                            continuation.resume()
                        }
                    #else
                        DispatchQueue.main.async {
                            if let index = self.remPanelChatMessages.firstIndex(where: {
                                $0.id == messageID
                            }) {
                                self.remPanelChatMessages[index] = AIChatMessage(
                                    id: messageID,
                                    role: .assistant,
                                    content: "On-device AI is not available in this build.",
                                    isError: true
                                )
                            }
                            self.remPanelIsProcessing = false
                        }
                        continuation.resume()
                    #endif
                }
            }
            return
        }

        remPanelAITask = Task {
            do {
                let (response, executedCommands) = try await AIProviderService.shared.sendWithTools(
                    query,
                    context: .none,
                    provider: provider,
                    apiKey: apiKey,
                    conversationHistory: history,
                    commandExecutor: { cmd, purpose in
                        // Fix relative paths: if AI used "find . ..." or "ls" without absolute path
                        // and we're in a folder context, rewrite to use the folder's absolute path
                        let fixedCmd: String = {
                            guard let folderPath = contextFolderPath else { return cmd }
                            var c = cmd
                            // find . → find /absolute/path
                            if c.hasPrefix("find . ") || c == "find ." {
                                c = "find " + folderPath + c.dropFirst(6)
                            } else if c.hasPrefix("find ./ ") {
                                c = "find " + folderPath + "/" + c.dropFirst(8)
                            }
                            // ls (no args or just flags) → ls folderPath
                            if c == "ls"
                                || c.range(of: #"^ls\s+-[a-zA-Z]+$"#, options: .regularExpression)
                                    != nil
                            {
                                c = c + " " + folderPath
                            }
                            // du . → du folderPath
                            if c.hasPrefix("du . ") || c == "du ." {
                                c = "du " + folderPath + c.dropFirst(4)
                            }
                            return c
                        }()
                        // Show command chip in chat + open embedded panel terminal
                        await MainActor.run {
                            self.remPanelChatMessages.append(
                                AIChatMessage(
                                    role: .tool,
                                    content: "$ \(fixedCmd)"
                                ))
                            let ck = self.activeConsoleKey
                            self.panelShowConsoleMap[ck] = true
                            // Ensure panel PTY exists before command fires
                            _ = self.panelTerminal(for: ck)
                        }
                        let result = await TerminalAIBridge.shared.processAICommand(
                            fixedCmd, purpose: purpose)
                        // Also send approved command to the panel's embedded PTY for live display
                        await MainActor.run {
                            let ck = self.activeConsoleKey
                            self.panelTerminalControllers[ck]?.sendCommand(fixedCmd)
                        }
                        // Post-execution: file detection / live panel (streaming already filled output lines)
                        await MainActor.run {
                            let ck = self.activeConsoleKey
                            // If the command created a file, auto-show its preview
                            if result.success,
                                let createdURL = self.detectCreatedFile(
                                    command: fixedCmd, output: result.output)
                            {
                                self.showLivePanel(.filePreview(url: createdURL))
                            } else if result.success || !result.output.isEmpty {
                                // Parse output → right panel results (files, tasks, processes, events, etc.)
                                let resultEntries = self.parseCommandOutputForPanel(
                                    command: fixedCmd,
                                    output: result.output,
                                    panelKey: activeKey
                                )
                                if !resultEntries.isEmpty {
                                    self.showLivePanel(.results(resultEntries))
                                }
                            }
                        }
                        return result
                    },
                    systemPromptOverride: systemPrompt
                )
                await MainActor.run {
                    // Strip any leaked raw tool-call syntax the AI accidentally included in its text reply
                    let cleanResponse = Self.stripLeakedToolCalls(response)
                    if !cleanResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        remPanelChatMessages.append(
                            AIChatMessage(role: .assistant, content: cleanResponse))
                        // Cache the response for pure-prompt extensions (no commands were run)
                        if executedCommands.isEmpty, let pExt = promptExts.first {
                            PromptRunner.shared.cacheResponse(
                                cleanResponse, for: pExt, query: query)
                        }
                    }
                    remPanelIsProcessing = false
                    searchState.appPanelAllItems = []
                    reloadAppPanelData(for: "reminders")
                    // Auto-switch live panel to terminal if spawn_worker was used
                    let spawnedTUI = executedCommands.contains {
                        $0.command.hasPrefix("spawn_worker")
                    }
                    if spawnedTUI { showLivePanel(.terminal) }
                }
            } catch AIServiceError.unsupportedProvider(_) {
                // Ollama: ask AI to output the rem command as plain text, then run it
                await handleRemPanelQueryLegacy(
                    query: query, systemPrompt: systemPrompt, provider: provider, apiKey: apiKey)
            } catch {
                await MainActor.run {
                    remPanelChatMessages.append(
                        AIChatMessage(
                            role: .assistant,
                            content: "⚠️ \(error.localizedDescription)", isError: true))
                    remPanelIsProcessing = false
                }
            }
        }
    }

    func executeScopedMenuIntentIfAvailable(
        query: String,
        activeKey: String,
        contextApp: SearchContextApp?,
        appLabel: String
    ) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return false }
        let looksLikeQuestion =
            q.hasSuffix("?")
            || q.hasPrefix("what") || q.hasPrefix("how") || q.hasPrefix("why")
            || q.hasPrefix("tell") || q.hasPrefix("explain") || q.hasPrefix("describe")
            || q.hasPrefix("summarize") || q.hasPrefix("who") || q.hasPrefix("when")
            || q.hasPrefix("where") || q.hasPrefix("is ") || q.hasPrefix("can ")
            || q.hasPrefix("does ") || q.hasPrefix("do ")
        guard !looksLikeQuestion else { return false }

        let target: (bundleId: String, appName: String)? = {
            if let contextApp, contextApp.resultType == .application {
                let bundleIdFromPath =
                    contextApp.appPath.isEmpty
                    ? nil
                    : Bundle(path: contextApp.appPath)?.bundleIdentifier
                let bundleIdFromRunning = NSWorkspace.shared.runningApplications.first(where: {
                    !$0.isTerminated && $0.localizedName == contextApp.name
                })?.bundleIdentifier
                if let bundleId = bundleIdFromPath ?? bundleIdFromRunning, !bundleId.isEmpty {
                    return (bundleId, contextApp.name)
                }
            }
            let meta = smartQueryMeta
            if !meta.appPath.isEmpty,
                let bundleId = Bundle(path: meta.appPath)?.bundleIdentifier,
                !bundleId.isEmpty
            {
                return (bundleId, meta.label)
            }
            if let entry = settings.customAppEntries.first(where: { $0.key == activeKey }),
                let bundleId = Bundle(path: entry.appPath)?.bundleIdentifier,
                !bundleId.isEmpty
            {
                return (bundleId, entry.label)
            }
            return nil
        }()

        guard let target,
            target.bundleId != "scope://clipboard",
            GlobalContextEngine.shared.hasMenuSnapshot(bundleIdentifier: target.bundleId)
        else { return false }

        let matches = GlobalContextEngine.shared.cachedMenuItems(
            bundleIdentifier: target.bundleId,
            appName: target.appName,
            processIdentifier: 0,
            query: query,
            maxResults: 8
        )
        guard let picked = highConfidenceMenuCandidate(from: matches, query: query) else {
            return false
        }

        Task {
            let app = await activateOrLaunchSemanticApp(
                bundleIdentifier: target.bundleId,
                appName: target.appName
            )
            guard let app else {
                await MainActor.run {
                    remPanelChatMessages.append(
                        AIChatMessage(
                            role: .assistant,
                            content: "I couldn't open \(target.appName) to run that menu action.",
                            isError: true
                        )
                    )
                    remPanelIsProcessing = false
                }
                return
            }
            AXActionResolver.shared.execute(menuPath: picked.path, in: app)
            await MainActor.run {
                remPanelChatMessages.append(
                    AIChatMessage(role: .assistant, content: "✅ \(picked.pathString)")
                )
                remPanelIsProcessing = false
                searchState.query = ""
            }
        }
        return true
    }

    func highConfidenceMenuCandidate(from items: [AXMenuItem], query: String) -> AXMenuItem?
    {
        let q = AppMenuCapabilityCache.normalize(query)
        let tokens = q.split(separator: " ").map(String.init).filter { $0.count > 2 }
        let scored = items.compactMap { item -> (AXMenuItem, Int)? in
            let title = AppMenuCapabilityCache.normalize(item.title)
            let path = AppMenuCapabilityCache.normalize(item.pathString)
            var score = 0
            if title == q {
                score += 100
            } else if title.hasPrefix(q) {
                score += 75
            } else if title.contains(q) {
                score += 55
            } else if path.contains(q) {
                score += 35
            }
            for token in tokens {
                if title == token {
                    score += 40
                } else if title.hasPrefix(token) {
                    score += 28
                } else if title.contains(token) {
                    score += 18
                } else if path.contains(token) {
                    score += 10
                }
            }
            if !item.isEnabled { score = max(0, score - 20) }
            guard score >= 40 else { return nil }
            return (item, score)
        }.sorted { $0.1 > $1.1 }
        return scored.first?.0
    }

    /// Fallback for Ollama (no tool_use): ask AI to output a rem command, then run it directly.
    func handleRemPanelQueryLegacy(
        query: String, systemPrompt: String, provider: AIProvider, apiKey: String?
    ) async {
        let legacySystemMsg =
            systemPrompt
            + "\n\nIMPORTANT: Respond with ONLY the exact shell command to run (starting with `rem`), nothing else.\nExample: rem add \"buy milk\" --due \"tomorrow at 9am\""
        let historyWithSystem: [ChatMessage] = [
            ChatMessage(role: .system, content: legacySystemMsg)
        ]
        do {
            let response = try await AIProviderService.shared.sendMessage(
                query,
                context: .none,
                provider: provider,
                apiKey: apiKey,
                conversationHistory: historyWithSystem
            )
            // Extract the rem command from the AI response
            let lines = response.components(separatedBy: .newlines)
            let cmd =
                lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("rem ") })
                ?? lines.first(where: { $0.contains("rem ") })
                ?? ""
            let remCmd = cmd.trimmingCharacters(in: .init(charactersIn: "`\" "))
            if remCmd.isEmpty {
                await MainActor.run {
                    remPanelChatMessages.append(
                        AIChatMessage(
                            role: .assistant,
                            content:
                                "I couldn't figure out the right rem command. Try being more specific, e.g. \"add buy milk tomorrow at 9am\""
                        ))
                    remPanelIsProcessing = false
                }
                return
            }
            let (success, output) = await TerminalAIBridge.shared.processAICommand(
                remCmd, purpose: "rem")
            await MainActor.run {
                let reply =
                    success
                    ? "✅ Done! Ran: `\(remCmd)`\n\(output.isEmpty ? "" : output)"
                    : "❌ Failed: `\(remCmd)`\n\(output)"
                remPanelChatMessages.append(
                    AIChatMessage(role: .assistant, content: reply, isError: !success))
                remPanelIsProcessing = false
                searchState.appPanelAllItems = []
                reloadAppPanelData(for: "reminders")
            }
        } catch {
            await MainActor.run {
                remPanelChatMessages.append(
                    AIChatMessage(
                        role: .assistant,
                        content: "⚠️ \(error.localizedDescription)", isError: true))
                remPanelIsProcessing = false
            }
        }
    }

    func checkRemInstalled() {
        Task {
            // Check known install paths directly — app doesn't inherit shell PATH
            let home = NSHomeDirectory()
            let knownPaths = [
                "/usr/local/bin/rem",
                "/opt/homebrew/bin/rem",
                "\(home)/.local/bin/rem",
                "\(home)/go/bin/rem",
                "\(home)/.cargo/bin/rem",
                "\(home)/bin/rem",
            ]
            let fm = FileManager.default
            if knownPaths.contains(where: { fm.fileExists(atPath: $0) }) {
                await MainActor.run { remIsInstalled = true }
                return
            }
            // Fallback: login shell which — loads user's full PATH
            let proc = Process()
            proc.launchPath = "/bin/bash"
            proc.arguments = ["-l", "-c", "which rem"]
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            try? proc.run()
            proc.waitUntilExit()
            await MainActor.run { remIsInstalled = proc.terminationStatus == 0 }
        }
    }

    func installRem() {
        // Copy install command to clipboard — user runs it in their own terminal
        // (curl|bash is blocked by TerminalAIBridge security policy, correctly so)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            "curl -fsSL https://rem.sidv.dev/install | bash", forType: .string)
        remPanelChatMessages.append(
            AIChatMessage(
                role: .assistant,
                content:
                    "📋 Install command copied to clipboard!\n\nPaste it in Terminal:\n```\ncurl -fsSL https://rem.sidv.dev/install | bash\n```\nAnswer **n** when asked about the AI agent skill — ILauncher uses your selected provider (\(AppSettings.shared.selectedAIProvider.shortName)) instead.\n\nAlternatively: open ILauncher terminal → type \"install rem\" → AI will handle it."
            ))
    }

    func isAffirmativeResponse(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let positives = [
            "yes", "y", "ok", "okay", "sure", "do it", "go ahead", "run it", "execute", "confirm",
        ]
        return positives.contains(where: { normalized == $0 })
    }

    func isNegativeResponse(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let negatives = ["no", "n", "stop", "cancel", "don't", "do not", "nah"]
        return negatives.contains(where: { normalized == $0 })
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

        func matchScore(_ ruleName: String) -> Int {
            let n = ruleName.lowercased()
            if n == q { return 100 }
            if q.contains(n) || n.contains(q) { return 80 }
            let nameWords = n.components(separatedBy: " ").filter { !$0.isEmpty }
            let queryWords = q.components(separatedBy: " ").filter { !$0.isEmpty }
            let hits = nameWords.filter { nw in
                queryWords.contains { qw in qw.contains(nw) || nw.contains(qw) }
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
        guard let cmd = SystemCommandsRegistry.shared.bestMatch(for: query) else { return false }
        AppToast.show(
            "Running \(cmd.name)…", icon: "bolt.fill", tint: .blue.opacity(0.9), duration: 2.0,
            centered: true)
        searchState.query = ""
        let ctx = AXContextReader.shared.current
        let envVars: [String: String] = [
            "CD_QUERY": query,
            "CD_URL": ctx.currentURL ?? SafariBrowserBridge.shared.currentContext()?.url ?? "",
            "CD_TEXT": ctx.selectedText ?? "",
            "CD_APP": ctx.appName,
        ]
        switch cmd.scriptType.lowercased() {
        case "applescript":
            AXTriggerRuleEngine.shared.run(type: .appleScript, value: cmd.script, envVars: envVars)
        default:
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("syscmd_\(UUID().uuidString).sh")
            try? cmd.script.write(to: tmp, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: tmp.path)
            AXTriggerRuleEngine.shared.run(type: .scriptFile, value: tmp.path, envVars: envVars)
        }
        return true
    }

    func handleL2Query(_ query: String, skipMenuRouter: Bool) {
        guard !query.isEmpty else { return }
        if handleL2TaskControlQueryIfNeeded(query) {
            return
        }
        if let findToken = lockedFindToken {
            executeFindToken(findToken, userMessage: "find \(query)")
            return
        }
        if tryExecuteTriggerRuleByName(query) { return }
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

        // ── Route to global context when user has a selection ─────────────────
        // Text selected, files selected, folders selected → user wants to TALK
        // about that content, not trigger a menu action. Activate global context
        // so the AI gets the selection as its primary subject.
        if hasActiveSelection && !isGlobalContextActive && !isExplicitAppScopeLocked {
            globalContextActivation = GlobalContextActivation(autoActivated: true)
        }

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

        if let findIntent = resolvedFindIntent(
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
        //   • User has NO active selection (selection → global context chat, not menu click)
        //   • Query does NOT look like a question (questions → AI answer, not menu click)
        //   • App has a cached menu snapshot to search
        let menuRouteEligible =
            !skipMenuRouter
            && !hasActiveSelection  // selection = user wants to chat, not click menus
            && !looksLikeQuestion  // question  = user wants an AI answer
            && !isGlobalContextActive  // global context already active = chat mode
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

        if let transformIntent = transformShareIntent(for: query) {
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

        if !shouldSkipCrossAppMailRouting,
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

        detectAndUpdateContext()

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
                    Task.detached(priority: .userInitiated) {
                        AXWebReader.shared.refresh(pid: pid, currentURL: liveURL)
                    }
                }
            }
        }

        // Fast-path: Safari NL commands ("search youtube for X", "close tab", etc.) skip AI entirely
        if frontmost.bundleID == "com.apple.Safari"
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
        let rawKey = AppSettings.shared.getAPIKey(for: provider)
        let apiKey: String? = rawKey.isEmpty ? nil : rawKey

        // Guard: if a cloud provider is selected but has no key, show guidance now — don't wait for a network error
        if provider != .onDevice && provider != .shortcuts && apiKey == nil {
            l2.isLoading = false
            let guide = QueryFailureGuide.shared.instant(
                for: .noAPIKey(provider: provider.shortName), originalQuery: query
            )
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
                print("🧠 [L2 AI] Provider: \(provider.shortName), direct message path")

                if provider != .onDevice && provider != .shortcuts {
                    let finalResponse = try await AIProviderService.shared.sendMessage(
                        query,
                        context: effectiveConversationUserContext,
                        provider: provider,
                        apiKey: apiKey,
                        conversationHistory: chatHistory,
                        additionalContextPrompt: finalContextPrompt
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
        switch settings.selectedAIProvider {
        case .onDevice:
            // Pass raw query — buildContextPrompt inside sendOnDevice builds context via the `context` parameter.
            // Pre-building context here would double it and overflow Foundation Models' context window.
            let dateHeader = currentDateTimeContextBlock()
            let onDeviceMsg = dateHeader.isEmpty ? query : "\(dateHeader)\n\nUser request: \(query)"
            return try await AIProviderService.shared.sendOnDevice(
                onDeviceMsg,
                context: effectiveConversationUserContext
            )
        case .openAI:
            return try await sendToOpenAI(query: query, context: context, imageFiles: imageFiles)
        case .googleGemini:
            return try await sendToGemini(query: query, context: context, imageFiles: imageFiles)
        case .anthropic:
            return try await sendToAnthropic(query: query, context: context, imageFiles: imageFiles)
        case .ollama:
            return try await sendToOllama(query: query, context: context)
        case .shortcuts:
            return try await sendToShortcuts(query: query, context: context)
        }
    }

    // MARK: - Process AI Response (Simplified for quick queries only)

    // MARK: - AI Provider Implementations

    func sendToOnDeviceAI(query: String, context: [[String: String]]) async throws -> String
    {
        // On-device AI using Apple's Foundation Models framework
        // This requires macOS 26.0+ (macOS Tahoe) and Apple Silicon

        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                do {
                    print("🤖 On-Device AI: Starting request...")

                    // Import at runtime to avoid compilation issues on older macOS
                    let session = LanguageModelSession()

                    // Build the prompt with context, using custom system prompt
                    var fullPrompt = ""

                    // Add custom system prompt if not empty, otherwise use context system message
                    let useCustomPrompt = !settings.onDeviceSystemPrompt.isEmpty
                    if useCustomPrompt {
                        print(
                            "🤖 Using custom system prompt (\(settings.onDeviceSystemPrompt.count) chars)"
                        )
                        fullPrompt += "system: \(settings.onDeviceSystemPrompt)\n"
                    }

                    // Add conversation history (skip system message from context if we used custom)
                    for msg in context {
                        let role = msg["role"] ?? "user"
                        let content = msg["content"] ?? ""

                        // Skip system message if we already added custom prompt
                        if useCustomPrompt && role == "system" {
                            continue
                        }

                        fullPrompt += "\(role): \(content)\n"
                    }

                    fullPrompt += "user: \(query)\nassistant:"

                    print("🤖 On-Device AI: Sending prompt (length: \(fullPrompt.count))")

                    let response = try await session.respond(to: fullPrompt)
                    print("🤖 On-Device AI: Response received successfully")
                    return response.content
                } catch {
                    print("❌ On-Device AI Error: \(error.localizedDescription)")
                    print("❌ Full error: \(error)")
                    // Return user-friendly error instead of throwing
                    return
                        "On-Device AI encountered an error: \(error.localizedDescription)\n\nPlease try:\n1. Checking your internet connection (may be needed for initial model download)\n2. Ensuring Apple Intelligence is enabled in System Settings\n3. Using a different AI provider in Settings"
                }
            } else {
                return
                    "On-device AI requires macOS 26.0 (Tahoe) or later with Apple Silicon. Your current macOS version does not support this feature. Please select a different AI provider in Settings."
            }
        #else
            // Foundation Models framework not available
            return
                "On-device AI (Apple Intelligence) is not available on this version of macOS. This feature requires macOS 26.0 (Tahoe) or later with Apple Silicon. Please select a different AI provider in Settings, such as:\n\n• **Ollama** - Free, runs locally on your Mac\n• **Google Gemini** - Requires API key\n• **OpenAI ChatGPT** - Requires API key\n• **Anthropic Claude** - Requires API key"
        #endif
    }

    func sendToOpenAI(query: String, context: [[String: String]]) async throws -> String {
        return try await sendToOpenAI(query: query, context: context, imageFiles: [])
    }

    func sendToOpenAI(query: String, context: [[String: String]], imageFiles: [URL])
        async throws -> String
    {
        guard !settings.openAIAPIKey.isEmpty else {
            throw AIError.noAPIKey
        }

        // TODO: Add vision support for OpenAI (gpt-4-vision-preview)
        // For now, just use text-only

        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var messages = context
        messages.append(["role": "user", "content": query])

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": messages,
            "max_tokens": 1000,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await AIProviderService.directSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AIError.requestFailed
        }

        struct OpenAIResponse: Codable {
            struct Choice: Codable {
                struct Message: Codable {
                    let content: String
                }
                let message: Message
            }
            let choices: [Choice]
        }

        let result = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        return result.choices.first?.message.content ?? "No response received."
    }

    func sendToGemini(query: String, context: [[String: String]]) async throws -> String {
        return try await sendToGemini(query: query, context: context, imageFiles: [])
    }

    func sendToGemini(query: String, context: [[String: String]], imageFiles: [URL])
        async throws -> String
    {
        guard !settings.googleGeminiAPIKey.isEmpty else {
            throw AIError.noAPIKey
        }

        let url = URL(
            string:
                "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"
        )!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.googleGeminiAPIKey, forHTTPHeaderField: "x-goog-api-key")

        // Build conversation history
        var parts: [[String: Any]] = []
        for msg in context {
            parts.append(["text": msg["content"] ?? ""])
        }
        parts.append(["text": query])

        let body: [String: Any] = [
            "contents": [["parts": parts]]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await AIProviderService.directSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.requestFailed
        }
        if httpResponse.statusCode == 429 {
            throw AIError.rateLimited
        } else if httpResponse.statusCode != 200 {
            let errBody = String(data: data, encoding: .utf8) ?? "no body"
            print("❌ Gemini error \(httpResponse.statusCode): \(errBody)")
            throw AIError.requestFailed
        }

        struct GeminiResponse: Codable {
            struct Candidate: Codable {
                struct Content: Codable {
                    struct Part: Codable {
                        let text: String
                    }
                    let parts: [Part]
                }
                let content: Content
            }
            let candidates: [Candidate]
        }

        let result = try JSONDecoder().decode(GeminiResponse.self, from: data)
        return result.candidates.first?.content.parts.first?.text ?? "No response received."
    }

    func sendToAnthropic(query: String, context: [[String: String]], imageFiles: [URL] = [])
        async throws -> String
    {
        guard !settings.anthropicAPIKey.isEmpty else {
            throw AIError.noAPIKey
        }

        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(settings.anthropicAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var messages: [[String: Any]] = []
        for msg in context {
            messages.append(["role": msg["role"] ?? "user", "content": msg["content"] ?? ""])
        }

        // Build the final user message with images if provided
        var finalMessageContent: [[String: Any]] = []

        // Add images first
        for imageFile in imageFiles {
            if let imageData = try? Data(contentsOf: imageFile) {
                let base64Image = imageData.base64EncodedString()
                let ext = imageFile.pathExtension.lowercased()
                let mediaType: String
                switch ext {
                case "png": mediaType = "image/png"
                case "jpg", "jpeg": mediaType = "image/jpeg"
                case "gif": mediaType = "image/gif"
                case "webp": mediaType = "image/webp"
                default: mediaType = "image/jpeg"
                }

                finalMessageContent.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": mediaType,
                        "data": base64Image,
                    ],
                ])
            }
        }

        // Add text query
        finalMessageContent.append([
            "type": "text",
            "text": query,
        ])

        messages.append(["role": "user", "content": finalMessageContent])

        // Use a vision-capable model if images are present
        let model = imageFiles.isEmpty ? "claude-3-haiku-20240307" : "claude-3-5-sonnet-20241022"

        let body: [String: Any] = [
            "model": model,
            "max_tokens": imageFiles.isEmpty ? 1000 : 2000,
            "messages": messages,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await AIProviderService.directSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            if let httpResponse = response as? HTTPURLResponse {
                print("❌ Anthropic API error: \(httpResponse.statusCode)")
                if let errorString = String(data: data, encoding: .utf8) {
                    print("Error response: \(errorString)")
                }
            }
            throw AIError.requestFailed
        }

        struct AnthropicResponse: Codable {
            struct Content: Codable {
                let text: String
            }
            let content: [Content]
        }

        let result = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        return result.content.first?.text ?? "No response received."
    }

    func sendToOllama(query: String, context: [[String: String]]) async throws -> String {
        guard !settings.ollamaEndpoint.isEmpty else {
            throw AIError.noEndpoint
        }
        guard !settings.selectedOllamaModel.isEmpty else {
            throw AIError.noModel
        }

        let endpoint = settings.ollamaEndpoint.trimmingCharacters(in: .whitespaces)
        let url = URL(string: "\(endpoint)/api/chat")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var messages: [[String: String]] = []
        for msg in context {
            messages.append(["role": msg["role"] ?? "user", "content": msg["content"] ?? ""])
        }
        messages.append(["role": "user", "content": query])

        let body: [String: Any] = [
            "model": settings.selectedOllamaModel,
            "messages": messages,
            "stream": false,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await AIProviderService.directSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AIError.requestFailed
        }

        struct OllamaResponse: Codable {
            struct Message: Codable {
                let content: String
            }
            let message: Message
        }

        let result = try JSONDecoder().decode(OllamaResponse.self, from: data)
        return result.message.content
    }

    func sendToShortcuts(query: String, context: [[String: String]]) async throws -> String
    {
        // Check if a shortcut is configured
        guard !settings.shortcutsProviderShortcut.isEmpty else {
            return
                "⚠️ No shortcut configured for Shortcuts provider.\n\nPlease select a shortcut in Settings → AI Provider to use this feature."
        }

        // Run the shortcut on a background thread to avoid blocking
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // First, ensure Shortcuts app is running and ready
                let workspace = NSWorkspace.shared
                let isRunning = workspace.runningApplications.contains(where: {
                    $0.bundleIdentifier == "com.apple.shortcuts"
                })

                if !isRunning {
                    print("⚠️ Shortcuts app not running, launching and activating...")

                    // Use AppleScript to launch and activate the app, which ensures it's ready
                    let launchScript = """
                        tell application "Shortcuts"
                            launch
                            activate
                        end tell
                        """

                    var launchError: NSDictionary?
                    if let launchScriptObject = NSAppleScript(source: launchScript) {
                        launchScriptObject.executeAndReturnError(&launchError)

                        if launchError != nil {
                            print("⚠️ Failed to launch Shortcuts app via AppleScript")
                        } else {
                            print("✅ Shortcuts app launched and activated")
                            // Wait for app to be fully ready
                            Thread.sleep(forTimeInterval: 2.0)
                        }
                    }
                } else {
                    print("✅ Shortcuts app already running")
                }

                // Escape the query for AppleScript - more thorough escaping
                let escapedQuery =
                    query
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: "\\n")
                    .replacingOccurrences(of: "\r", with: "\\r")

                print(
                    "🔵 Running shortcut: '\(self.settings.shortcutsProviderShortcut)' with input: '\(query)'"
                )

                // Try using the direct Shortcuts app scripting (not Shortcuts Events)
                let script = """
                    tell application "Shortcuts"
                        set theResult to run shortcut "\(self.settings.shortcutsProviderShortcut)" with input "\(escapedQuery)"
                        return theResult as text
                    end tell
                    """

                var error: NSDictionary?
                guard let scriptObject = NSAppleScript(source: script) else {
                    continuation.resume(returning: "⚠️ Failed to create AppleScript object")
                    return
                }

                print("⏳ Executing AppleScript...")
                let output = scriptObject.executeAndReturnError(&error)

                if let error = error {
                    print("❌ AppleScript error: \(error)")
                    let errorMessage =
                        error["NSAppleScriptErrorMessage"] as? String ?? "Unknown error"
                    let errorNumber = error["NSAppleScriptErrorNumber"] as? Int ?? 0

                    // If we get error -600, try one more time with a longer delay
                    if errorNumber == -600 {
                        print("⚠️ Got error -600, waiting longer and retrying...")
                        Thread.sleep(forTimeInterval: 2.0)

                        // Retry
                        var retryError: NSDictionary?
                        let retryOutput = scriptObject.executeAndReturnError(&retryError)
                        if let retryErr = retryError {
                            let retryErrorMsg =
                                retryErr["NSAppleScriptErrorMessage"] as? String ?? "Unknown error"
                            let result = """
                                ⚠️ Error running shortcut '\(self.settings.shortcutsProviderShortcut)' (Error \(errorNumber)):

                                \(retryErrorMsg)

                                Make sure:
                                • The shortcut exists in your Shortcuts app
                                • It accepts text input
                                • It returns a text result
                                • Automation permission is granted in System Settings → Privacy & Security → Automation
                                • ILauncher has permission to control Shortcuts
                                """
                            continuation.resume(returning: result)
                            return
                        } else if let result = retryOutput.stringValue, !result.isEmpty {
                            print("✅ Shortcut returned (after retry): \(result.prefix(100))...")
                            continuation.resume(returning: result)
                            return
                        }
                    }

                    let result = """
                        ⚠️ Error running shortcut '\(self.settings.shortcutsProviderShortcut)' (Error \(errorNumber)):

                        \(errorMessage)

                        Make sure:
                        • The shortcut exists in your Shortcuts app
                        • It accepts text input
                        • It returns a text result
                        • Automation permission is granted in System Settings → Privacy & Security → Automation
                        """
                    continuation.resume(returning: result)
                    return
                }

                // Get the result from the AppleScript output
                if let result = output.stringValue, !result.isEmpty {
                    print("✅ Shortcut returned: \(result.prefix(100))...")
                    continuation.resume(returning: result)
                } else {
                    print("⚠️ Shortcut returned empty or nil result")
                    print("⚠️ Output descriptor: \(output)")
                    let result = """
                        ⚠️ Shortcut '\(self.settings.shortcutsProviderShortcut)' ran but returned no output.

                        Make sure your shortcut:
                        • Returns a text result
                        • Uses 'Stop and Output' or 'Return' action with text
                        • Doesn't just show an alert or notification
                        """
                    continuation.resume(returning: result)
                }
            }
        }
    }

    // Meta info for the active smart query app panel
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
