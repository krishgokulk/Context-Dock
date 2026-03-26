//
//  AIModeView.swift
//  ILauncher
//
//  AI-powered intelligent suggestions view
//  Shows context-aware extension suggestions with one-click execution
//

import SwiftUI
import AppKit

// Explicitly reference our UserContext to avoid ambiguity with system types
typealias AppUserContext = ILauncher.UserContext

struct AIModeView: View {
    @Binding var currentContext: AppUserContext
    @Binding var isVisible: Bool

    @State private var suggestions: [SuggestedExtension] = []
    @State private var isLoading: Bool = false
    @State private var contextDescription: String = ""
    @State private var userInput: String = ""

    // AI Chat state — uses the same AIChatMessage model as the L2 layer (consistent)
    @State private var chatMessages: [AIChatMessage] = []
    @State private var isAIResponding: Bool = false
    @State private var streamingMessageId: UUID? = nil
    @StateObject private var aiService = AIProviderService.shared
    @ObservedObject private var settings = AppSettings.shared
    
    // Code save state
    @StateObject private var codeSaver = CodeSuggestionSaver.shared

    private func newConversationAction() {
        chatMessages = []
        aiService.resetOnDeviceSession()
    }

    @ViewBuilder private var chatHistorySection: some View {
        if !chatMessages.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(chatMessages) { message in
                            AIChatMessageView(
                                message: message,
                                isStreaming: message.id == streamingMessageId
                            )
                            .id(message.id)
                        }
                        if isAIResponding && streamingMessageId == nil {
                            AILoadingView().id("loading")
                        }
                    }
                    .padding()
                }
                .frame(maxHeight: 280)
                .onChange(of: chatMessages.count) { _ in
                    if let last = chatMessages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    @ViewBuilder private var quickActionsSection: some View {
        if !chatMessages.isEmpty && !suggestions.isEmpty {
            DisclosureGroup(isExpanded: Binding.constant(chatMessages.isEmpty)) {
                QuickActionShortcutsView(suggestions: Array(suggestions.prefix(6)), context: currentContext)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            } label: {
                Text("Quick Actions (\(min(6, suggestions.count)))")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.top, 8)
        } else if !suggestions.isEmpty {
            QuickActionShortcutsView(suggestions: Array(suggestions.prefix(6)), context: currentContext)
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
        } else if !isLoading {
            HStack {
                ProgressView().scaleEffect(0.7)
                Text("Loading extensions...").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder private var inputRow: some View {
        HStack(spacing: 8) {
            TextField(getPlaceholder(), text: $userInput)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1))
                .onSubmit { handleUserInput() }
            if isAIResponding {
                ProgressView().scaleEffect(0.8).frame(width: 32, height: 32)
            } else if !userInput.isEmpty {
                Button(action: handleUserInput) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)).foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    @ViewBuilder private var resultPanel: some View {
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("All Extensions").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary).padding(.horizontal, 16)
                SuggestionsGridView(suggestions: suggestions, context: currentContext).frame(maxHeight: 200)
            }
        }
    }

    private func handleAppear() {
        if case .none = currentContext { autoDetectContext() } else { loadSuggestions() }
    }

    private func handleVisibilityChange(_ newValue: Bool) {
        guard newValue else { return }
        if case .none = currentContext { autoDetectContext() } else { loadSuggestions() }
    }

    var body: some View {
        VStack(spacing: 0) {
            AIHeaderView(
                contextDescription: contextDescription,
                onClose: { isVisible = false; chatMessages = [] },
                onNewConversation: newConversationAction
            )
            chatHistorySection
            quickActionsSection
            inputRow
            ContextAppSuggestionsRow(
                context: currentContext,
                onOpenWith: { app in
                    if case .filesSelected(let urls) = currentContext { openFilesWithApp(urls, app: app) }
                },
                onRunExtension: { ext in executeContextExtension(ext) }
            )
            .padding(.horizontal, 16).padding(.bottom, 8)
            resultPanel
        }
        .frame(maxWidth: 600, maxHeight: 500)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
        )
        .onAppear { handleAppear() }
        .onChange(of: isVisible) { handleVisibilityChange($0) }
        .onChange(of: currentContext.description) { _ in loadSuggestions() }
        .sheet(isPresented: $codeSaver.showSaveSheet) { SaveExtensionSheet() }
    }

    // MARK: - Open With Helper

    private func openFilesWithApp(_ urls: [URL], app: DefaultAppResolver.DefaultApp) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        NSWorkspace.shared.open(
            urls,
            withApplicationAt: app.path,
            configuration: config
        ) { _, error in
            if let error = error {
                print("Error opening files: \(error.localizedDescription)")
            } else {
                print("Opened \(urls.count) file(s) with \(app.displayName)")
            }
        }
    }

    private func executeContextExtension(_ ext: ScriptExtension) {
        Task {
            do {
                let input = getInputFromContext()
                let result = try await ext.execute(with: input)
                print("Extension result: \(result)")
            } catch {
                print("Extension error: \(error)")
            }
        }
    }

    private func getInputFromContext() -> String {
        switch currentContext {
        case .filesSelected(let urls):
            return urls.map { $0.path }.joined(separator: "\n")
        case .textSelected(let text):
            return text
        case .url(let url):
            return url
        case .appFocused(let name, _):
            return name
        case .contactSelected(let contact):
            return contact
        case .none:
            return NSPasteboard.general.string(forType: .string) ?? ""
        }
    }
    
    private func getPlaceholder() -> String {
        switch currentContext {
        case .filesSelected(let urls):
            return urls.count == 1 ? "Ask about this file or run an extension..." : "Ask about these \(urls.count) files or run an extension..."
        case .textSelected:
            return "Ask about this text or run an extension..."
        case .url:
            return "Ask about this link or run an extension..."
        case .appFocused(let name, _):
            return "Ask about \(name) or run an extension..."
        case .contactSelected:
            return "Ask about this contact or run an extension..."
        case .none:
            return "Ask a question or search extensions..."
        }
    }

    // MARK: - AI Chat Functions

    private func handleUserInput() {
        let input = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        // Determine if this is a question (send to AI) or filter (filter extensions)
        if shouldSendToAI(input) {
            sendMessageToAI(input)
        } else {
            // In future: filter extensions by input
            // For now, just send to AI if it looks like a question
            sendMessageToAI(input)
        }
    }

    private func shouldSendToAI(_ input: String) -> Bool {
        // Send to AI if:
        // 1. Input ends with "?"
        // 2. Starts with question words
        // 3. Contains complete sentences (3+ words)
        // 4. Contains key AI-trigger words

        let questionWords = ["what", "how", "why", "when", "where", "who", "which",
                           "can", "is", "are", "does", "do", "tell", "show", "find",
                           "list", "summarize", "explain", "analyze", "compare"]

        let lowercased = input.lowercased()

        // Check for question mark
        if input.hasSuffix("?") {
            return true
        }

        // Check if starts with question word
        for word in questionWords {
            if lowercased.hasPrefix(word + " ") {
                return true
            }
        }

        // Check word count (3+ words likely a question/statement)
        let wordCount = input.split(separator: " ").count
        if wordCount >= 3 {
            return true
        }

        // Otherwise, treat as extension filter
        return false
    }

    private func sendMessageToAI(_ message: String) {
        chatMessages.append(AIChatMessage(role: .user, content: message))
        userInput = ""
        isAIResponding = true

        // On-device Apple Intelligence uses real-time streaming
        if settings.selectedAIProvider == .onDevice {
            sendOnDeviceStreaming(message: message)
            return
        }

        Task {
            do {
                if settings.selectedAIProvider.requiresAPIKey {
                    let apiKey = settings.getAPIKey(for: settings.selectedAIProvider)
                    guard !apiKey.isEmpty else {
                        throw AIServiceError.missingAPIKey("Please configure your \(settings.selectedAIProvider.displayName) API key in Settings")
                    }
                }

                let response = try await aiService.sendMessage(
                    message,
                    context: currentContext,
                    provider: settings.selectedAIProvider,
                    apiKey: settings.getAPIKey(for: settings.selectedAIProvider),
                    conversationHistory: chatHistoryAsChatMessages()
                )

                await MainActor.run {
                    chatMessages.append(AIChatMessage(role: .assistant, content: response))
                    isAIResponding = false
                }

            } catch let error as AIServiceError {
                await MainActor.run {
                    chatMessages.append(AIChatMessage(role: .assistant,
                        content: "Error: \(error.localizedDescription)\n\nPlease check your API key in Settings.",
                        isError: true))
                    isAIResponding = false
                }
            } catch {
                await MainActor.run {
                    chatMessages.append(AIChatMessage(role: .assistant,
                        content: "Error: \(error.localizedDescription)", isError: true))
                    isAIResponding = false
                }
            }
        }
    }

    /// Convert AIChatMessage history → ChatMessage for AIProviderService.sendMessage / streamOnDeviceResponse
    private func chatHistoryAsChatMessages() -> [ChatMessage] {
        chatMessages.compactMap { msg in
            switch msg.role {
            case .user:      return ChatMessage(role: .user, content: msg.content)
            case .assistant: return ChatMessage(role: .assistant, content: msg.content)
            default:         return nil
            }
        }
    }

    // MARK: - On-Device Streaming

    private func sendOnDeviceStreaming(message: String) {
        let placeholder = AIChatMessage(role: .assistant, content: "")
        chatMessages.append(placeholder)
        let msgId = placeholder.id
        streamingMessageId = msgId

        aiService.streamOnDeviceResponse(
            message: message,
            context: currentContext,
            history: chatHistoryAsChatMessages(),
            onPartial: { token in
                DispatchQueue.main.async {
                    if let idx = chatMessages.firstIndex(where: { $0.id == msgId }) {
                        chatMessages[idx] = AIChatMessage(
                            id: msgId, role: .assistant,
                            content: chatMessages[idx].content + token
                        )
                    }
                }
            },
            onComplete: { _ in
                DispatchQueue.main.async {
                    streamingMessageId = nil
                    isAIResponding = false
                }
            },
            onError: { errorText in
                DispatchQueue.main.async {
                    if let idx = chatMessages.firstIndex(where: { $0.id == msgId }) {
                        chatMessages[idx] = AIChatMessage(id: msgId, role: .assistant, content: errorText, isError: true)
                    }
                    streamingMessageId = nil
                    isAIResponding = false
                }
            }
        )
    }

    private func autoDetectContext() {
        print("🔍 [AIModeView] Auto-detecting context...")
        
        Task {
            let detectedContext = await detectContext()
            
            // Update context and load suggestions
            currentContext = detectedContext
            print("📊 [AIModeView] Context updated to: \(detectedContext.description)")
            loadSuggestions()
        }
    }
    
    private func detectContext() async -> AppUserContext {
        // PRIORITY 1: Check if there's already a valid context passed in
        // (e.g., from AppDelegate's pre-detection via .userContextDetected notification)
        // Respect ANY non-.none context, not just .filesSelected
        switch currentContext {
        case .filesSelected(let urls) where !urls.isEmpty:
            print("✅ [AIModeView] Using existing file context: \(urls.count) files")
            return currentContext
        case .appFocused(let name, _):
            print("✅ [AIModeView] Using existing app context: \(name)")
            return currentContext
        case .textSelected(let text) where !text.isEmpty:
            print("✅ [AIModeView] Using existing text context: \(text.prefix(50))...")
            return currentContext
        case .url(let url) where !url.isEmpty:
            print("✅ [AIModeView] Using existing URL context: \(url.prefix(50))...")
            return currentContext
        case .contactSelected:
            print("✅ [AIModeView] Using existing contact context")
            return currentContext
        default:
            print("🔍 [AIModeView] No existing context (.none), running detection...")
        }

        // PRIORITY 2: Try to get Finder selection directly (works even if ILauncher is frontmost)
        let finderSelection = ContextDetector.shared.getFinderSelectedFiles()
        if !finderSelection.isEmpty {
            print("📁 [AIModeView] Got Finder selection directly: \(finderSelection.count) files")
            for url in finderSelection.prefix(5) {
                print("   - \(url.lastPathComponent)")
            }
            return .filesSelected(finderSelection)
        }

        // PRIORITY 3: Try frontmost app detection (but skip if ILauncher)
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            print("⚠️ [AIModeView] No frontmost application found")
            return checkClipboard()
        }

        // Skip ILauncher itself - can't detect context from ourselves
        if frontmostApp.bundleIdentifier?.contains("ILauncher") == true {
            print("⚠️ [AIModeView] Frontmost app is ILauncher, checking clipboard...")
            return checkClipboard()
        }

        // Try ContextDetector with the frontmost app
        guard let detected = ContextDetector.shared.detectContext(frontmostApp: frontmostApp) else {
            print("⚠️ [AIModeView] ContextDetector returned nil")
            return checkClipboard()
        }

        print("✅ [AIModeView] ContextDetector detected: \(detected.description)")

        switch detected {
        case .files(let urls):
            return .filesSelected(urls)
        case .text(let text):
            return .textSelected(text)
        case .app(let bundleID, let name):
            return .appFocused(name: name, bundleID: bundleID)
        default:
            print("⚠️ [AIModeView] Unsupported DetectedContext case: \(detected)")
            return checkClipboard()
        }
    }

    private func checkClipboard() -> AppUserContext {
        // Check for file URLs in clipboard
        if let fileURLs = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            let validFileURLs = fileURLs.filter { $0.isFileURL }
            if !validFileURLs.isEmpty {
                print("📋 [AIModeView] Found \(validFileURLs.count) file(s) in clipboard")
                return .filesSelected(validFileURLs)
            }
        }

        // Check for text in clipboard
        if let clipboardText = NSPasteboard.general.string(forType: .string) {
            let trimmed = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed.count >= 3 {
                // Check if it looks like a URL
                if let url = URL(string: trimmed), url.scheme != nil {
                    print("🔗 [AIModeView] Found URL in clipboard: \(trimmed.prefix(50))")
                    return .url(trimmed)
                }
                print("📝 [AIModeView] Found text in clipboard: \(trimmed.prefix(50))...")
                return .textSelected(trimmed)
            }
        }

        print("⚪ [AIModeView] No context detected")
        return .none
    }
    
    
    private func loadSuggestions() {
        isLoading = true
        print("🤖 [AIModeView] ==========================================")
        print("🤖 [AIModeView] Starting to load suggestions...")
        print("🤖 [AIModeView] Current context: \(currentContext)")
        print("🤖 [AIModeView] Current context description: \(currentContext.description)")

        Task {
            // Add delay to ensure UI is ready
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
            
            let matcher = IntelligentExtensionMatcher.shared
            let detectedContext = convertToDetectedContext(currentContext)

            print("🤖 [AIModeView] Converted to DetectedContext: \(detectedContext)")

            // Get suggestions from matcher (which now includes built-in extensions via ExtensionManager)
            var newSuggestions = matcher.suggestExtensions(for: detectedContext)
            print("🤖 [AIModeView] Got \(newSuggestions.count) suggestions from matcher")
            
            if newSuggestions.isEmpty {
                print("❌ [AIModeView] ERROR: No suggestions returned from matcher!")
                print("❌ [AIModeView] Checking if extensions are enabled in settings...")
                print("❌ [AIModeView] enableContextAIExtensions: \(AppSettings.shared.enableContextAIExtensions)")
                
                // FALLBACK: Always show default built-in extensions if nothing matches
                print("⚠️ [AIModeView] Loading default built-in extensions as fallback...")
                let allExtensions = ExtensionManager.shared.getEnabledExtensions()
                print("📦 [AIModeView] Found \(allExtensions.count) total extensions")
                
                // Create suggestions from all built-in extensions with default scores
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
                print("✅ [AIModeView] Created \(newSuggestions.count) fallback suggestions")
            }
            
            // Sort by relevance
            newSuggestions.sort { $0.relevanceScore > $1.relevanceScore }
            
            print("🤖 [AIModeView] Total suggestions after sorting: \(newSuggestions.count)")
            for (index, suggestion) in newSuggestions.prefix(10).enumerated() {
                print("🤖 [AIModeView]   \(index + 1). \(suggestion.scriptExtension.displayName) (score: \(suggestion.relevanceScore)) - \(suggestion.reason)")
            }

            let description = describeContext(currentContext)
            print("🤖 [AIModeView] Context description: \(description)")

            await MainActor.run {
                suggestions = newSuggestions
                contextDescription = description
                isLoading = false
                print("🤖 [AIModeView] ✅ FINAL: UI updated with \(newSuggestions.count) suggestions")
            }
            
            print("🤖 [AIModeView] ==========================================")
        }
    }
    
    private func convertToDetectedContext(_ context: AppUserContext) -> DetectedContext {
        switch context {
        case .filesSelected(let urls):
            return .files(urls)
            
        case .textSelected(let text):
            return .text(text)

        case .url(let url):
            return .text(url)
            
        case .appFocused(let name, let bundleID):
            return .app(bundleID: bundleID, name: name)
            
        case .contactSelected(let contact):
            return .text(contact)
            
        case .none:
            // When no context, try to get clipboard text
            if let clipboardText = NSPasteboard.general.string(forType: .string), !clipboardText.isEmpty {
                print("🤖 [AIModeView] No context, but found clipboard text (\(clipboardText.count) chars)")
                return .text(clipboardText)
            }
            
            // Otherwise, return generic app context
            print("🤖 [AIModeView] No context and empty clipboard - using Unknown app context")
            return .app(bundleID: "", name: "Unknown")
        }
    }

    private func describeContext(_ context: AppUserContext) -> String {
        switch context {
        case .filesSelected(let urls):
            if urls.count == 1 {
                let filename = urls[0].lastPathComponent
                let ext = urls[0].pathExtension.uppercased()
                return "1 file selected: \(filename)" + (ext.isEmpty ? "" : " (\(ext))")
            } else {
                // Analyze file types
                var imageCount = 0
                var pdfCount = 0
                var docCount = 0
                var videoCount = 0
                var otherCount = 0

                for url in urls {
                    let ext = url.pathExtension.lowercased()
                    if ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tiff"].contains(ext) {
                        imageCount += 1
                    } else if ext == "pdf" {
                        pdfCount += 1
                    } else if ["doc", "docx", "txt", "rtf", "pages"].contains(ext) {
                        docCount += 1
                    } else if ["mp4", "mov", "avi", "mkv", "m4v"].contains(ext) {
                        videoCount += 1
                    } else {
                        otherCount += 1
                    }
                }

                // Build description
                var parts: [String] = []
                if imageCount > 0 { parts.append("\(imageCount) image\(imageCount > 1 ? "s" : "")") }
                if pdfCount > 0 { parts.append("\(pdfCount) PDF\(pdfCount > 1 ? "s" : "")") }
                if docCount > 0 { parts.append("\(docCount) document\(docCount > 1 ? "s" : "")") }
                if videoCount > 0 { parts.append("\(videoCount) video\(videoCount > 1 ? "s" : "")") }
                if otherCount > 0 { parts.append("\(otherCount) other file\(otherCount > 1 ? "s" : "")") }

                if parts.isEmpty {
                    return "\(urls.count) files selected"
                } else {
                    return parts.joined(separator: ", ")
                }
            }

        case .textSelected(let text):
            let wordCount = text.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.count
            let charCount = text.count
            return "\(wordCount) word\(wordCount != 1 ? "s" : ""), \(charCount) character\(charCount != 1 ? "s" : "")"

        case .url(let url):
            return "Link selected: \(url)"

        case .appFocused(let name, _):
            return "Using \(name)"

        case .contactSelected(let contact):
            return "Contact: \(contact)"

        case .none:
            return "No context detected - Try selecting files or text"
        }
    }
}

// MARK: - AI Header

struct AIHeaderView: View {
    let contextDescription: String
    let onClose: () -> Void
    var onNewConversation: (() -> Void)? = nil
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.purple, .blue],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )

                    Text("AI Suggestions")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                }

                Spacer()

                if settings.selectedAIProvider == .onDevice, let newConv = onNewConversation {
                    Button(action: newConv) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 17))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("New conversation (resets Apple Intelligence context)")
                }

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Context chip
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Text(contextDescription)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - Suggestions Grid

struct SuggestionsGridView: View {
    let suggestions: [SuggestedExtension]
    let context: AppUserContext

    let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(suggestions.prefix(12)) { suggestion in
                    SuggestionCard(
                        suggestion: suggestion,
                        context: context
                    )
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Suggestion Card

struct SuggestionCard: View {
    let suggestion: SuggestedExtension
    let context: AppUserContext

    @State private var isHovered: Bool = false
    @State private var isExecuting: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Icon and relevance
            HStack {
                Image(systemName: suggestion.scriptExtension.type.icon)
                    .font(.system(size: 24))
                    .foregroundStyle(iconColor)
                    .frame(width: 40, height: 40)
                    .background(iconBackgroundColor.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Spacer()

                if isExecuting {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    relevanceBadge
                }
            }

            // Title
            Text(suggestion.scriptExtension.displayName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Reason
            Text(suggestion.reason)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Category tag
            Text(suggestion.scriptExtension.category.displayName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovered ? Color.accentColor.opacity(0.1) : Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isHovered ? Color.accentColor : Color.clear,
                    lineWidth: 2
                )
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.3), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            executeExtension()
        }
    }

    private var iconColor: Color {
        switch suggestion.relevanceScore {
        case 90...:
            return .green
        case 70..<90:
            return .blue
        default:
            return .orange
        }
    }

    private var iconBackgroundColor: Color {
        iconColor
    }

    private var relevanceBadge: some View {
        HStack(spacing: 2) {
            ForEach(0..<starCount, id: \.self) { _ in
                Image(systemName: "star.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.yellow)
            }
        }
    }

    private var starCount: Int {
        switch suggestion.relevanceScore {
        case 90...:
            return 3
        case 70..<90:
            return 2
        default:
            return 1
        }
    }

    private func executeExtension() {
        isExecuting = true

        Task {
            do {
                let input = getInputFromContext()
                let result = try await suggestion.scriptExtension.execute(with: input)

                await MainActor.run {
                    isExecuting = false
                    showSuccessNotification(result)
                }

            } catch {
                await MainActor.run {
                    isExecuting = false
                    showErrorNotification(error)
                }
            }
        }
    }

    private func getInputFromContext() -> String {
        switch context {
        case .filesSelected(let urls):
            return urls.map { $0.path }.joined(separator: "\n")
        case .textSelected(let text):
            return text
        case .url(let url):
            return url
        case .appFocused(let name, _):
            return name
        case .contactSelected(let contact):
            return contact
        case .none:
            // Try clipboard
            return NSPasteboard.general.string(forType: .string) ?? ""
        }
    }

    private func showSuccessNotification(_ result: String) {
        let notification = NSUserNotification()
        notification.title = suggestion.scriptExtension.displayName
        notification.informativeText = result.isEmpty ? "Completed successfully" : result
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }

    private func showErrorNotification(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Loading View

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Analyzing context...")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Empty Suggestions View

struct EmptySuggestionsView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No suggestions available")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)

            Text("Try selecting a file or text to get AI-powered suggestions.\n\nIf nothing appears, check Settings → General → Enable Context AI Extensions")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .onAppear {
            print("❌ [EmptySuggestionsView] Showing empty state - no suggestions found!")
            print("❌ [EmptySuggestionsView] Context AI Extensions enabled: \(AppSettings.shared.enableContextAIExtensions)")
        }
    }
}

// MARK: - Quick Action Shortcuts View

struct QuickActionShortcutsView: View {
    let suggestions: [SuggestedExtension]
    let context: AppUserContext
    
    @State private var executingID: UUID?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Actions")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions) { suggestion in
                        QuickActionChip(
                            suggestion: suggestion,
                            context: context,
                            isExecuting: executingID == suggestion.id
                        ) {
                            executeExtension(suggestion)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    
    private func executeExtension(_ suggestion: SuggestedExtension) {
        executingID = suggestion.id
        
        Task {
            do {
                let input = getInputFromContext()
                let result = try await suggestion.scriptExtension.execute(with: input)
                
                await MainActor.run {
                    executingID = nil
                    showSuccessNotification(suggestion, result: result)
                }
                
            } catch {
                await MainActor.run {
                    executingID = nil
                    showErrorNotification(suggestion, error: error)
                }
            }
        }
    }
    
    private func getInputFromContext() -> String {
        switch context {
        case .filesSelected(let urls):
            return urls.map { $0.path }.joined(separator: "\n")
        case .textSelected(let text):
            return text
        case .url(let url):
            return url
        case .appFocused(let name, _):
            return name
        case .contactSelected(let contact):
            return contact
        case .none:
            return NSPasteboard.general.string(forType: .string) ?? ""
        }
    }
    
    private func showSuccessNotification(_ suggestion: SuggestedExtension, result: String) {
        let notification = NSUserNotification()
        notification.title = suggestion.scriptExtension.displayName
        notification.informativeText = result.isEmpty ? "Completed successfully" : result
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }
    
    private func showErrorNotification(_ suggestion: SuggestedExtension, error: Error) {
        let alert = NSAlert()
        alert.messageText = "Error: \(suggestion.scriptExtension.displayName)"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Quick Action Chip

struct QuickActionChip: View {
    let suggestion: SuggestedExtension
    let context: AppUserContext
    let isExecuting: Bool
    let onTap: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                // Icon
                Image(systemName: suggestion.scriptExtension.type.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(chipColor)
                
                // Title
                Text(suggestion.scriptExtension.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                
                // Loading indicator
                if isExecuting {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                }
                
                // Relevance indicator
                if suggestion.relevanceScore >= 90 {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.yellow)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? chipColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(chipColor.opacity(isHovered ? 0.8 : 0.3), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isExecuting)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(suggestion.reason) // Tooltip
    }
    
    private var chipColor: Color {
        switch suggestion.relevanceScore {
        case 90...:
            return .green
        case 70..<90:
            return .blue
        default:
            return .orange
        }
    }
}

// MARK: - AI Input Field View

struct AIInputFieldView: View {
    @Binding var input: String
    let placeholder: String
    let isEnabled: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                
                TextField(placeholder, text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .disabled(!isEnabled)
                
                if !input.isEmpty {
                    Button(action: { input = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
            )
            
            if !isEnabled {
                Text("Select files or text to enable AI actions")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
    }
}

// MARK: - Context Change Separator

struct ContextChangeSeparator: View {
    let context: MessageContext

    private var contextIcon: String {
        switch context.contextType {
        case "file": return "doc.fill"
        case "text": return "doc.text.fill"
        case "app": return "app.fill"
        case "url": return "link"
        case "contact": return "person.crop.circle.fill"
        default: return "circle"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: 1)

            // App icon if available
            if let appPath = context.appIconPath {
                Image(nsImage: {
                    let icon = NSWorkspace.shared.icon(forFile: appPath)
                    icon.size = NSSize(width: 16, height: 16)
                    return icon
                }())
                .resizable()
                .frame(width: 16, height: 16)
            } else {
                Image(systemName: contextIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Text("Context: \(context.contextSummary)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: 1)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview {
    AIModeView(
        currentContext: .constant(AppUserContext.filesSelected([
            URL(fileURLWithPath: "/Users/test/image.jpg"),
            URL(fileURLWithPath: "/Users/test/document.pdf")
        ])),
        isVisible: .constant(true)
    )
}
