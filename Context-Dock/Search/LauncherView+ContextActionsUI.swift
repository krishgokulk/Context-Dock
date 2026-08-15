import AddressBook
import AppIntents
import AppKit
import Combine
import Contacts
import Darwin
import FoundationModels
import PDFKit
import Quartz
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers
import Vision

extension LauncherView {
    // MARK: - AI Extension Quick Actions (now shown in dock on swipe up)
    @ViewBuilder
    var aiExtensionQuickActions: some View {
        // AI extensions now show inside dock on swipe up, not here
        EmptyView()
    }

    // MARK: - AI Mode Controls
    @ViewBuilder
    var aiModeControls: some View {
        HStack(spacing: 6) {
            // Attachment chips (files/images pending to send)
            ForEach(aiMode.attachments, id: \.absoluteString) { url in
                HStack(spacing: 3) {
                    Image(
                        systemName: url.pathExtension.lowercased().matches(
                            of: /jpg|jpeg|png|heic|gif|webp/
                        ).isEmpty ? "doc.fill" : "photo.fill"
                    )
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.blue.opacity(0.8))
                    Text(url.lastPathComponent)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.75))
                        .lineLimit(1)
                        .frame(maxWidth: 80)
                    Button {
                        aiMode.attachments.removeAll { $0 == url }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.blue.opacity(0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.blue.opacity(0.25), lineWidth: 0.5))
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }

            // Attach menu: file / photo / screenshot / capture area
            Menu {
                Button {
                    attachAIFiles(imagesOnly: false)
                } label: { Label("Upload File", systemImage: "doc") }
                Button {
                    attachAIFiles(imagesOnly: true)
                } label: { Label("Upload Photo", systemImage: "photo") }
                Divider()
                Button {
                    captureScreenshotToAttachments(interactive: false) { url in
                        withAnimation { aiMode.attachments.append(url) }
                    }
                } label: { Label("Take Screenshot", systemImage: "camera.viewfinder") }
                Button {
                    captureScreenshotToAttachments(interactive: true, windowFirst: true) { url in
                        withAnimation { aiMode.attachments.append(url) }
                    }
                } label: { Label("Capture Area", systemImage: "crop") }
                Button {
                    captureScreenText { text in
                        let existing = aiMode.selectionText?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        aiMode.selectionText = existing.isEmpty
                            ? text : existing + "\n\n" + text
                    }
                } label: { Label("Capture Text", systemImage: "text.viewfinder") }
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary.opacity(aiMode.attachments.isEmpty ? 0.6 : 0.9))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Attach file, photo, or screenshot")

            // App icon: compact, independently scrollable picker for chat focus.
            Button {
                isShowingChatFocusAppPicker.toggle()
            } label: {
                Image(systemName: "app.badge")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary.opacity(0.6))
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Add running apps")
            .popover(isPresented: $isShowingChatFocusAppPicker, arrowEdge: .top) {
                chatFocusAppPicker
            }

            // "/" filter: the matches replace the focus chips while it is active, so the
            // capsule shows one thing at a time — what you have, or what you are choosing.
            if generalChatSlashFilter != nil {
                generalChatSlashAppCapsule
            } else if !chatFocusApps.isEmpty {
                HStack(spacing: 5) {
                    ForEach(chatFocusApps) { focusedApp in
                        Button {
                            chatFocusApps.removeAll { $0.bundleId == focusedApp.bundleId }
                        } label: {
                            ZStack {
                                AppBundleIconView(
                                    bundleId: focusedApp.bundleId,
                                    fallbackSymbol: "app.dashed",
                                    size: 18,
                                    cornerRadius: 4
                                )
                                .opacity(
                                    hoveredChatFocusBundleId == focusedApp.bundleId ? 0.22 : 1
                                )

                                if hoveredChatFocusBundleId == focusedApp.bundleId {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.primary)
                                }
                            }
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(focusedApp.name)")
                        .onHover { hovering in
                            withAnimation(.easeOut(duration: 0.1)) {
                                hoveredChatFocusBundleId = hovering
                                    ? focusedApp.bundleId : nil
                            }
                        }
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
            }

            // Artifact button: the answer built a chart, table or diagram, and this strip
            // can only show its source. One press moves the thread to the window, which
            // renders it beside the conversation.
            if generalChatArtifact != nil {
                Button(action: openGeneralChatArtifactInWindow) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor.opacity(0.9))
                        .frame(width: 22, height: 22)
                        .background(Color.accentColor.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Show what this answer built")
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }

            // Clear chat button
            if !aiMode.messages.isEmpty {
                Button(action: {
                    withAnimation {
                        aiMode.messages.removeAll()
                    }
                    aiMode.streamingId = nil
                    aiMode.isLoading = false
                    aiMode.attachments = []
                    aiMode.selectionText = nil
                    aiMode.selectionFiles = []
                    aiMode.selectionURL = nil
                    aiMode.pendingShare = nil
                    generalChatArtifact = nil
                    hasUserSentMessageInCurrentSession = false
                    clearGeneralAIConversation()
                    AIProviderService.shared.resetOnDeviceSession()
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear chat")
            }
        }
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: aiMode.attachments.count)
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: generalChatArtifact)
    }

    @ViewBuilder
    var chatFocusAppPicker: some View {
        // Shared with the composer bar's picker: one list, one source, one set of states,
        // so choosing an app is the same interaction wherever the chat is. Finder leads
        // it — see ChatAppDirectory.
        ScopedAppPickerList(
            rows: ScopedAppPickerRow.allApps(),
            selectedIDs: Set(chatFocusApps.map { $0.bundleId.lowercased() })
        ) { row in
            if chatFocusApps.contains(where: { $0.bundleId == row.bundleId }) {
                chatFocusApps.removeAll { $0.bundleId == row.bundleId }
            } else {
                chatFocusApps.append(.init(name: row.name, bundleId: row.bundleId))
            }
        }
    }


    /// Open the file picker and append the chosen files to the AI chat attachments.
    func attachAIFiles(imagesOnly: Bool) {
        let picked = pickFilesForChatAttachment(imagesOnly: imagesOnly)
        guard !picked.isEmpty else { return }
        withAnimation {
            aiMode.attachments.append(contentsOf: picked.filter { !aiMode.attachments.contains($0) })
        }
    }

    /// Open panel that returns the chosen file URLs — shared by the general chat and
    /// the frontmost-app chat + menus.
    func pickFilesForChatAttachment(imagesOnly: Bool) -> [URL] {
        ChatAttachmentCapture.pickFiles(imagesOnly: imagesOnly)
    }

    /// Capture a screenshot and hand the PNG to `append`. See ChatAttachmentCapture
    /// for the modes — the implementation is shared with the chat window's "+" menu.
    func captureScreenshotToAttachments(
        interactive: Bool, windowFirst: Bool = false, append: @escaping (URL) -> Void
    ) {
        ChatAttachmentCapture.captureScreenshot(
            interactive: interactive, windowFirst: windowFirst, append: append)
    }

    /// Select a screen region, recognize its text locally with Vision, copy the
    /// result to the clipboard, and return it to the active AI surface.
    func captureScreenText(append: @escaping (String) -> Void) {
        ChatAttachmentCapture.captureScreenText(append: append)
    }

    var providerColor: SwiftUI.Color {
        switch settings.selectedAIProvider {
        case .onDevice: return .purple
        case .googleGemini: return .blue
        case .openAI: return .green
        case .anthropic: return .orange
        case .claudeBridge: return .purple
        case .chatGPTBridge: return .green
        case .ollama: return .cyan
        case .openAICompatible: return .mint
        case .kimi: return .blue
        case .shortcuts: return .indigo
        }
    }

    func copyAIResponse() {
        guard let lastAssistantMessage = aiMode.messages.last(where: { $0.role == .assistant })
        else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lastAssistantMessage.content, forType: .string)
    }

    // MARK: - Context Chip Section
    @ViewBuilder
    var contextChipSection: some View {
        // Only show if context awareness is enabled
        if settings.enableContextAIExtensions {
            // Only show if we have a meaningful context (not just "none")
            let shouldShowContext: Bool = {
                switch currentContext {
                case .filesSelected(let urls):
                    return !urls.isEmpty
                case .textSelected(let text):
                    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .url(let urlString):
                    return !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .appFocused, .contactSelected:
                    return false  // Don't show chips for app/contact context for now
                case .none:
                    return false
                }
            }()

            // Get suggested shortcuts — passive context only (not while typing).
            // Showing them while typing would expand the window on every keystroke,
            // interrupting the user's search flow. They appear when idle with detected context.
            let suggestedShortcuts: [SearchResult] = {
                guard searchState.query.isEmpty && shouldShowContext else { return [] }
                return allShortcuts.filter { shortcut in
                    guard let metadata = shortcutMetadataCache[shortcut.title] else { return false }
                    return metadata.matches(context: currentContext)
                }
            }()

            if shouldShowContext && !suggestedShortcuts.isEmpty {
                // Beautiful card-style context display (like macOS 26 Spotlight)
                VStack(spacing: 0) {
                    // Context header with icon and description
                    HStack(spacing: 12) {
                        // Context icon in a pill
                        HStack(spacing: 6) {
                            Image(systemName: currentContext.icon)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.blue)
                            Text(getContextActionTitle())
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color.blue.opacity(0.1))
                        )

                        Spacer()

                        // Context detail text
                        Text(getContextDetailText())
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                    Divider()
                        .padding(.horizontal, 20)

                    // Suggested shortcuts section
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(suggestedShortcuts.prefix(3)) { shortcut in
                            Button(action: {
                                executeResult(shortcut)
                            }) {
                                HStack(spacing: 12) {
                                    // Shortcut icon
                                    if let icon = shortcut.icon {
                                        Image(nsImage: icon)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(width: 28, height: 28)
                                    } else {
                                        Image(systemName: "bolt.fill")
                                            .font(.system(size: 14))
                                            .foregroundStyle(.orange)
                                            .frame(width: 28, height: 28)
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(shortcut.title)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(.primary)
                                        Text(shortcut.subtitle)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.clear)
                            )
                            .onHover { hovering in
                                // Optional: Add hover effect
                            }

                            if shortcut.id != suggestedShortcuts.prefix(3).last?.id {
                                Divider()
                                    .padding(.horizontal, 20)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.95).combined(with: .opacity),
                        removal: .scale(scale: 0.95).combined(with: .opacity)
                    ))
            }
        }
    }

    // Helper functions for context display
    func getContextActionTitle() -> String {
        switch currentContext {
        case .filesSelected(let urls):
            return urls.count == 1 ? "Send" : "Send \(urls.count) files"
        case .textSelected:
            return "Send"
        case .url:
            return "Send"
        case .appFocused, .contactSelected, .none:
            return "Action"
        }
    }

    func getContextDetailText() -> String {
        switch currentContext {
        case .filesSelected(let urls):
            if urls.count == 1 {
                return urls[0].lastPathComponent
            } else {
                return "\(urls.count) files selected"
            }
        case .textSelected(let text):
            let preview = text.prefix(50)
            return "\"\(preview)\(text.count > 50 ? "..." : "")\""
        case .url(let urlString):
            let preview = urlString.prefix(50)
            return "\"\(preview)\(urlString.count > 50 ? "..." : "")\""
        case .appFocused, .contactSelected, .none:
            return ""
        }
    }

    @ViewBuilder
    var l2ResultsPopoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(dockHeaderDisplayName)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !l2.chatMessages.isEmpty {
                    Button("Clear") {
                        l2.chatMessages = []
                        l2.isLoading = false
                        l2.activeRequestID = nil
                        l2.currentTask?.cancel()
                        l2.currentTask = nil
                        l2.showChatPopover = false
                        l2.chatArmed = false
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider().padding(.horizontal, 8)

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(l2.chatMessages) { message in
                        if message.role == .approval {
                            l2InlineApprovalCard(message)
                        } else if message.hasInstallButton {
                            AIChatMessageView(
                                message: message,
                                onInstallExtension: installSuggestedExtension,
                                onInstallProposal: { json in installFromProposal(json) },
                                onRunOnceProposal: { json in runOnceFromProposal(json) },
                                onPickAction: { choice in
                                    runPickedActionChoice(choice, inDock: true)
                                },
                                onReminderAction: { reminder, operation in
                                    offerReminderRowAction(reminder, operation: operation)
                                }
                            )
                        } else {
                            AIChatMessageView(
                                message: message,
                                onPickAction: { choice in
                                    runPickedActionChoice(choice, inDock: true)
                                },
                                onReminderAction: { reminder, operation in
                                    offerReminderRowAction(reminder, operation: operation)
                                }
                            )
                        }
                    }
                    if l2.isLoading { AILoadingView(status: l2.loadingStatus) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .frame(minHeight: 120, maxHeight: 420)
        }
        .frame(minWidth: 540, idealWidth: 600)
    }

    @ViewBuilder
    var finderFolderSearchPopoverContent: some View {
        let folderPath = currentFinderFolderPath()
        let folderName = URL(fileURLWithPath: folderPath).lastPathComponent
        let query = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(folderName.isEmpty ? "Current Folder Search" : folderName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if !query.isEmpty {
                    Text("Names + Content")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider().padding(.horizontal, 8)

            if query.isEmpty {
                Text("Type to search this Finder folder.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else if isFinderSemanticLoading && finderSemanticResults.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Searching filenames and indexed content in this folder…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .padding(.horizontal, 16)
            } else if finderSemanticResults.isEmpty {
                Text("No matches in this Finder folder.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(finderSemanticResults.enumerated()), id: \.element.id) {
                            _, result in
                            ResultRow(result: result, isSelected: false, isPinned: false)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    executeFinderFolderSearchResult(result)
                                }
                                .contextMenu {
                                    resultContextMenu(for: result)
                                }
                            Divider()
                                .padding(.leading, 56)
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 360)
            }
        }
        .frame(minWidth: 520, idealWidth: 560)
    }

    func executeFinderFolderSearchResult(_ result: SearchResult) {
        result.action()
        UsageTracker.shared.recordAccess(for: result.trackingIdentifier)
        l2.showResultsPopover = false
        searchState.query = ""
        searchState.selectedIndex = nil
        clearFinderSemanticState()
        hideLauncherAfterFinderAction()
    }

    // MARK: - Add Page Button (browser L2 research)

    @ViewBuilder
    var addPageButton: some View {
        let browserPID: pid_t = AppDelegate.shared?.previousFrontmostApp?.processIdentifier ?? 0
        let snap: PageSnapshot? = AXWebReader.shared.cachedSnapshot(for: browserPID)
        let alreadyAdded: Bool =
            snap.map { s in webResearch.pages.contains(where: { $0.url == s.url }) } ?? false
        Button(action: {
            if let s = snap {
                Task { @MainActor in WebResearchSession.shared.addPage(s) }
            } else {
                Task { @MainActor in
                    let url = AXContextReader.shared.current.currentURL ?? ""
                    AXWebReader.shared.refresh(pid: browserPID, currentURL: url)
                }
            }
        }) {
            ZStack {
                Circle()
                    .fill(alreadyAdded ? Color.green.opacity(0.3) : Color.white.opacity(0.12))
                    .frame(width: 22, height: 22)
                Image(systemName: alreadyAdded ? "checkmark" : "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .buttonStyle(.plain)
        .help(
            alreadyAdded
                ? "Page added to research"
                : snap != nil ? "Add page to research session" : "Tap to read page first")
    }

    // MARK: - Safari Tabs + Button (Extension-powered)

    /// Adds the current browser page to the web-research context (the webpage pill).
    /// Returns false when not in a browser or no fresh page is available, so the
    /// right-arrow handler can fall through to other behaviors.
    @discardableResult
    func addCurrentSafariPageToContextFromKeyboard() -> Bool {
        guard AXWebReader.shared.isBrowser(bundleId: frontmost.bundleID) else { return false }
        let bridge = SafariBrowserBridge.shared
        if bridge.isFresh, let ctx = bridge.latestContext, !ctx.url.isEmpty {
            attachBrowserPageSnapshotToCurrentChat(
                PageSnapshot(
                    url: ctx.url, text: ctx.pageTextForAI,
                    title: ctx.title, timestamp: ctx.timestamp))
            return true
        }

        let browserPID: pid_t = AppDelegate.shared?.previousFrontmostApp?.processIdentifier ?? 0
        if let snap = AXWebReader.shared.cachedSnapshot(for: browserPID),
            !snap.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            attachBrowserPageSnapshotToCurrentChat(snap)
            return true
        }

        guard let url = currentBrowserPageURL()?.absoluteString else { return false }
        let title = URL(string: url)?.host ?? frontmost.name
        attachBrowserPageSnapshotToCurrentChat(
            PageSnapshot(
                url: url, text: "",
                title: title, timestamp: Date()))
        if browserPID != 0 {
            AXWebReader.shared.refresh(pid: browserPID, currentURL: url)
        }
        return true
    }

    @ViewBuilder
    var safariTabsButton: some View {
        let addedCount = webResearch.count
        Button {
            showSafariTabPicker = true
            // Current tab is shown instantly from the extension bridge.
            // Load OTHER open tabs in background via AppleScript.
            safariTabPickerLoading = true
            Task {
                let tabs = await SafariTabManager.shared.fetchTabs()
                await MainActor.run {
                    safariTabPickerTabs = tabs
                    safariTabPickerLoading = false
                }
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "square.on.square")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.8))
                    .frame(width: 22, height: 22)
                if addedCount > 0 {
                    Text("\(addedCount)")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1.5)
                        .background(Color.blue, in: Capsule())
                        .offset(x: 8, y: -7)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.2, dampingFraction: 0.75), value: addedCount)
        .help(
            addedCount > 0 ? "\(addedCount) tab(s) added to context" : "Tabs — add current page (→)"
        )
        .popover(isPresented: showSafariTabPickerBinding, arrowEdge: .top) {
            safariTabPickerPopover
        }
    }

    @ViewBuilder
    var safariTabPickerPopover: some View {
        let bridge = SafariBrowserBridge.shared
        let currentCtx = bridge.isFresh ? bridge.latestContext : nil

        VStack(spacing: 0) {
            // ── Current page (instant, from extension — no loading) ──────────
            if let ctx = currentCtx {
                sectionLabel("CURRENT PAGE")
                safariTabRowFromExtension(ctx)
            }

            // ── Other open tabs (AppleScript, may still be loading) ──────────
            let otherTabs = safariTabPickerTabs.filter { $0.url != currentCtx?.url }
            if safariTabPickerLoading || !otherTabs.isEmpty {
                Divider().padding(.leading, currentCtx != nil ? 38 : 0)
                sectionLabel("OTHER TABS")
                if safariTabPickerLoading {
                    HStack {
                        Spacer()
                        ProgressView().scaleEffect(0.75).padding(.vertical, 12)
                        Spacer()
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(otherTabs) { tab in
                                safariTabRow(tab)
                                if tab.id != otherTabs.last?.id {
                                    Divider().padding(.leading, 38)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 260)
                }
            }

            // ── Empty state (extension not active, no tabs found yet) ────────
            if currentCtx == nil && !safariTabPickerLoading && safariTabPickerTabs.isEmpty {
                Text("No open tabs found")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(16)
            }
        }
        .frame(width: 300)
        .background(.regularMaterial)
    }

    @ViewBuilder
    func sectionLabel(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    // Current page row — extension data, page text already available (no fetch needed).
    @ViewBuilder
    func safariTabRowFromExtension(_ ctx: SafariPageContext) -> some View {
        let isAdded = webResearch.pages.contains(where: { $0.url == ctx.url })
        Button {
            if isAdded {
                if let idx = webResearch.pages.firstIndex(where: { $0.url == ctx.url }) {
                    WebResearchSession.shared.remove(at: idx)
                }
            } else {
                let snap = PageSnapshot(
                    url: ctx.url,
                    text: ctx.pageTextForAI,
                    title: ctx.title,
                    timestamp: ctx.timestamp)
                WebResearchSession.shared.addPage(snap)
            }
        } label: {
            safariTabRowLabel(
                url: ctx.url,
                title: ctx.title,
                subtitle: ctx.hasSelectedText ? "· has selection" : nil,
                icon: "safari",
                isAdded: isAdded
            )
        }
        .buttonStyle(.plain)
    }

    // Other-tab row — AppleScript fetch, but checks extension first for active URL.
    @ViewBuilder
    func safariTabRow(_ tab: SafariTab) -> some View {
        let isAdded = webResearch.pages.contains(where: { $0.url == tab.url })
        Button {
            if isAdded {
                if let idx = webResearch.pages.firstIndex(where: { $0.url == tab.url }) {
                    WebResearchSession.shared.remove(at: idx)
                }
            } else {
                let snap = PageSnapshot(url: tab.url, text: "", title: tab.title, timestamp: Date())
                let capturedTab = tab
                Task { @MainActor in
                    WebResearchSession.shared.addPage(snap)
                    // Same extraction logic as content_script.js: article → main → body
                    let js = """
                        (function(){
                            var el = document.querySelector('article')
                                     || document.querySelector('main')
                                     || document.body;
                            return el ? el.innerText.trim().substring(0, 8000) : '';
                        })()
                        """
                    let text =
                        await SafariTabManager.shared.executeJS(
                            js,
                            windowIndex: capturedTab.windowIndex,
                            tabIndex: capturedTab.tabIndex
                        ) ?? ""
                    if !text.isEmpty {
                        WebResearchSession.shared.updateText(url: capturedTab.url, text: text)
                    }
                }
            }
        } label: {
            safariTabRowLabel(
                url: tab.url,
                title: tab.title.isEmpty ? tab.domain : tab.title,
                subtitle: nil,
                icon: tab.icon,
                isAdded: isAdded
            )
        }
        .buttonStyle(.plain)
    }

    // Shared row layout used by both extension and AppleScript rows.
    @ViewBuilder
    func safariTabRowLabel(
        url: String, title: String, subtitle: String?,
        icon: String, isAdded: Bool
    ) -> some View {
        HStack(spacing: 10) {
            let faviconURL = URL(string: url).flatMap { u -> URL? in
                guard let host = u.host else { return nil }
                return URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=32")
            }
            AsyncImage(url: faviconURL) { img in
                img.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 18, height: 18)
            .clipShape(RoundedRectangle(cornerRadius: 3))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 3) {
                    Text(URL(string: url)?.host ?? url)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    if let sub = subtitle {
                        Text(sub)
                            .font(.system(size: 10))
                            .foregroundStyle(.blue.opacity(0.75))
                    }
                }
            }
            Spacer(minLength: 4)
            Image(systemName: isAdded ? "checkmark" : "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isAdded ? Color.blue : .secondary.opacity(0.6))
                .frame(width: 18)
                .animation(.easeInOut(duration: 0.15), value: isAdded)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(isAdded ? Color.blue.opacity(0.07) : Color.clear)
    }

    @ViewBuilder
    var addFinderFolderButton: some View {
        let folderPath = currentFinderFolderPath()
        let folderURL = URL(fileURLWithPath: folderPath)
        let folderName =
            folderURL.lastPathComponent.isEmpty ? "this folder" : folderURL.lastPathComponent
        let alreadyAdded = isCurrentFinderFolderAttachedToConversation()

        Button(action: {
            addCurrentFinderFolderToConversation()
        }) {
            ZStack {
                Circle()
                    .fill(alreadyAdded ? Color.blue.opacity(0.35) : Color.white.opacity(0.12))
                    .frame(width: 22, height: 22)
                Image(systemName: alreadyAdded ? "minus" : "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(alreadyAdded ? Color.white : Color.white.opacity(0.85))
            }
        }
        .buttonStyle(.plain)
        .help(
            alreadyAdded
                ? "Remove \(folderName) from AI context"
                : "Add \(folderName) as AI context — all queries will be scoped to this folder")
    }

    /// Opens a persistent AI thread for the folder Finder is showing. In Finder's
    /// desktop-only mode, Desktop itself is the scope. The general chat window owns this
    /// conversation so folder history, file tools, and the right-side preview stay together.
    @ViewBuilder
    var openFinderFolderInChatWindowButton: some View {
        let folderURL = currentFinderAIChatFolderURL
        let folderName =
            folderURL.lastPathComponent.isEmpty ? "this folder" : folderURL.lastPathComponent
        let isOpen = GeneralChatWindowModel.shared.sessions.contains {
            $0.scope == .folder(path: folderURL.resolvingSymlinksInPath().path)
        }

        Button {
            _ = openCurrentFinderFolderAIChatIfNeeded()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    isOpen
                        ? AnyShapeStyle(Color.green.opacity(0.9))
                        : AnyShapeStyle(.secondary.opacity(0.70))
                )
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.07), in: Circle())
        }
        .buttonStyle(.plain)
        .help(
            isOpen
                ? "Open the \(folderName) AI chat"
                : "Chat with \(folderName) in the AI window")
    }

    /// The stable folder scope represented by Finder right now. Finder returns its last
    /// browser directory even when every window is closed, so desktop-only mode must not
    /// trust that cached value: its visible place is always `~/Desktop`.
    var currentFinderAIChatFolderURL: URL {
        if isFinderDesktopOnlyMode {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop", isDirectory: true)
                .standardizedFileURL
        }
        return URL(fileURLWithPath: currentFinderFolderPath()).standardizedFileURL
    }

    /// What the dock's chat field offers to talk about.
    ///
    /// "Ask Finder" is the wrong noun in a Finder window: nobody wants to ask the file
    /// manager anything — they want to ask about the folder they are looking at, which is
    /// also the scope the answer will actually use. Naming the folder says which one, so
    /// the same phrasing is honest in Downloads and in a project directory.
    var contextDockChatPrompt: String {
        if isFinderFrontmostWindowContext() {
            let name = currentFinderAIChatFolderURL.lastPathComponent
            return name.isEmpty ? "Ask about this folder" : "Ask about \(name)"
        }
        return "Ask \(contextDockChatDraftAppName)"
    }

    /// Mirrors the trailing Finder `+` for keyboard users. Empty-field Right Arrow opens
    /// the persistent folder thread; it no longer enables the retired folder-search mode.
    @discardableResult
    func openCurrentFinderFolderAIChatIfNeeded() -> Bool {
        guard showContextInDock,
            !isGlobalContextActive,
            isFinderFrontmostWindowContext()
        else { return false }

        let folderURL = currentFinderAIChatFolderURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: folderURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return false }

        // The dock answers about the current folder in the dock. Opening the window here
        // took the user out of the surface they were typing in to start a conversation
        // they had not asked to move — and the window glyph beside this control exists
        // precisely to say when they do want that. The folder thread is still created, so
        // pressing the glyph later lands in the same conversation rather than a new one.
        GeneralChatWindowModel.shared.openFolderSession(folderURL)
        armContextDockChat()
        return true
    }

    /// Sends an unmatched Finder-window query to the same persistent folder thread opened
    /// by the trailing `+`. Real Finder menu/file rows get first refusal in the keyboard
    /// handlers; this is the natural-language fallback once none of those executed.
    @discardableResult
    func submitCurrentFinderFolderAIQueryIfNeeded(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            showContextInDock,
            !isGlobalContextActive,
            isFinderFrontmostWindowContext()
        else { return false }

        let folderURL = currentFinderAIChatFolderURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: folderURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return false }

        // Registered so the thread exists and the window glyph opens the same
        // conversation, but the question itself is answered here: a folder question typed
        // into the dock is a dock question. Returning false hands it to the dock's own
        // Finder chat rather than sending it somewhere the user cannot see it.
        //
        // Deliberately not arming the chat from here. This runs before find-intent
        // resolution, and arming flips wasContextDockChatActive — which would demote
        // "search X" in a Finder window from a real search into a chat message.
        GeneralChatWindowModel.shared.openFolderSession(folderURL)
        return false
    }

    @ViewBuilder
    var addMailContextButton: some View {
        let alreadyAdded = isCurrentMailContextAttached()

        Button(action: {
            toggleMailContextAttachment()
        }) {
            ZStack {
                Circle()
                    .fill(alreadyAdded ? Color.blue.opacity(0.28) : Color.white.opacity(0.12))
                    .frame(width: 22, height: 22)
                Image(systemName: alreadyAdded ? "minus" : "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .buttonStyle(.plain)
        .help(
            alreadyAdded
                ? "Detach Mail context for AI questions"
                : "Attach Mail context for AI questions"
        )
    }

    /// Reliable execution for an already-approved inline command card. Opens the terminal
    /// panel for live output, runs through the background/terminal executor (real exit code
    /// + captured output — no fragile PTY-marker wait), appends the result to the chat, and
    /// feeds it back to the model for a plain answer.
    /// Ceiling on chained commands for one request. Three is enough for the common
    /// wrong-command-then-right-command recovery without letting a failing tool loop.
    static let maxScopedCommandAttempts = 3

    /// The model asks to read documentation by putting `HELP: <subcommand>` on its own line.
    static func parseLoopHelpRequest(_ reply: String) -> String? {
        for raw in reply.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.uppercased().hasPrefix("HELP:") else { continue }
            return line.dropFirst(5)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        }
        return nil
    }

    /// The model asks for another command by putting `RUN: <command>` on its own line.
    static func parseLoopCommand(_ reply: String) -> String? {
        for raw in reply.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.uppercased().hasPrefix("RUN:") else { continue }
            let command = line.dropFirst(4)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            guard !command.isEmpty else { return nil }
            // A capability id is not a shell command. The model is shown ids like
            // "cli.list" and "browser.history" as things it can run, so it writes
            // `RUN: cli.list` — and this loop, which accepts any string, classified it,
            // asked the user to approve it, and handed it to zsh: "command not found:
            // cli.list", exit 127. The user approved a real prompt for a command that never
            // existed.
            guard !isCapabilityID(command) else { return nil }
            return command
        }
        return nil
    }

    /// Whether the first word names a registered capability rather than a binary.
    ///
    /// Checked against the registry rather than by shape, so a genuine command that happens
    /// to contain a dot — `python3.12 -m http.server`, `./scripts/dev-run.sh` — still runs.
    static func isCapabilityID(_ command: String) -> Bool {
        guard let first = command.split(separator: " ").first.map(String.init) else {
            return false
        }
        return CapabilityRegistry.shared.capability(id: first) != nil
    }

    /// Removes the directive line so a reply that both explains and proposes does not show
    /// the user machine syntax.
    static func strippingLoopDirective(_ reply: String) -> String {
        let kept = reply.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("RUN:") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return kept.isEmpty ? reply : kept
    }

    /// Prompt for one turn of the loop: everything run so far, and the two allowed replies.
    func scopedLoopPrompt(
        originalQuestion: String,
        transcript: [(command: String, output: String, status: String)],
        canRunAnother: Bool
    ) -> String {
        var lines = ["User asked:", originalQuestion, ""]
        for (index, step) in transcript.enumerated() {
            lines.append("Command \(index + 1): \(step.command)\(step.status)")
            lines.append("Output \(index + 1):")
            lines.append(step.output.isEmpty ? "(no output)" : step.output)
            lines.append("")
        }
        if canRunAnother {
            lines.append(
                "If the output answers the request, answer it concisely and say nothing else.")
            lines.append(
                "If you need to know a subcommand's exact flags before using it, reply with "
                + "exactly one line `HELP: <subcommand>` and its documented help will be given "
                + "to you. Do this instead of guessing a flag.")
            lines.append(
                "If the output does not answer the request — wrong command, missing argument, "
                + "empty or error output — reply with exactly one line `RUN: <command>` giving "
                + "the single next command to try, using only documented subcommands and flags.")
            lines.append(
                "Never repeat a command already listed above, and never re-run one that failed "
                + "for a reason a different flag cannot fix — a missing dependency, a tool that "
                + "cannot run in this terminal, a permission error. Say what is wrong instead.")
        } else {
            lines.append(
                "Answer the request from the output above. No more commands can be run, so "
                + "if it still cannot be answered, say what is missing.")
        }
        return lines.joined(separator: "\n")
    }

    func runApprovedScopedCommand(_ command: String, originalQuestion: String) {
        // Only an interactive command needs a visible terminal. Everything else already runs
        // headless with its output captured, and that output is appended to the chat below —
        // so opening a PTY panel for it showed the same result twice, the second time as raw
        // escape-coded transcript. Reveal the terminal only when the command genuinely needs
        // a tty (top, vim, a REPL); otherwise the answer stays in the conversation.
        if TerminalAIBridge.shared.isTUICommand(command),
            !livePanelVisible || livePanelMode != .terminal
        {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                livePanelMode = .terminal
                livePanelVisible = true
            }
        }
        Task {
            // Agentic loop: run, judge the result against what was asked, and either answer
            // or take one more step. Bounded — an unbounded loop on a tool that keeps
            // erroring would run commands forever.
            var transcript: [(command: String, output: String, status: String)] = []
            var current = command

            for attempt in 1...Self.maxScopedCommandAttempts {
                await MainActor.run {
                    // Without this the chat sat silent until the command exited — `mole clean`
                    // runs for minutes, and nothing on screen said it was working.
                    l2.isLoading = true
                    dockTraceStep(
                        attempt == 1
                            ? "Running \(current)…"
                            : "Step \(attempt): running \(current)…")
                }
                // Same thread the chat window lists for this scope: a command approved in the
                // dock belongs on that thread's console, whichever surface approved it.
                let consoleScope = await MainActor.run {
                    GeneralChatScope(dockBundleId: currentGlobalScopedBundleID)
                }
                let result = await TerminalCommandExecutor.shared.runPreApproved(
                    current, consoleScope: consoleScope
                ) { line in
                    // Live progress: the tool's own latest line, cleaned of the escape codes it
                    // prints for colour. Status only — the full output is kept for the answer.
                    let clean = TerminalPackageManager.strippingANSI(line)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { return }
                    let shown = clean.count > 80 ? String(clean.prefix(80)) + "…" : clean
                    Task { @MainActor in l2.loadingStatus = shown }
                }
                // Stored stripped: the collapsed output view is not a terminal emulator, so raw
                // CSI sequences rendered as literal "[0;32m" noise around every line.
                let output = TerminalPackageManager.strippingANSI(result.output)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let ranCommand = current
                await MainActor.run {
                    l2.isLoading = false
                    dockTraceStep(
                        result.success
                            ? "Ran \(ranCommand)"
                            : "\(ranCommand) failed (exit \(result.exitCode))")
                    // Running is the proof a linked tool belongs to this scope: it promotes a
                    // provisional link so the sweep stops treating it as a wrong guess.
                    if result.success {
                        let binary = ranCommand.split(separator: " ").first.map(String.init) ?? ""
                        let leaf = (binary as NSString).lastPathComponent
                        let scope = self.currentScopeBundleIDForToolTrust()
                        if !leaf.isEmpty, !scope.isEmpty {
                            CLILinkTrustStore.shared.markUsed(command: leaf, bundleID: scope)
                        }
                    }
                }
                if result.success {
                    // Worked here, on this version, with these flags — worth more next time
                    // than the documentation it was derived from.
                    TerminalPackageManager.shared.recordSuccessfulInvocation(ranCommand)
                }
                transcript.append((
                    ranCommand, output,
                    result.success ? "" : "  [exited \(result.exitCode)]"
                ))

                // Ask what to do next. A failed or empty run is still worth judging: knowing
                // the command was wrong is exactly what lets the next step be right, which is
                // the behaviour that was missing — `pear help list` returned nothing useful
                // and the loop simply stopped instead of trying `pear --help`.
                let decision: String
                do {
                    let history = await MainActor.run { l2.chatMessages }
                    decision = try await sendToAIProviderWithContext(
                        query: scopedLoopPrompt(
                            originalQuestion: originalQuestion,
                            transcript: transcript,
                            canRunAnother: attempt < Self.maxScopedCommandAttempts),
                        messageHistory: history)
                } catch {
                    // No verdict arrived, so surface the raw output rather than losing it.
                    await MainActor.run {
                        l2.chatMessages.append(
                            AIChatMessage(
                                role: .tool, content: ranCommand,
                                trace: l2.routerTrace,
                                runOutput: output.isEmpty ? nil : output))
                    }
                    return
                }

                // Documentation first. Serving a HELP: request costs no attempt and runs
                // nothing — it hands back the block the tool itself printed, which is the
                // difference between using a flag and inventing one. `--json` in the loop
                // that prompted this had never appeared in any help output.
                if let wanted = Self.parseLoopHelpRequest(decision),
                    Self.parseLoopCommand(decision) == nil
                {
                    // In a CLI scope every command starts with the tool itself.
                    let tool = ranCommand.components(separatedBy: " ").first ?? ""
                    let section = TerminalPackageManager.shared.helpSection(
                        command: tool, subcommand: wanted)
                    await MainActor.run {
                        dockTraceStep(
                            section == nil
                                ? "No documented help for \(tool) \(wanted)"
                                : "Read help for \(tool) \(wanted)")
                    }
                    transcript.append((
                        "\(tool) \(wanted) --help",
                        section ?? "(no documented help for this subcommand)",
                        ""
                    ))
                    continue
                }

                // A next step is a command on its own line after RUN:. Anything else is the
                // answer, which is also what an exhausted attempt budget produces.
                guard let next = Self.parseLoopCommand(decision),
                    attempt < Self.maxScopedCommandAttempts
                else {
                    await MainActor.run {
                        l2.chatMessages.append(
                            AIChatMessage(
                                role: .assistant,
                                content: Self.strippingLoopDirective(decision),
                                trace: l2.routerTrace,
                                runOutput: output.isEmpty ? nil : output))
                    }
                    return
                }

                // Never run the same thing twice. The loop that prompted this ran `ls`, then
                // `ls --all`, then `ls --all --json`, then `ls --all` again — the tool was
                // reporting it could not control this terminal, which no flag fixes, and each
                // retry burned an attempt and raised the risk prompt.
                let alreadyTried = transcript.contains {
                    $0.command.caseInsensitiveCompare(next) == .orderedSame
                }
                if alreadyTried {
                    await MainActor.run {
                        dockTraceStep("Stopped: \(next) was already tried")
                        l2.chatMessages.append(
                            AIChatMessage(
                                role: .assistant,
                                content:
                                    "I already ran `\(next)` and it did not answer the request, "
                                    + "so repeating it would not help. Here is what it returned:",
                                trace: l2.routerTrace,
                                runOutput: output.isEmpty ? nil : output))
                    }
                    return
                }

                // The app's own risk policy decides whether a follow-up may run unattended:
                // safe and low are documented as auto-execute, everything above needs the
                // user. Letting the model pick its own next command is only acceptable
                // because that gate is here.
                let classification = TerminalCommandClassifier.shared.classify(next)
                guard classification.riskLevel <= .low else {
                    await MainActor.run {
                        dockTraceStep("Next step needs your approval: \(next)")
                        l2.chatMessages.append(
                            AIChatMessage(
                                role: .approval,
                                content: next,
                                structuredData:
                                    "Continue: \(originalQuestion)|||/\(classification.riskLevel.displayName)",
                                trace: l2.routerTrace,
                                runOutput: output.isEmpty ? nil : output))
                    }
                    return
                }
                await MainActor.run { dockTraceStep("Not answered yet — trying \(next)") }
                current = next
            }
        }
    }

    func l2ApprovalCardMeta(_ msg: AIChatMessage) -> (
        purpose: String, risk: String, isDockCommand: Bool
    ) {
        let sd = msg.structuredData ?? ""
        if sd.hasPrefix("dock_cmd|||") {
            return (String(sd.dropFirst("dock_cmd|||".count)), "Moderate", true)
        }
        let parts = sd.components(separatedBy: "|||/")
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "Unknown", false)
    }

    @ViewBuilder
    func l2InlineApprovalCard(_ msg: AIChatMessage) -> some View {
        let (purpose, risk, isDockCommand) = l2ApprovalCardMeta(msg)
        let isHighRisk =
            risk.lowercased().contains("high") || risk.lowercased().contains("critical")
        let isHandled = l2.handledApprovalIds.contains(msg.id)
        // Clickable until handled. Bridge cards used to gate on the global
        // `pendingApproval`, which left orphaned cards (loop ended / 60s timeout) with a
        // dead button — now the approve action runs those directly via the reliable executor.
        let isPending = !isHandled
        let termIconColor: SwiftUI.Color =
            isHandled ? .green : (isHighRisk ? .orange : .accentColor)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(termIconColor)
                Text(isHandled ? "Sent to terminal" : "Run command?")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if isHandled {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                } else if isHighRisk {
                    Text(risk)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                }
            }
            if !purpose.isEmpty {
                Text(purpose)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(msg.content)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
                .frame(maxWidth: .infinity, alignment: .leading)
            if !isHandled {
                HStack(spacing: 8) {
                    Button("Deny") {
                        l2.handledApprovalIds.insert(msg.id)
                        if !isDockCommand { TerminalAIBridge.shared.denyCommand() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .disabled(!isPending)
                    Button {
                        guard !l2.handledApprovalIds.contains(msg.id) else { return }
                        l2.handledApprovalIds.insert(msg.id)
                        let command = msg.content
                        // Route the bridge to the scoped PTY, then resume the pending tool
                        // call. Sending directly to the PTY left the on-device loop waiting.
                        // Same rule as runApprovedScopedCommand: the scoped PTY is revealed
                        // only for commands that need a tty. prepareForExecution also expands
                        // the panel, so calling it for every approval was what opened a
                        // terminal for `mole clean`.
                        if isInCLIToolScope, TerminalAIBridge.shared.isTUICommand(command) {
                            _ = CLIScopeTerminalManager.shared.prepareForExecution()
                        }
                        // Bridge card whose tool loop is still awaiting THIS command →
                        // resume it (the loop runs it and feeds the result back to the
                        // model). Every other case (dock_cmd, or an orphaned bridge card
                        // whose loop already ended/timed out) → run through the reliable
                        // pre-approved executor directly and surface the output.
                        if !isDockCommand,
                            terminalBridge.pendingApproval?.command == command
                        {
                            TerminalAIBridge.shared.approveCommand(command)
                        } else {
                            let originalQuestion =
                                l2.chatMessages.last(where: { $0.role == .user })?.content
                                ?? purpose
                            runApprovedScopedCommand(command, originalQuestion: originalQuestion)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill").font(.system(size: 9))
                            Text("Approve & Run")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .background(
                            isPending ? Color.accentColor : Color.gray,
                            in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(!isPending)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(cardBgFill(isHandled: isHandled, isHighRisk: isHighRisk))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    cardBorderColor(isHandled: isHandled, isHighRisk: isHighRisk), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func cardBgFill(isHandled: Bool, isHighRisk: Bool) -> SwiftUI.Color {
        if isHandled { return SwiftUI.Color.green.opacity(0.06) }
        if isHighRisk { return SwiftUI.Color.orange.opacity(0.08) }
        return SwiftUI.Color.accentColor.opacity(0.07)
    }

    func cardBorderColor(isHandled: Bool, isHighRisk: Bool) -> SwiftUI.Color {
        if isHandled { return SwiftUI.Color.green.opacity(0.2) }
        if isHighRisk { return SwiftUI.Color.orange.opacity(0.25) }
        return SwiftUI.Color.accentColor.opacity(0.2)
    }

    // MARK: - Contextual Quick Actions (type-based)

    struct PanelAction: Identifiable {
        let id = UUID()
        let icon: String
        let label: String
        let action: () -> Void
    }

    func appScopeShortcuts(
        for appKey: String,
        placements: Set<AppShortcut.Placement>
    ) -> [AppShortcut] {
        let builtIns = AppShortcut.builtInDefaults.filter { shortcut in
            (shortcut.appKey == appKey || shortcut.targetAppKeys.contains(appKey))
                && placements.contains(shortcut.placement)
        }
        let custom: [AppShortcut] = {
            var shortcuts: [AppShortcut] = []
            if placements.contains(.quickActions) || placements.contains(.both) {
                shortcuts += settings.shortcuts(for: appKey)
            }
            if placements.contains(.contextDock) || placements.contains(.both) {
                shortcuts += settings.contextDockShortcuts(for: appKey)
            }
            return shortcuts
        }()
        var seen = Set<String>()
        return (builtIns + custom).filter { seen.insert($0.name).inserted }
    }

    func sortedAppScopeShortcuts(_ shortcuts: [AppShortcut], query: String) -> [AppShortcut] {
        let normalizedQuery = normalizedScopeIntentText(query)
        guard !normalizedQuery.isEmpty else { return shortcuts }
        let ranked = shortcuts.map { shortcut -> (AppShortcut, Double) in
            let score = scopeIntentScore(
                label: shortcut.name,
                keywords: shortcut.triggerKeywords,
                query: normalizedQuery
            )
            return (shortcut, score)
        }
        let hasPositiveMatch = ranked.contains { $0.1 > 0 }
        return
            ranked
            .filter { hasPositiveMatch ? $0.1 > 0 : true }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name)
                        == .orderedAscending
                }
                return lhs.1 > rhs.1
            }
            .map(\.0)
    }

    func smartAppScopePanelActions(for appKey: String, query: String) -> [PanelAction] {
        guard appKey == "reminders" else { return [] }
        let normalizedQuery = normalizedScopeIntentText(query)
        guard !normalizedQuery.isEmpty else { return [] }

        let reminderTitle = reminderItemName(from: normalizedQuery)
        let listTitle = reminderListName(from: normalizedQuery)
        let wantsList = scopeIntentContainsAny(
            normalizedQuery,
            ["list", "shopping list", "todo list", "reminder list", "checklist"]
        )
        let wantsReminder = scopeIntentContainsAny(
            normalizedQuery,
            ["reminder", "remainder", "remind", "task", "todo", "to do"]
        )
        let createVerb = scopeIntentContainsAny(
            normalizedQuery,
            ["create", "new", "add", "make", "set"]
        )

        var ranked: [(PanelAction, Double)] = []
        if wantsReminder || createVerb {
            let score =
                (wantsReminder ? 80.0 : 30.0)
                + (createVerb ? 35.0 : 0.0)
                + (wantsList && !wantsReminder ? -18.0 : 0.0)
            ranked.append(
                (
                    PanelAction(
                        icon: "plus.circle",
                        label: reminderTitle.isEmpty ? "New Reminder" : "Add Reminder"
                    ) {
                        createReminderFromScopeQuery(reminderTitle)
                    },
                    score
                ))
        }

        if wantsList || normalizedQuery.contains("shopping") {
            let score =
                (wantsList ? 92.0 : 40.0)
                + (createVerb ? 30.0 : 0.0)
                + (normalizedQuery.contains("reminder list") ? 36.0 : 0.0)
            ranked.append(
                (
                    PanelAction(
                        icon: "list.bullet.rectangle",
                        label: listTitle.isEmpty ? "New List" : "Create List"
                    ) {
                        createReminderListFromScopeQuery(listTitle)
                    },
                    score
                ))
        }

        if normalizedQuery.contains("overdue") {
            ranked.append(
                (
                    PanelAction(icon: "exclamationmark.circle", label: "Overdue") {
                        searchState.query = "show overdue reminders"
                        handleRemPanelQuery()
                    },
                    120
                ))
        }

        if normalizedQuery.contains("today") {
            ranked.append(
                (
                    PanelAction(icon: "calendar", label: "Today") {
                        searchState.query = "show reminders due today"
                        handleRemPanelQuery()
                    },
                    112
                ))
        }

        return
            ranked
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    func createReminderFromScopeQuery(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchState.query = "create new reminder "
            return
        }
        let ok = AppleAppsAPI.shared.createReminder(title: trimmed)
        appendPanelMessage(
            AIChatMessage(
                role: .assistant,
                content: ok ? "Created reminder: \(trimmed)" : "Couldn't create that reminder.",
                isError: !ok
            )
        )
        if ok {
            searchState.query = ""
            reloadAppPanelData(for: "reminders")
        }
    }

    func createReminderListFromScopeQuery(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchState.query = "create new reminder list "
            return
        }
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            tell application "Reminders"
                activate
                make new list with properties {name:"\(escaped)"}
            end tell
            """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        let ok = error == nil
        appendPanelMessage(
            AIChatMessage(
                role: .assistant,
                content: ok ? "Created reminder list: \(trimmed)" : "Couldn't create that list.",
                isError: !ok
            )
        )
        if ok {
            searchState.query = ""
            reloadAppPanelData(for: "reminders")
        }
    }

    func reminderItemName(from normalizedQuery: String) -> String {
        cleanedReminderIntentName(
            from: normalizedQuery,
            removing: [
                "create", "new", "add", "make", "set", "a", "an", "reminder", "remainder", "remind",
                "task", "todo", "to", "do",
            ]
        )
    }

    func reminderListName(from normalizedQuery: String) -> String {
        cleanedReminderIntentName(
            from: normalizedQuery,
            removing: [
                "create", "new", "add", "make", "a", "an", "reminder", "remainder", "reminders",
                "list", "todo", "to", "do",
            ]
        )
    }

    func cleanedReminderIntentName(
        from normalizedQuery: String, removing stopWords: Set<String>
    ) -> String {
        normalizedQuery
            .split(separator: " ")
            .map(String.init)
            .filter { !stopWords.contains($0) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func scopeIntentScore(label: String, keywords: [String], query: String) -> Double {
        let normalizedLabel = normalizedScopeIntentText(label)
        var score = 0.0
        if normalizedLabel == query { score += 120 }
        if normalizedLabel.contains(query) || query.contains(normalizedLabel) { score += 80 }
        score += Double(scopeTokenOverlap(normalizedLabel, query)) * 22
        for keyword in keywords.map(normalizedScopeIntentText) where !keyword.isEmpty {
            if keyword == query { score += 120 }
            if keyword.contains(query) || query.contains(keyword) { score += 70 }
            score += Double(scopeTokenOverlap(keyword, query)) * 18
        }
        return score
    }

    func normalizedScopeIntentText(_ text: String) -> String {
        let lowered = text.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func scopeTokenOverlap(_ lhs: String, _ rhs: String) -> Int {
        let left = Set(lhs.split(separator: " ").map(String.init))
        let right = Set(rhs.split(separator: " ").map(String.init))
        return left.intersection(right).count
    }

    func scopeIntentContainsAny(_ query: String, _ needles: [String]) -> Bool {
        needles.contains { query.contains($0) }
    }

    /// Returns quick actions appropriate for the current context item.
    func contextPanelActions() -> [PanelAction] {
        let activeKey = searchState.activeSmartQueryKey ?? ""
        let scopedQuery = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if searchState.contextApp == nil {
            if !activeKey.isEmpty {
                var seen = Set<String>()
                let smartActions = smartAppScopePanelActions(for: activeKey, query: scopedQuery)
                let quick = appScopeShortcuts(for: activeKey, placements: [.quickActions, .both])
                let dock = appScopeShortcuts(for: activeKey, placements: [.contextDock, .both])
                let extActions = appPillScriptExtensions(for: activeKey, query: scopedQuery)
                    .map { ext in
                        PanelAction(
                            icon: ext.scriptLanguage?.systemImage ?? "terminal",
                            label: ext.toolName.replacingOccurrences(of: "-", with: " ").capitalized
                        ) {
                            executeAppToolExtension(ext)
                        }
                    }
                for action in smartActions { seen.insert(action.label) }
                for s in quick { seen.insert(s.name) }
                let combined = quick + dock.filter { seen.insert($0.name).inserted }
                let sortedShortcuts = sortedAppScopeShortcuts(combined, query: scopedQuery)
                var actions =
                    smartActions
                    + sortedShortcuts.map { sc in
                        PanelAction(icon: sc.iconName, label: sc.name) { executeAppShortcut(sc) }
                    }
                for action in extActions where seen.insert(action.label).inserted {
                    actions.append(action)
                }
                if !actions.isEmpty {
                    return actions
                }
            }

            return []
        }
        guard let ctx = searchState.contextApp else { return [] }

        switch ctx.resultType {
        case .application:
            // Custom shortcuts first (combine quick-actions + context-dock placements), then standard
            let key = ctx.key ?? searchState.activeSmartQueryKey ?? ""
            let mergedShortcuts: [AppShortcut] = {
                var seen = Set<String>()
                let quick = appScopeShortcuts(for: key, placements: [.quickActions, .both])
                let dock = appScopeShortcuts(for: key, placements: [.contextDock, .both])
                for s in quick { seen.insert(s.name) }
                return quick + dock.filter { seen.insert($0.name).inserted }
            }()
            let smartActions = smartAppScopePanelActions(for: key, query: scopedQuery)
            let userShortcuts: [PanelAction] =
                smartActions
                + sortedAppScopeShortcuts(
                    mergedShortcuts, query: scopedQuery
                ).filter { shortcut in
                    !smartActions.contains(where: { $0.label == shortcut.name })
                }.map { sc in
                    PanelAction(icon: sc.iconName, label: sc.name) { executeAppShortcut(sc) }
                }
            let userExtensions: [PanelAction] = appPillScriptExtensions(
                for: key, query: scopedQuery
            )
            .map { ext in
                PanelAction(
                    icon: ext.scriptLanguage?.systemImage ?? "terminal",
                    label: ext.toolName.replacingOccurrences(of: "-", with: " ").capitalized
                ) {
                    executeAppToolExtension(ext)
                }
            }
            let combinedUserActions =
                userShortcuts
                + userExtensions.filter { ext in
                    !userShortcuts.contains(where: { $0.label == ext.label })
                }
            if !combinedUserActions.isEmpty { return combinedUserActions }
            var actions: [PanelAction] = []
            if !ctx.appPath.isEmpty {
                actions.append(
                    PanelAction(icon: "arrow.up.forward.app", label: "Open") {
                        NSWorkspace.shared.openApplication(
                            at: URL(fileURLWithPath: ctx.appPath),
                            configuration: NSWorkspace.OpenConfiguration())
                    })
                actions.append(
                    PanelAction(icon: "magnifyingglass", label: "Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            URL(fileURLWithPath: ctx.appPath)
                        ])
                    })
            }
            return actions

        case .file, .document:
            guard let path = ctx.filePath else { return [] }
            return [
                PanelAction(icon: "doc", label: "Open") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                },
                PanelAction(icon: "folder", label: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                },
                PanelAction(icon: "doc.on.doc", label: "Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                },
                PanelAction(icon: "eye", label: "Quick Look") {
                    quickLookDataSource = QuickLookDataSource(urls: [URL(fileURLWithPath: path)])
                },
                PanelAction(icon: "trash", label: "Move to Trash") {
                    try? FileManager.default.trashItem(
                        at: URL(fileURLWithPath: path), resultingItemURL: nil)
                },
            ]

        case .folder:
            let path = ctx.filePath ?? ctx.subtitle
            return [
                PanelAction(icon: "folder", label: "Open") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                },
                PanelAction(icon: "doc.on.doc", label: "Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                },
                PanelAction(icon: "terminal", label: "Open in Terminal") {
                    let script =
                        "tell application \"Terminal\" to do script \"cd '\(path)'\" activate"
                    NSAppleScript(source: script)?.executeAndReturnError(nil)
                },
                PanelAction(icon: "eye", label: "Quick Look") {
                    quickLookDataSource = QuickLookDataSource(urls: [URL(fileURLWithPath: path)])
                },
            ]

        case .contact:
            var actions: [PanelAction] = []
            if let email = ctx.contactEmail, !email.isEmpty {
                actions.append(
                    PanelAction(icon: "envelope", label: "Send Email") {
                        if let url = URL(string: "mailto:\(email)") { NSWorkspace.shared.open(url) }
                    })
                actions.append(
                    PanelAction(icon: "message", label: "Send Message") {
                        if let url = URL(string: "imessage:\(email)") {
                            NSWorkspace.shared.open(url)
                        }
                    })
                actions.append(
                    PanelAction(icon: "doc.on.doc", label: "Copy Email") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(email, forType: .string)
                    })
            }
            if let phone = ctx.contactPhone, !phone.isEmpty {
                actions.append(
                    PanelAction(icon: "phone", label: "Call") {
                        if let url = URL(string: "tel:\(phone)") { NSWorkspace.shared.open(url) }
                    })
            }
            actions.append(
                PanelAction(icon: "person.crop.circle", label: "Open in Contacts") {
                    NSWorkspace.shared.open(URL(string: "addressbook://")!)
                })
            return actions

        case .calendarEvent:
            return [
                PanelAction(icon: "calendar", label: "Open Calendar") {
                    NSWorkspace.shared.open(URL(string: "ical://")!)
                },
                PanelAction(icon: "doc.on.doc", label: "Copy Title") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ctx.name, forType: .string)
                },
            ]

        case .reminder:
            return [
                PanelAction(icon: "checkmark.circle", label: "Open Reminders") {
                    NSWorkspace.shared.open(URL(string: "x-apple-reminder://")!)
                },
                PanelAction(icon: "doc.on.doc", label: "Copy Title") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ctx.name, forType: .string)
                },
            ]

        case .note:
            return [
                PanelAction(icon: "note.text", label: "Open Notes") {
                    NSWorkspace.shared.open(URL(string: "notes://")!)
                },
                PanelAction(icon: "doc.on.doc", label: "Copy Title") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ctx.name, forType: .string)
                },
            ]

        case .cliTool:
            // Show subcommands as quick actions, plus a "Run in Terminal" button for TUI tools
            let toolCmd = ctx.name
            let pkg = TerminalPackageManager.shared.packages.first(where: {
                $0.name == ctx.name || $0.command == ctx.name
            })
            let isTUI = TerminalAIBridge.shared.isTUICommand(toolCmd)
            var actions: [PanelAction] = []

            func sendCLIQuery(_ msg: String) {
                searchState.query = msg
                handleRemPanelQuery()
                searchState.query = ""
            }

            if isTUI {
                actions.append(
                    PanelAction(icon: "play.fill", label: "Launch") {
                        // Direct spawn — bypasses AI so TUI starts instantly
                        if panelTerminalHost == nil {
                            panelTerminalHost = TerminalHostController()
                        }
                        showLivePanel(.terminal)
                        // Small delay so SwiftTerm shell is ready before we send the command
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            panelTerminalHost?.sendCommand(toolCmd)
                            BackgroundWorkerPool.shared.registerPTYWorker(
                                command: toolCmd,
                                purpose: "Launched from panel",
                                intent: TerminalAIBridge.shared.detectWorkerIntent(for: toolCmd)
                            )
                        }
                    })
            }
            // First few subcommands as quick actions
            if let subs = pkg?.subcommands {
                for sub in subs.prefix(isTUI ? 3 : 4) {
                    actions.append(
                        PanelAction(icon: "arrow.right.circle", label: sub) {
                            sendCLIQuery("Run: \(toolCmd) \(sub)")
                        })
                }
            }
            actions.append(
                PanelAction(icon: "questionmark.circle", label: "Help") {
                    sendCLIQuery("Show \(toolCmd) --help")
                })
            actions.append(
                PanelAction(icon: "info.circle", label: "Version") {
                    sendCLIQuery("What version is \(toolCmd)?")
                })
            return actions

        default:
            return []
        }
    }

}
