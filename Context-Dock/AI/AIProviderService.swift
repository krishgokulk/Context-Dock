//
//  AIProviderService.swift
//  ILauncher
//
//  AI Provider Service for direct chat with context awareness
//  Supports: OpenAI, Anthropic, Google Gemini, Ollama
//

import Foundation
import AppKit
import Combine
import PDFKit
import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Chat Message Models

/// Context info stored with each chat message
struct MessageContext: Codable {
    let appName: String?
    let bundleId: String?
    let appIconPath: String?
    let contextType: String // "file", "text", "app", "url", "none"
    let contextSummary: String // e.g., "2 PDF files", "VSCode", "Selected text"

    static func from(_ context: UserContext) -> MessageContext {
        switch context {
        case .filesSelected(let urls):
            let ext = urls.first?.pathExtension.uppercased() ?? "file"
            let summary = urls.count == 1 ? urls.first!.lastPathComponent : "\(urls.count) \(ext) files"
            return MessageContext(
                appName: "Finder",
                bundleId: "com.apple.finder",
                appIconPath: "/System/Library/CoreServices/Finder.app",
                contextType: "file",
                contextSummary: summary
            )
        case .textSelected(let text):
            let wordCount = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
            return MessageContext(
                appName: nil,
                bundleId: nil,
                appIconPath: nil,
                contextType: "text",
                contextSummary: "\(wordCount) words selected"
            )
        case .appFocused(let name, let bundleId):
            let appPath = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)?.path
            return MessageContext(
                appName: name,
                bundleId: bundleId,
                appIconPath: appPath,
                contextType: "app",
                contextSummary: name
            )
        case .url(let url):
            return MessageContext(
                appName: "Safari",
                bundleId: "com.apple.Safari",
                appIconPath: "/Applications/Safari.app",
                contextType: "url",
                contextSummary: String(url.prefix(30)) + (url.count > 30 ? "..." : "")
            )
        case .contactSelected(let contact):
            return MessageContext(
                appName: "Contacts",
                bundleId: "com.apple.AddressBook",
                appIconPath: "/Applications/Contacts.app",
                contextType: "contact",
                contextSummary: contact
            )
        case .none:
            return MessageContext(
                appName: nil,
                bundleId: nil,
                appIconPath: nil,
                contextType: "none",
                contextSummary: "No context"
            )
        }
    }
}

struct ChatMessage: Codable, Identifiable {
    let id: UUID
    let role: MessageRole
    let content: String
    let timestamp: Date
    let context: MessageContext?

    init(role: MessageRole, content: String, timestamp: Date = Date(), context: MessageContext? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.context = context
    }

    /// Used to update in-place (streaming): preserves the original id.
    init(id: UUID, role: MessageRole, content: String) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.context = nil
    }

    enum MessageRole: String, Codable {
        case user
        case assistant
        case system
    }
}

// MARK: - File Analysis Models

struct FileAnalysis {
    var sizeBytes: Int64 = 0
    var sizeFormatted: String = ""
    var modifiedDate: String = ""
    var type: String = "File"
    var isTextBased: Bool = false
    var isImageFile: Bool = false
    var imageURL: URL? = nil
    var contentPreview: String?
    var permissions: String = ""
}

struct FolderAnalysis {
    var totalItems: Int = 0
    var fileCount: Int = 0
    var folderCount: Int = 0
    var totalSize: Int64 = 0
    var fileTypes: [String: Int] = [:]
    var files: [(name: String, size: Int64, path: String)] = []
    var largestFiles: [(name: String, size: Int64, path: String)] = []

    var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
}

// MARK: - AI Provider Service

@MainActor
class AIProviderService: ObservableObject {
    static let shared = AIProviderService()

    /// URLSession that bypasses system proxy PAC evaluation.
    /// macOS sometimes fails to resolve the PAC file host, causing -1003 errors for all
    /// outgoing requests. Using a direct session with proxy disabled avoids this.
    nonisolated static let directSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]   // disable all proxy / PAC lookup
        config.timeoutIntervalForRequest  = 60
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    @Published var isProcessing: Bool = false
    @Published var currentResponse: String = ""
    @Published var error: String?

    // MARK: - On-Device Session Cache
    // Stored as AnyObject so the property exists on all OS versions; cast to
    // LanguageModelSession only inside `if #available(macOS 26.0, *)` blocks.
    private var _onDeviceSessionStore: AnyObject?
    private var _onDeviceSessionSystemPrompt: String = ""
    @available(macOS 26.0, *)
    private var onDeviceCachedSession: LanguageModelSession? {
        get { _onDeviceSessionStore as? LanguageModelSession }
        set { _onDeviceSessionStore = newValue }
    }

    private init() {}

    // MARK: - Main Send Message Function

    /// Send message to selected AI provider with full context awareness.
    /// When the message matches a registered L2 terminal package, the package's
    /// --help output and current Finder folder are automatically injected into the prompt.
    func sendMessage(
        _ message: String,
        context: UserContext,
        provider: AIProvider,
        apiKey: String? = nil,
        conversationHistory: [ChatMessage] = [],
        additionalContextPrompt: String = "",
        attachments: [AIAttachment] = [],
        surfaceScoped: Bool = false
    ) async throws -> String {

        #if DEBUG
        print("🤖 [AIProviderService] Sending message to \(provider.displayName)")
        #endif
        #if DEBUG
        print("🤖 [AIProviderService] Message: \(message)")
        #endif
        #if DEBUG
        print("🤖 [AIProviderService] Context: \(context.description)")
        #endif

        isProcessing = true
        error = nil

        defer {
            isProcessing = false
        }

        // Match query against registered L2 packages for tool-specific context injection.
        // Surface-scoped callers (the Quick Note sidecar, extension panels) opt out: they
        // own a narrow domain, and package matching would teach the model the
        // [TERMINAL_COMMAND: …] protocol — "new note" once matched an L2 package and came
        // back as a terminal directive instead of a note.
        let matchedPackage = surfaceScoped
            ? nil
            : TerminalPackageManager.shared.findPackageForQuery(message)

        // Capture current Finder folder only when Finder is the active context.
        // A pinned app scope in the dock should not inherit frontmost Finder folder context.
        let currentFolder: String? = await { () async -> String? in
            // A directory the user attached IS the working directory — asked first,
            // because a folder-scoped chat must not run "here" against whatever happens to
            // be frontmost. (The later `.filesSelected` fallback takes the parent, which is
            // right for a selected file and wrong for a selected folder.)
            if case .filesSelected(let urls) = context, urls.count == 1,
                let url = urls.first
            {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                    isDirectory.boolValue
                {
                    return url.path
                }
            }
            // A scoped app dock panel resolves the folder for THAT app, so a pinned scope
            // still gets its own project instead of inheriting whatever is frontmost.
            if case .appFocused(_, let bundleID) = context {
                if bundleID == "com.apple.finder" {
                    return AppleAppsAPI.shared.getCurrentFolder()
                }
                if let scoped = NSWorkspace.shared.runningApplications.first(
                    where: { $0.bundleIdentifier == bundleID }) {
                    return await ProjectContextResolver.shared.projectRoot(for: scoped)
                }
                return nil
            }
            if let frontmost = NSWorkspace.shared.frontmostApplication {
                if frontmost.bundleIdentifier == "com.apple.finder" {
                    return AppleAppsAPI.shared.getCurrentFolder()
                }
                // An editor in front means its workspace is the working directory. Without
                // this, folder-relative work silently ran in the Finder folder or ~.
                return await ProjectContextResolver.shared.projectRoot(for: frontmost)
            }
            return nil
        }()

        // Build context-aware system prompt
        let contextPrompt = await buildContextPrompt(
            for: context,
            matchedPackage: matchedPackage,
            currentFolder: currentFolder,
            originalQuery: message,
            includePrivateSafariData: shouldIncludePrivateSafariData(for: provider),
            additionalContextPrompt: additionalContextPrompt,
            surfaceScoped: surfaceScoped
        )

        #if DEBUG
        print("🤖 [AIProviderService] Context prompt built (\(contextPrompt.count) chars)")
        #endif

        let response = try await AIProviderRouter.shared.sendPrepared(
            provider: provider,
            message: message,
            context: context,
            contextPrompt: contextPrompt,
            apiKeyOverride: apiKey,
            conversationHistory: conversationHistory,
            attachments: attachments
        )

        #if DEBUG
        print("✅ [AIProviderService] Response received (\(response.count) chars)")
        #endif

        currentResponse = response

        return response
    }

    private func shouldIncludePrivateSafariData(for provider: AIProvider) -> Bool {
        switch provider {
        case .onDevice:
            return true
        case .ollama, .openAICompatible, .claudeBridge, .chatGPTBridge:
            let endpoint: String
            switch provider {
            case .ollama: endpoint = AppSettings.shared.ollamaEndpoint
            case .claudeBridge: endpoint = AppSettings.shared.claudeBridgeEndpoint
            case .chatGPTBridge: endpoint = AppSettings.shared.chatGPTBridgeEndpoint
            default: endpoint = AppSettings.shared.openAICompatibleEndpoint
            }
            guard let components = URLComponents(string: endpoint),
                  let host = components.host?.lowercased()
            else { return false }
            return host == "localhost" || host == "127.0.0.1" || host == "::1"
        case .openAI, .anthropic, .googleGemini, .kimi, .shortcuts:
            return false
        }
    }

    // MARK: - Context Prompt Builder

    /// Public wrapper used by streaming callers (e.g. AIModeView).
    func buildContextPrompt(context: UserContext) -> String {
        let settings = AppSettings.shared
        var prompt = "You are a helpful AI assistant integrated into ILauncher, a macOS launcher application. "
        prompt += "Be concise, helpful, and actionable. "
        if !settings.onDeviceSystemPrompt.isEmpty {
            prompt = settings.onDeviceSystemPrompt + "\n\n" + prompt
        }
        return prompt
    }

    /// `hasDirectoryPath` only reports what the URL was built to claim, so a path parsed
    /// from text says "file" for a real folder. The disk is asked instead.
    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    private func buildContextPrompt(
        for context: UserContext,
        matchedPackage: TerminalPackage? = nil,
        currentFolder: String? = nil,
        originalQuery: String = "",
        forToolUse: Bool = false,
        forOnDevice: Bool = false,
        includePrivateSafariData: Bool = false,
        additionalContextPrompt: String = "",
        surfaceScoped: Bool = false
    ) async -> String {
        // A scoped surface supplies its own identity in additionalContextPrompt. Layering
        // the launcher-wide preamble on top makes the model believe it can run files, apps
        // and shell commands from inside a note sidecar.
        if surfaceScoped {
            var scoped = additionalContextPrompt
            if !AppSettings.shared.onDeviceSystemPrompt.isEmpty {
                scoped = AppSettings.shared.onDeviceSystemPrompt + "\n\n" + scoped
            }
            return scoped
        }

        var prompt = "You are a helpful AI assistant integrated into ILauncher, a macOS launcher application. "
        prompt += "You help users with file management, app workflows, and productivity tasks. "
        prompt += "Be concise, helpful, and actionable. "

        if forToolUse {
            prompt += """

            ## TOOL PRIORITY RULES
            - If the user mentions a fuzzy recipient, sender, organization, contact, or event name without an exact email address, phone number, or event identifier, call `resolve_metadata` FIRST.
            - Prefer `resolve_metadata` before trying menu actions, Mail UI search, or app navigation when the missing piece is metadata.
            - Use `resolve_metadata(domain: "mail")` for names like "Uber", "my manager", or "that sender from Mail" when you need an email address.
            - Use `resolve_metadata(domain: "contacts")` for people when you need an email address or phone number.
            - Use `resolve_metadata(domain: "calendar")` for fuzzy event references.
            - After resolution, use the returned concrete value to perform the action.
            - Only use app menu tools when you already know the target metadata or when the task is explicitly about app UI operations.
            """
        }

        // --- Package-aware injection ---
        // If a registered L2 package matches the query, inject its --help syntax
        // so the AI generates syntactically correct commands instead of guessing.
        if let pkg = matchedPackage {
            // Collect selected file names from context if available
            var selectedFiles: [String] = []
            if case .filesSelected(let urls) = context {
                selectedFiles = urls.map { $0.lastPathComponent }
            }
            let folder = currentFolder ?? {
                // Also try to get folder from filesSelected context
                if case .filesSelected(let urls) = context {
                    return urls.first?.deletingLastPathComponent().path
                }
                return nil
            }()
            prompt += AITerminalPrompts.buildPackageAwarePrompt(
                package: pkg,
                query: originalQuery,
                currentFolder: folder,
                selectedFiles: selectedFiles
            )
        } else if let folder = currentFolder, !folder.isEmpty {
            // Even without a matched package, inject the current folder
            prompt += "\n\n## CURRENT WORKING DIRECTORY\n`\(folder)`\n"
            prompt += "Use this path when the user refers to 'current folder', 'here', or 'this folder'.\n"
        }

        switch context {
        case .filesSelected(let urls):
            if urls.count == 1, urls[0].hasDirectoryPath || isDirectory(urls[0]) {
                // A folder described with the file template reads as a file nobody can
                // open: "Type: —, Size: 0 bytes, no content". A folder chat asked "do you
                // know anything about this folder?" and was answered "I do not have any
                // specific information", because the section that looked authoritative was
                // empty. Folders get folder facts.
                let url = urls[0]
                prompt += "\n\n## SELECTED FOLDER\n"
                prompt += FolderScopeDigest.promptBlock(for: url)
                prompt += "\n"
            } else if urls.count == 1 {
                let url = urls[0]
                let fileInfo = await analyzeFile(url)
                prompt += "\n\n## SELECTED FILE\n"
                prompt += "• Name: \(url.lastPathComponent)\n"
                prompt += "• Path: \(url.path)\n"
                prompt += "• Type: \(fileInfo.type)\n"
                prompt += "• Size: \(fileInfo.sizeFormatted)\n"
                prompt += "• Modified: \(fileInfo.modifiedDate)\n"

                if fileInfo.isImageFile {
                    prompt += "\nThis is an image file. You can describe it, analyze its content, or help the user with image-related tasks.\n"
                    if let preview = fileInfo.contentPreview {
                        prompt += "• \(preview)\n"
                    }
                } else if fileInfo.isTextBased, let content = fileInfo.contentPreview, !content.isEmpty {
                    prompt += "\n### Full File Content\n```\n\(content)\n```\n"
                    if content.count >= 4000 {
                        prompt += "*(content truncated — file is larger than shown)*\n"
                    }
                }

                // Translation hint
                prompt += "\nIf the user asks to translate this file, translate the content above to the requested language.\n"

            } else {
                prompt += "\n\n## SELECTED FILES (\(urls.count) total)\n"
                var imageFiles: [URL] = []
                for (index, url) in urls.prefix(30).enumerated() {
                    let fileInfo = await analyzeFile(url)
                    prompt += "\(index + 1). **\(url.lastPathComponent)** — \(fileInfo.type), \(fileInfo.sizeFormatted)\n"
                    if fileInfo.isTextBased, let preview = fileInfo.contentPreview, !preview.isEmpty, urls.count <= 3 {
                        // For small selections, include content of each file
                        prompt += "   ```\n\(String(preview.prefix(1500)))\n   ```\n"
                    }
                    if fileInfo.isImageFile { imageFiles.append(url) }
                }
                if urls.count > 30 {
                    prompt += "... and \(urls.count - 30) more files\n"
                }
                if !imageFiles.isEmpty {
                    prompt += "\n\(imageFiles.count) image file(s) selected. You can help describe, analyze, or process them.\n"
                }
            }

        case .textSelected(let text):
            prompt += "\n\n## SELECTED TEXT\n"
            prompt += "```\n\(text)\n```\n"
            prompt += "\nYou can summarize, translate, rewrite, explain, or answer questions about this text. "
            prompt += "If asked to translate, output ONLY the translation in the requested language.\n"

        case .url(let urlString):
            // Multi-page research session takes priority over single page
            let research = WebResearchSession.shared
            if !research.isEmpty {
                prompt += research.count > 1 ? research.contextBlock : research.singlePageBlock
            } else {
                // Use previousFrontmostApp — when the dock is open, frontmostApplication is
                // Context-Dock itself, giving the wrong PID for AXWebReader lookups.
                let browser = AppDelegate.shared?.previousFrontmostApp
                    ?? NSWorkspace.shared.runningApplications.first(where: { AXWebReader.shared.isBrowser(bundleId: $0.bundleIdentifier ?? "") })
                let pid = browser?.processIdentifier ?? 0
                prompt += "\n\n## CURRENT WEB PAGE\nURL: \(urlString)\n"
                if let snap = AXWebReader.shared.cachedSnapshot(for: pid), !snap.text.isEmpty {
                    if !snap.title.isEmpty { prompt += "Title: \(snap.title)\n" }
                    prompt += "\n### Page Content (live, extracted from screen):\n"
                    prompt += snap.text
                    prompt += "\n\nAnswer ONLY using this content — it is the ACTUAL live text on screen.\n"
                } else {
                    Task { @MainActor in
                        AXWebReader.shared.refresh(pid: pid, currentURL: urlString)
                    }
                    prompt += "(Page content loading — answer from URL context for now)\n"
                }
                if browser?.bundleIdentifier?.hasPrefix("com.apple.Safari") == true {
                    if includePrivateSafariData {
                        prompt += SafariDeepContextReader.shared.contextBlock(
                            query: originalQuery,
                            maxRecentHistory: 50,
                            maxMatchedHistory: 35,
                            maxBookmarks: 30,
                            maxCharacters: 6_500
                        )
                    }
                }
            }

        case .appFocused(let name, let bundleID):
            if AXWebReader.shared.isBrowser(bundleId: bundleID),
               let frontmost = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
                let pid = frontmost.processIdentifier
                // Always inject current URL (fast AX read) even if full page isn't cached yet
                let liveURL = AXContextReader.shared.current.currentURL ?? ""
                prompt += "\n\n## CURRENT WEB PAGE\n"
                prompt += "URL: \(liveURL.isEmpty ? "(unknown)" : liveURL)\n"

                let research = WebResearchSession.shared
                // Only use research session if at least one page has actual text content
                let researchHasContent = research.pages.contains { !$0.text.isEmpty }
                if !research.isEmpty && researchHasContent {
                    prompt += research.count > 1 ? research.contextBlock : research.singlePageBlock
                } else if let snap = AXWebReader.shared.cachedSnapshot(for: pid), !snap.text.isEmpty {
                    if !snap.title.isEmpty { prompt += "Title: \(snap.title)\n" }
                    prompt += "\n### Page Content (live, extracted from screen):\n"
                    prompt += snap.text
                    prompt += "\n\nAnswer ONLY using the page content above — this is the actual live text on screen.\n"
                } else {
                    // Cache cold — kick off a background read for next query
                    Task { @MainActor in
                        AXWebReader.shared.refresh(pid: pid, currentURL: liveURL)
                    }
                    // If research session has the URL but no text, show what we have
                    if !research.isEmpty, let page = research.pages.first {
                        let label = page.title.isEmpty ? page.url : page.title
                        prompt += "\n(Page '\(label)' was added but content is still loading. "
                        prompt += "Try asking again in a moment for page-grounded answers.)\n"
                    } else {
                        prompt += "\n(Full page text is loading — answer from the URL above for now. "
                        prompt += "Try asking again in a moment for page-grounded answers.)\n"
                    }
                }
                if includePrivateSafariData && bundleID.hasPrefix("com.apple.Safari") {
                    prompt += SafariDeepContextReader.shared.contextBlock(
                        query: originalQuery,
                        maxRecentHistory: 50,
                        maxMatchedHistory: 35,
                        maxBookmarks: 30,
                        maxCharacters: 6_500
                    )
                }
            } else {
                prompt += "\n\nThe user is currently focused on: \(name) (\(bundleID)).\n"
                prompt += "Answer in the context of \(name).\n"
            }

            // Inject learned usage patterns for this app (from AppInteractionStore)
            let topActions = AppInteractionStore.shared.topActionIds(for: bundleID, limit: 6)
            let recentQueries = AppInteractionStore.shared.recentQueries(for: bundleID, limit: 8)
            if !topActions.isEmpty || !recentQueries.isEmpty {
                prompt += "\n\n## \(name) — Learned Usage (from this device)\n"
                if !topActions.isEmpty {
                    prompt += "Most-used actions (prefer these when relevant):\n"
                    for (id, count) in topActions {
                        let label = id.components(separatedBy: " > ").last ?? id
                        prompt += "• \(label) (used \(count)×)\n"
                    }
                }
                if !recentQueries.isEmpty {
                    prompt += "Recent queries for \(name):\n"
                    for q in recentQueries.prefix(5) {
                        prompt += "• \(q)\n"
                    }
                }
                prompt += "Use this history to anticipate intent — prefer proven actions over guessing.\n"
            }

        case .contactSelected(let contact):
            prompt += "\n\nThe user has selected a contact: \(contact)\n"

        case .none:
            prompt += "\n\nThe user is in the launcher with no specific context selected.\n"
        }

        if includePrivateSafariData,
            !prompt.contains("## Local Safari Context (private local providers only)"),
            shouldInjectPrivateSafariData(for: context)
        {
            prompt += SafariDeepContextReader.shared.contextBlock(
                query: originalQuery,
                maxRecentHistory: 50,
                maxMatchedHistory: 35,
                maxBookmarks: 30,
                maxCharacters: 6_500
            )
        }

        if includePrivateSafariData {
            let capabilityBlock: String = {
                switch context {
                case .appFocused(let name, let bundleID):
                    if let app = NSWorkspace.shared.runningApplications.first(where: {
                        $0.bundleIdentifier == bundleID && !$0.isTerminated
                    }) {
                        return AppMenuCapabilityCache.shared.contextBlock(
                            for: app,
                            query: originalQuery,
                            maxResults: 40
                        )
                    }

                    let cachedItems = AppMenuCapabilityCache.shared.menuItems(
                        bundleIdentifier: bundleID,
                        appName: name,
                        query: originalQuery,
                        maxResults: 40
                    )
                    guard !cachedItems.isEmpty else { return "" }

                    var lines = ["## Cached App Menu Capabilities"]
                    lines.append(
                        "These are previously discovered app menu actions. Validate live state before executing."
                    )
                    for item in cachedItems {
                        let shortcut = item.shortcutDisplay.map { " [\($0)]" } ?? ""
                        lines.append("- \(item.pathString)\(shortcut)")
                    }
                    return lines.joined(separator: "\n")

                default:
                    guard let app = AppDelegate.shared?.previousFrontmostApp
                        ?? NSWorkspace.shared.frontmostApplication
                    else {
                        return ""
                    }
                    return AppMenuCapabilityCache.shared.contextBlock(
                        for: app,
                        query: originalQuery,
                        maxResults: 40
                    )
                }
            }()

            if !capabilityBlock.isEmpty {
                prompt += "\n\n" + capabilityBlock
            }
        }

        let trimmedAdditionalPrompt = additionalContextPrompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !trimmedAdditionalPrompt.isEmpty {
            prompt += "\n\n" + trimmedAdditionalPrompt
        }

        prompt += "\nRespond helpfully and concisely. If the user asks about files or folders, provide specific details based on the context above."

        return prompt
    }

    private func shouldInjectPrivateSafariData(for context: UserContext) -> Bool {
        switch context {
        case .appFocused(_, let bundleID):
            return bundleID.hasPrefix("com.apple.Safari")
        case .url:
            let browser = AppDelegate.shared?.previousFrontmostApp
                ?? NSWorkspace.shared.runningApplications.first(where: {
                    AXWebReader.shared.isBrowser(bundleId: $0.bundleIdentifier ?? "")
                })
            return browser?.bundleIdentifier?.hasPrefix("com.apple.Safari") == true
        default:
            let app = AppDelegate.shared?.previousFrontmostApp
                ?? NSWorkspace.shared.frontmostApplication
            return app?.bundleIdentifier?.hasPrefix("com.apple.Safari") == true
        }
    }

    // MARK: - File Analysis

    private func analyzeFile(_ url: URL) async -> FileAnalysis {
        var analysis = FileAnalysis()

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            analysis.sizeBytes = attributes[.size] as? Int64 ?? 0
            analysis.sizeFormatted = ByteCountFormatter.string(fromByteCount: analysis.sizeBytes, countStyle: .file)

            if let modDate = attributes[.modificationDate] as? Date {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .full
                analysis.modifiedDate = formatter.localizedString(for: modDate, relativeTo: Date())
            } else {
                analysis.modifiedDate = "Unknown"
            }

            let ext = url.pathExtension.lowercased()
            analysis.type = ext.isEmpty ? "File" : ".\(ext) file"

            // ── Text-based files ──────────────────────────────────────────
            let textExtensions = ["txt", "md", "markdown", "swift", "py", "js", "ts", "jsx", "tsx",
                                  "html", "css", "scss", "json", "xml", "yaml", "yml", "csv",
                                  "log", "sh", "bash", "zsh", "conf", "config", "ini", "toml",
                                  "r", "c", "cpp", "h", "java", "go", "rs", "rb", "php", "sql"]
            analysis.isTextBased = textExtensions.contains(ext)

            if analysis.isTextBased && analysis.sizeBytes < 5_000_000 {
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    analysis.contentPreview = String(content.prefix(4000))
                } else if let content = try? String(contentsOf: url, encoding: .isoLatin1) {
                    analysis.contentPreview = String(content.prefix(4000))
                }
            }

            // ── PDF extraction ────────────────────────────────────────────
            if ext == "pdf" {
                analysis.type = "PDF document"
                analysis.isTextBased = true
                if let pdf = PDFDocument(url: url) {
                    let pageCount = pdf.pageCount
                    analysis.type = "PDF document (\(pageCount) page\(pageCount == 1 ? "" : "s"))"
                    var text = ""
                    // Extract up to 8 pages worth of text
                    for i in 0..<min(pageCount, 8) {
                        if let pageText = pdf.page(at: i)?.string {
                            text += pageText + "\n"
                        }
                        if text.count > 4000 { break }
                    }
                    analysis.contentPreview = text.isEmpty ? nil : String(text.prefix(4000))
                }
            }

            // ── Rich text / Word docs ─────────────────────────────────────
            if ["rtf", "rtfd"].contains(ext) {
                analysis.type = "Rich Text document"
                analysis.isTextBased = true
                if let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
                    analysis.contentPreview = String(attributed.string.prefix(4000))
                }
            }

            // ── Images ────────────────────────────────────────────────────
            let imageExtensions = ["jpg", "jpeg", "png", "heic", "heif", "gif", "bmp", "tiff", "tif", "webp"]
            if imageExtensions.contains(ext) {
                analysis.type = "Image (\(ext.uppercased()))"
                analysis.isImageFile = true
                analysis.imageURL = url
                // Get image dimensions
                if let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                   let w = props[kCGImagePropertyPixelWidth] as? Int,
                   let h = props[kCGImagePropertyPixelHeight] as? Int {
                    analysis.contentPreview = "Dimensions: \(w) × \(h) px"
                }
            }

            // ── Permissions ───────────────────────────────────────────────
            if let permissions = attributes[.posixPermissions] as? NSNumber {
                let perms = permissions.intValue
                let owner = (perms & 0o400 != 0 ? "r" : "-")
                          + (perms & 0o200 != 0 ? "w" : "-")
                          + (perms & 0o100 != 0 ? "x" : "-")
                analysis.permissions = owner
            }

        } catch {
            #if DEBUG
            print("⚠️ [AIProviderService] Error analyzing file: \(error)")
            #endif
        }

        return analysis
    }

    // MARK: - Folder Analysis

    func analyzeFolderContext(folderPath: String) async -> FolderAnalysis {
        var analysis = FolderAnalysis()

        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(atPath: folderPath) else {
            return analysis
        }

        analysis.totalItems = contents.count

        for item in contents {
            // Skip hidden files
            if item.hasPrefix(".") { continue }

            let itemPath = (folderPath as NSString).appendingPathComponent(item)
            guard let attributes = try? fileManager.attributesOfItem(atPath: itemPath) else { continue }

            if let isDirectory = attributes[.type] as? FileAttributeType, isDirectory == .typeDirectory {
                analysis.folderCount += 1
            } else {
                analysis.fileCount += 1

                if let size = attributes[.size] as? Int64 {
                    analysis.totalSize += size

                    // Track all files
                    analysis.files.append((name: item, size: size, path: itemPath))
                }

                // Track file types
                let ext = (item as NSString).pathExtension.lowercased()
                if !ext.isEmpty {
                    analysis.fileTypes[ext, default: 0] += 1
                }
            }
        }

        // Sort files by size (largest first)
        analysis.files.sort { $0.size > $1.size }
        analysis.largestFiles = Array(analysis.files.prefix(10))

        return analysis
    }

    // MARK: - On-Device Integration

    private func sendToOnDevice(
        message: String,
        contextPrompt: String,
        history: [ChatMessage],
        imageURLs: [URL] = []
    ) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                // OCR-extract image content and prepend so the model can reason about it
                var finalMessage = message
                let imageContent = onDeviceImageContentBlock(from: imageURLs)
                if !imageContent.isEmpty {
                    finalMessage = "\(imageContent)\n\nUser request: \(message)"
                }
                let session = try await onDeviceSession(for: contextPrompt)
                let response = try await session.respond(to: finalMessage)
                return response.content
            } catch {
                return "Apple Intelligence error: \(error.localizedDescription)\n\nMake sure Apple Intelligence is enabled in System Settings > Apple Intelligence."
            }
        }
        return "On-device AI requires macOS 26.0 (Tahoe) or later with Apple Silicon."
        #else
        return "On-device AI requires macOS 26.0 or later with Apple Silicon."
        #endif
    }

    private func shouldUseOnDeviceToolSession(for context: UserContext, message: String = "") -> Bool {
        // Pure generation / Q&A ("draft a letter", "summarize", "what is…") needs no app
        // tool. Loading the app's whole tool set for these can stall the on-device model
        // (the reply never streams → the chat sticks on an empty bubble). Use plain
        // streaming for those; reserve the tool session for action-shaped requests.
        let m = message.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let generationHints = [
            "draft", "write", "compose", "rewrite", "rephrase", "summarize", "summarise",
            "translate", "explain", "describe", "reply", "respond", "answer", "suggest",
            "improve", "proofread", "what", "why", "how", "who", "when", "where",
            "tell me", "give me",
        ]
        if generationHints.contains(where: { m.hasPrefix($0 + " ") || m == $0 }) {
            return false
        }
        if case .appFocused(_, let bundleID) = context {
            // Browsers need the streaming path so they receive live page content from AXWebReader.
            // Tool session gets an empty AX context when the dock is frontmost (not the browser).
            if AXWebReader.shared.isBrowser(bundleId: bundleID) { return false }
            return !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }

    private func onDeviceToolContext(for context: UserContext) -> (bundleId: String, axContext: AXContext)? {
        guard case .appFocused(let name, let bundleID) = context else { return nil }
        let liveAX = AXContextReader.shared.current
        if liveAX.bundleId == bundleID {
            return (bundleID, liveAX)
        }

        let pid = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })?
            .processIdentifier ?? 0
        let fallback = AXContext(
            appName: name,
            bundleId: bundleID,
            pid: pid,
            selectedText: nil,
            currentURL: nil,
            windowTitle: nil,
            focusedElementRole: nil,
            selectedFilePaths: [],
            menuItems: []
        )
        return (bundleID, fallback)
    }

    /// Public async on-device invocation — builds full file/PDF/image context from UserContext.
    /// Used by ContentView's L2 and quick-action paths so on-device AI gets the same rich context
    /// as cloud providers (document summarization, PDF analysis, translation, etc.).
    func sendOnDevice(
        _ message: String,
        context: UserContext,
        history: [ChatMessage] = [],
        additionalContextPrompt: String = ""
    ) async throws -> String {
        let useTools = shouldUseOnDeviceToolSession(for: context, message: message)
        let matchedPackage = TerminalPackageManager.shared.findPackageForQuery(message)
        let contextPrompt = await buildContextPrompt(
            for: context,
            matchedPackage: matchedPackage,
            originalQuery: message,
            forToolUse: useTools,
            forOnDevice: true,
            includePrivateSafariData: false,
            additionalContextPrompt: additionalContextPrompt
        )
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), useTools, let toolContext = onDeviceToolContext(for: context) {
            return try await OnDeviceToolSession.shared.respond(
                to: message,
                systemPrompt: contextPrompt,
                bundleId: toolContext.bundleId,
                axContext: toolContext.axContext
            )
        }
        #endif
        return try await sendToOnDevice(message: message, contextPrompt: contextPrompt, history: history)
    }

    // MARK: - On-Device Streaming

    /// Streams tokens from on-device Apple Intelligence.
    /// Accepts UserContext so it can build the full file-aware system prompt (same as cloud AI).
    func streamOnDeviceResponse(
        message: String,
        imageURLs: [URL] = [],
        context: UserContext,
        history: [ChatMessage],
        additionalContextPrompt: String = "",
        onPartial: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            Task {
                do {
                    // ── 1. For browser contexts: force-refresh page content first ──
                    let browserBundles = ["com.apple.Safari","com.google.Chrome","com.brave.Browser",
                                          "org.chromium.Chromium","com.microsoft.edgemac"]
                    if case .url(let urlString) = context {
                        let browser = AppDelegate.shared?.previousFrontmostApp
                            ?? NSWorkspace.shared.runningApplications.first(where: { browserBundles.contains($0.bundleIdentifier ?? "") })
                        if let pid = browser?.processIdentifier, pid != 0 {
                            if AXWebReader.shared.cachedSnapshot(for: pid)?.text.isEmpty != false {
                                AXWebReader.shared.refresh(pid: pid, currentURL: urlString)
                                try? await Task.sleep(nanoseconds: 600_000_000) // give AX 600ms to read
                            }
                        }
                    } else if case .appFocused(_, let bid) = context,
                              AXWebReader.shared.isBrowser(bundleId: bid) {
                        // If research session has pages with empty text, fetch them now before answering
                        let research = WebResearchSession.shared
                        let emptyPages = await MainActor.run { research.pages.filter { $0.text.isEmpty } }
                        for page in emptyPages {
                            // Try JS fetch via the open Safari tab that matches this URL
                            let tabs = await SafariTabManager.shared.fetchTabs()
                            if let tab = tabs.first(where: { $0.url == page.url }) {
                                let js = "document.body ? document.body.innerText.substring(0, 5000) : ''"
                                if let text = await SafariTabManager.shared.executeJS(js, windowIndex: tab.windowIndex, tabIndex: tab.tabIndex),
                                   !text.isEmpty {
                                    await MainActor.run { WebResearchSession.shared.updateText(url: page.url, text: text) }
                                }
                            }
                        }
                        // Also try AX refresh if cache is cold
                        if let browser = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid }) {
                            let pid = browser.processIdentifier
                            let liveURL = AXContextReader.shared.current.currentURL ?? ""
                            if AXWebReader.shared.cachedSnapshot(for: pid)?.text.isEmpty != false {
                                AXWebReader.shared.refresh(pid: pid, currentURL: liveURL)
                                try? await Task.sleep(nanoseconds: 400_000_000)
                            }
                        }
                    }

                    // ── 2. Build full context prompt with live page / file content ──
                    let useTools = self.shouldUseOnDeviceToolSession(for: context, message: message)
                    let matchedPackage = TerminalPackageManager.shared.findPackageForQuery(message)
                    let contextPrompt = await buildContextPrompt(
                        for: context,
                        matchedPackage: matchedPackage,
                        originalQuery: message,
                        forToolUse: useTools,
                        forOnDevice: true,
                        includePrivateSafariData: false,
                        additionalContextPrompt: additionalContextPrompt
                    )

                    #if canImport(FoundationModels)
                    if #available(macOS 26.0, *), useTools, let toolContext = self.onDeviceToolContext(for: context) {
                        await OnDeviceToolSession.shared.stream(
                            to: message,
                            imageURLs: imageURLs,
                            systemPrompt: contextPrompt,
                            bundleId: toolContext.bundleId,
                            axContext: toolContext.axContext,
                            onPartial: onPartial,
                            onComplete: onComplete,
                            onError: onError
                        )
                        return
                    }
                    #endif

                    // ── 3. Build the full prompt including conversation history ──
                    var fullPrompt = contextPrompt + "\n\n"
                    if !history.isEmpty {
                        fullPrompt += "## Conversation History\n"
                        for msg in history.suffix(6) { // last 6 turns
                            let role = msg.role == .user ? "User" : "Assistant"
                            fullPrompt += "\(role): \(msg.content)\n"
                        }
                        fullPrompt += "\n"
                    }

                    let session = try await onDeviceSession(for: fullPrompt)

                    var lastLength = 0
                    var finalContent = ""

                    let imageContent = self.onDeviceImageContentBlock(from: imageURLs)
                    let finalMessage = imageContent.isEmpty
                        ? message
                        : "\(imageContent)\n\nUser request: \(message)"
                    let stream = session.streamResponse(to: finalMessage, generating: String.self)
                    for try await snapshot in stream {
                        let full = snapshot.content
                        let delta = String(full.dropFirst(lastLength))
                        lastLength = full.count
                        finalContent = full
                        if !delta.isEmpty { onPartial(delta) }
                    }
                    if finalContent.isEmpty { finalContent = "Done." }
                    onComplete(finalContent)
                } catch {
                    onError("Apple Intelligence error: \(error.localizedDescription)")
                }
            }
            return
        }
        onError("On-device AI requires macOS 26.0 or later with Apple Silicon.")
        #else
        onError("On-device AI requires macOS 26.0 or later with Apple Silicon.")
        #endif
    }

    // MARK: - On-Device Helpers

    /// Returns image URLs from a file selection context.
    private func extractImageURLs(from context: UserContext) -> [URL] {
        guard case .filesSelected(let urls) = context else { return [] }
        let imageExtensions = Set(["jpg", "jpeg", "png", "heic", "heif", "gif", "bmp", "tiff", "tif", "webp"])
        return urls.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
    }

    private func onDeviceImageContentBlock(from imageURLs: [URL]) -> String {
        guard !imageURLs.isEmpty else { return "" }

        var sections: [String] = []
        for url in imageURLs.prefix(8) {
            var lines = ["### \(url.lastPathComponent)"]
            guard let image = NSImage(contentsOf: url) else {
                lines.append("Image could not be loaded from \(url.path).")
                sections.append(lines.joined(separator: "\n"))
                continue
            }

            let size = image.size
            if size.width > 0, size.height > 0 {
                lines.append("Size: \(Int(size.width)) x \(Int(size.height)) px")
            }

            if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform([request])
                let recognized = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if !recognized.isEmpty {
                    lines.append("Recognized text:")
                    lines.append(recognized.joined(separator: "\n"))
                } else {
                    lines.append("No readable text detected. Use the image file metadata only.")
                }
            }
            sections.append(lines.joined(separator: "\n"))
        }

        if imageURLs.count > 8 {
            sections.append("... \(imageURLs.count - 8) more image attachment(s) omitted.")
        }
        return "## Image Attachments (local OCR)\n" + sections.joined(separator: "\n\n")
    }

    /// Returns a cached `LanguageModelSession` for the given system prompt.
    /// Creates a new session when the context changes (new file selected, etc.)
    @available(macOS 26.0, *)
    private func onDeviceSession(for contextPrompt: String) async throws -> LanguageModelSession {
        let settings = AppSettings.shared
        // Merge custom system prompt with context — never discard file/PDF/URL context
        let systemPrompt: String
        if settings.onDeviceSystemPrompt.isEmpty {
            systemPrompt = contextPrompt
        } else {
            systemPrompt = settings.onDeviceSystemPrompt + "\n\n" + contextPrompt
        }

        // Check Apple Intelligence availability
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw NSError(domain: "ILauncher", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence is not available. Enable it in System Settings > Apple Intelligence."])
        }

        // Reuse session only if context is identical — rebuild when file/context changes
        if let existing = onDeviceCachedSession, _onDeviceSessionSystemPrompt == systemPrompt {
            return existing
        }

        let session = LanguageModelSession(instructions: systemPrompt)
        onDeviceCachedSession = session
        _onDeviceSessionSystemPrompt = systemPrompt
        return session
    }

    /// Resets the on-device session (call when user clears conversation).
    func resetOnDeviceSession() {
        _onDeviceSessionStore = nil
        _onDeviceSessionSystemPrompt = ""
    }

    func sendPreparedOnDevice(
        message: String,
        contextPrompt: String,
        history: [ChatMessage],
        imageURLs: [URL] = []
    ) async throws -> String {
        try await sendToOnDevice(
            message: message,
            contextPrompt: contextPrompt,
            history: history,
            imageURLs: imageURLs
        )
    }

    // MARK: - Executed Command Record

    struct ExecutedCommand {
        let command: String
        let output: String
        let success: Bool
        let isVerification: Bool

        init(
            command: String,
            output: String,
            success: Bool,
            isVerification: Bool = false
        ) {
            self.command = command
            self.output = output
            self.success = success
            self.isVerification = isVerification
            TaskRunStore.shared.record(self)
        }
    }

    // MARK: - Tool-Use Dispatcher

    /// Tool-calling entry point for the L2 terminal layer.
    /// Runs up to `maxIterations` rounds: send → detect tool_call → execute → feed result back → repeat.
    /// Custom L2 extensions are automatically included alongside run_command.
    /// Throws `AIServiceError.unsupportedProvider("onDevice_fallback")` for OnDevice — caller must catch and use legacy path.
    func sendWithTools(
        _ message: String,
        context: UserContext,
        provider: AIProvider,
        apiKey: String?,
        conversationHistory: [ChatMessage],
        commandExecutor: @escaping (String, String, Bool) async -> (Bool, String, Int32),
        maxIterations: Int = 5,
        systemPromptOverride: String? = nil,
        additionalSystemPrompt: String? = nil,
        imageAttachments: [URL] = [],
        /// The thread asking, so tools inherit its folder boundary and its artifact home.
        chatScope: GeneralChatScope? = nil,
        simulateAllTools: Bool = false,
        /// Called as the answer is written, when the provider supports it. Nil keeps the
        /// buffered behaviour — a caller that has nowhere to put a partial answer should not
        /// be handed one.
        onStream: (@Sendable (AIProviderStreamEvent) -> Void)? = nil
    ) async throws -> (finalResponse: String, executedCommands: [ExecutedCommand]) {

        let resume = TaskRunStore.shared.resolve(message)
        let effectiveMessage = resume.message
        let guardedCommandExecutor: (String, String, Bool) async -> (Bool, String, Int32) = {
            command, purpose, approval in
            if let cached = TaskRunStore.shared.cachedSuccessfulCommand(command, from: resume.source) {
                return (true, "Resumed from durable receipt: \(cached.output)", 0)
            }
            return await commandExecutor(command, purpose, approval)
        }

        return try await TaskRunStore.shared.track(
            request: resume.source?.request ?? message,
            provider: String(describing: provider),
            resumedFrom: resume.source?.id
        ) {

        var contextPrompt: String
        if let override = systemPromptOverride {
            contextPrompt = override
        } else {
            contextPrompt = await buildContextPrompt(for: context, originalQuery: effectiveMessage, forToolUse: true)
        }
        if let additional = additionalSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
            !additional.isEmpty
        {
            contextPrompt += "\n\n" + additional
        }
        let extManager = L2ExtensionManager.shared

        switch provider {
        case .openAI:
            guard let key = apiKey, !key.isEmpty else {
                throw AIServiceError.missingAPIKey("OpenAI API key is required")
            }
            let customTools = extManager.toolSchemas(for: .openAI)
            return try await sendOpenAIWithTools(
                message: effectiveMessage, contextPrompt: contextPrompt, apiKey: key,
                history: conversationHistory, commandExecutor: guardedCommandExecutor,
                customTools: customTools,
                maxIterations: maxIterations, endpoint: "https://api.openai.com/v1/chat/completions",
                model: AppSettings.shared.selectedOpenAIModel.isEmpty
                    ? "gpt-4o-mini" : AppSettings.shared.selectedOpenAIModel,
                transport: OpenAIToolProviderAdapter(),
                imageAttachments: imageAttachments,
                userContext: context,
                chatScope: chatScope,
                simulateAllTools: simulateAllTools,
                onStream: onStream
            )

        case .anthropic:
            guard let key = apiKey, !key.isEmpty else {
                throw AIServiceError.missingAPIKey("Anthropic API key is required")
            }
            let customTools = extManager.toolSchemas(for: .anthropic)
            return try await sendAnthropicWithTools(
                message: effectiveMessage, contextPrompt: contextPrompt, apiKey: key,
                history: conversationHistory, commandExecutor: guardedCommandExecutor,
                customTools: customTools,
                maxIterations: maxIterations,
                model: AppSettings.shared.selectedAnthropicModel.isEmpty
                    ? AnthropicModelCatalog.defaultModelID
                    : AppSettings.shared.selectedAnthropicModel,
                imageAttachments: imageAttachments,
                userContext: context,
                chatScope: chatScope,
                simulateAllTools: simulateAllTools,
                onStream: onStream
            )

        case .googleGemini:
            guard let key = apiKey, !key.isEmpty else {
                throw AIServiceError.missingAPIKey("Google Gemini API key is required")
            }
            let customTools = extManager.toolSchemas(for: .gemini)
            return try await sendGeminiWithTools(
                message: effectiveMessage, contextPrompt: contextPrompt, apiKey: key,
                history: conversationHistory, commandExecutor: guardedCommandExecutor,
                customTools: customTools,
                maxIterations: maxIterations,
                imageAttachments: imageAttachments,
                userContext: context,
                chatScope: chatScope,
                simulateAllTools: simulateAllTools,
                onStream: onStream
            )

        case .ollama:
            let settings = AppSettings.shared
            let model = settings.selectedOllamaModel.isEmpty ? "llama2" : settings.selectedOllamaModel
            let endpoint = settings.ollamaEndpoint.isEmpty ? "http://localhost:11434" : settings.ollamaEndpoint
            let customTools = extManager.toolSchemas(for: .openAI)
            // Use OpenAI-compatible endpoint (/v1/chat/completions) so response format matches OpenAIToolResponse
            return try await sendOpenAIWithTools(
                message: effectiveMessage, contextPrompt: contextPrompt, apiKey: nil,
                history: conversationHistory, commandExecutor: guardedCommandExecutor,
                customTools: customTools,
                maxIterations: maxIterations,
                endpoint: "\(endpoint)/v1/chat/completions",
                model: model,
                timeout: 120,
                extraHeaders: [:],
                transport: OllamaToolProviderAdapter(),
                simulateAllTools: simulateAllTools,
                onStream: onStream
            )

        case .openAICompatible:
            let settings = AppSettings.shared
            let endpoint = settings.openAICompatibleEndpoint
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !endpoint.isEmpty, !settings.openAICompatibleModelID.isEmpty else {
                throw AIServiceError.networkError("OpenAI-compatible endpoint and model ID are required")
            }
            let key = apiKey ?? settings.openAICompatibleAPIKey
            let customTools = extManager.toolSchemas(for: .openAI)
            return try await sendOpenAIWithTools(
                message: effectiveMessage, contextPrompt: contextPrompt,
                apiKey: key.isEmpty ? nil : key,
                history: conversationHistory, commandExecutor: guardedCommandExecutor,
                customTools: customTools, maxIterations: maxIterations,
                endpoint: endpoint.hasSuffix("chat/completions")
                    ? endpoint : "\(endpoint)/chat/completions",
                model: settings.openAICompatibleModelID,
                timeout: 120,
                extraHeaders: [:],
                transport: OpenAICompatibleToolProviderAdapter(),
                simulateAllTools: simulateAllTools,
                onStream: onStream
            )

        case .kimi:
            guard let key = apiKey, !key.isEmpty else {
                throw AIServiceError.missingAPIKey("Kimi API key is required")
            }
            let customTools = extManager.toolSchemas(for: .openAI)
            return try await sendOpenAIWithTools(
                message: effectiveMessage,
                contextPrompt: contextPrompt,
                apiKey: key,
                history: conversationHistory,
                commandExecutor: guardedCommandExecutor,
                customTools: customTools,
                maxIterations: maxIterations,
                endpoint: "https://api.moonshot.ai/v1/chat/completions",
                model: AppSettings.shared.selectedKimiModel,
                timeout: 120,
                extraHeaders: [:],
                transport: OpenAICompatibleToolProviderAdapter(),
                imageAttachments: imageAttachments,
                userContext: context,
                chatScope: chatScope,
                simulateAllTools: simulateAllTools,
                onStream: onStream)

        case .claudeBridge:
            let settings = AppSettings.shared
            let endpoint = settings.claudeBridgeEndpoint
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !endpoint.isEmpty, !settings.claudeBridgeModelID.isEmpty else {
                throw AIServiceError.networkError("Claude bridge endpoint and model ID are required")
            }
            let customTools = extManager.toolSchemas(for: .openAI)
            return try await sendOpenAIWithTools(
                message: effectiveMessage,
                contextPrompt: contextPrompt,
                apiKey: nil,
                history: conversationHistory,
                commandExecutor: guardedCommandExecutor,
                customTools: customTools,
                maxIterations: maxIterations,
                endpoint: endpoint.hasSuffix("chat/completions")
                    ? endpoint : "\(endpoint)/chat/completions",
                model: settings.claudeBridgeModelID,
                timeout: 120,
                extraHeaders: [:],
                transport: OpenAICompatibleToolProviderAdapter(),
                simulateAllTools: simulateAllTools,
                onStream: onStream
            )

        case .chatGPTBridge:
            let settings = AppSettings.shared
            let endpoint = settings.chatGPTBridgeEndpoint
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !endpoint.isEmpty, !settings.chatGPTBridgeModelID.isEmpty else {
                throw AIServiceError.networkError("ChatGPT bridge endpoint and model ID are required")
            }
            let customTools = extManager.toolSchemas(for: .openAI)
            return try await sendOpenAIWithTools(
                message: effectiveMessage,
                contextPrompt: contextPrompt,
                apiKey: nil,
                history: conversationHistory,
                commandExecutor: guardedCommandExecutor,
                customTools: customTools,
                maxIterations: maxIterations,
                endpoint: endpoint.hasSuffix("chat/completions")
                    ? endpoint : "\(endpoint)/chat/completions",
                model: settings.chatGPTBridgeModelID,
                timeout: 120,
                extraHeaders: [:],
                transport: OpenAICompatibleToolProviderAdapter(),
                simulateAllTools: simulateAllTools,
                onStream: onStream
            )

        default:
            throw AIServiceError.unsupportedProvider("onDevice_fallback")
        }
        }
    }

}

// MARK: - AI Service Errors

enum AIServiceError: LocalizedError {
    case missingAPIKey(String)
    case authenticationFailed(String)
    case networkError(String)
    case emptyResponse(String)
    case unsupportedProvider(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let message),
             .authenticationFailed(let message),
             .networkError(let message),
             .emptyResponse(let message),
             .unsupportedProvider(let message):
            return message
        }
    }
}
