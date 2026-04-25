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
        additionalContextPrompt: String = ""
    ) async throws -> String {

        print("🤖 [AIProviderService] Sending message to \(provider.displayName)")
        print("🤖 [AIProviderService] Message: \(message)")
        print("🤖 [AIProviderService] Context: \(context.description)")

        isProcessing = true
        error = nil

        defer {
            isProcessing = false
        }

        // Match query against registered L2 packages for tool-specific context injection
        let matchedPackage = TerminalPackageManager.shared.findPackageForQuery(message)

        // Capture current Finder folder only when Finder is the active context.
        // A pinned app scope in the dock should not inherit frontmost Finder folder context.
        let currentFolder: String? = {
            if case .appFocused(_, let bundleID) = context,
               bundleID != "com.apple.finder" {
                return nil
            }
            if let frontmost = NSWorkspace.shared.frontmostApplication,
               frontmost.bundleIdentifier == "com.apple.finder" {
                return AppleAppsAPI.shared.getCurrentFolder()
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
            additionalContextPrompt: additionalContextPrompt
        )

        print("🤖 [AIProviderService] Context prompt built (\(contextPrompt.count) chars)")

        // Route to appropriate provider
        let response: String

        switch provider {
        case .openAI:
            guard let key = apiKey, !key.isEmpty else {
                throw AIServiceError.missingAPIKey("OpenAI API key is required")
            }
            response = try await sendToOpenAI(
                message: message,
                contextPrompt: contextPrompt,
                apiKey: key,
                history: conversationHistory
            )

        case .anthropic:
            guard let key = apiKey, !key.isEmpty else {
                throw AIServiceError.missingAPIKey("Anthropic API key is required")
            }
            response = try await sendToAnthropic(
                message: message,
                contextPrompt: contextPrompt,
                apiKey: key,
                history: conversationHistory
            )

        case .googleGemini:
            guard let key = apiKey, !key.isEmpty else {
                throw AIServiceError.missingAPIKey("Google Gemini API key is required")
            }
            response = try await sendToGemini(
                message: message,
                contextPrompt: contextPrompt,
                apiKey: key,
                history: conversationHistory
            )

        case .ollama:
            let settings = AppSettings.shared
            let model = settings.selectedOllamaModel.isEmpty ? "llama2" : settings.selectedOllamaModel
            response = try await sendToOllama(
                message: message,
                contextPrompt: contextPrompt,
                endpoint: settings.ollamaEndpoint,
                model: model,
                history: conversationHistory
            )

        case .onDevice:
            response = try await sendToOnDevice(
                message: message,
                contextPrompt: contextPrompt,
                history: conversationHistory
            )

        case .shortcuts:
            throw AIServiceError.unsupportedProvider("Shortcuts-based chat is not yet implemented. Please select OpenAI, Anthropic, Gemini, or Ollama.")
        }

        print("✅ [AIProviderService] Response received (\(response.count) chars)")

        currentResponse = response

        return response
    }

    private func shouldIncludePrivateSafariData(for provider: AIProvider) -> Bool {
        switch provider {
        case .onDevice:
            return true
        case .ollama:
            guard let components = URLComponents(string: AppSettings.shared.ollamaEndpoint),
                  let host = components.host?.lowercased()
            else { return false }
            return host == "localhost" || host == "127.0.0.1" || host == "::1"
        case .openAI, .anthropic, .googleGemini, .shortcuts:
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

    private func buildContextPrompt(
        for context: UserContext,
        matchedPackage: TerminalPackage? = nil,
        currentFolder: String? = nil,
        originalQuery: String = "",
        forToolUse: Bool = false,
        forOnDevice: Bool = false,
        includePrivateSafariData: Bool = false,
        additionalContextPrompt: String = ""
    ) async -> String {
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
            if urls.count == 1 {
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
                    Task.detached(priority: .background) {
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
                    Task.detached(priority: .background) {
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
            print("⚠️ [AIProviderService] Error analyzing file: \(error)")
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
        history: [ChatMessage]
    ) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                let session = try await onDeviceSession(for: contextPrompt)
                let response = try await session.respond(to: message)
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

    private func shouldUseOnDeviceToolSession(for context: UserContext) -> Bool {
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
        let useTools = shouldUseOnDeviceToolSession(for: context)
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
                    let useTools = self.shouldUseOnDeviceToolSession(for: context)
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

                    let stream = session.streamResponse(to: message, generating: String.self)
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

    // MARK: - Pure Chat Session (AI chat mode — no instructions, no context overhead)

    /// Sends a message to Apple Foundation Models — no system prompt, no context injection.
    /// Creates a fresh LanguageModelSession per call so the model never receives accumulated
    /// transcript history. This is the standard pattern for stable Foundation Models usage.
    func sendPureChat(
        message: String,
        onComplete: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            Task {
                print("🤖 [FoundationModels] Checking availability...")
                let model = SystemLanguageModel.default
                print("🤖 [FoundationModels] Availability: \(model.availability)")
                guard case .available = model.availability else {
                    print("🤖 [FoundationModels] Not available — aborting")
                    onError("Apple Intelligence is not available. Enable it in System Settings > Apple Intelligence.")
                    return
                }
                print("🤖 [FoundationModels] Creating fresh session...")
                let session = LanguageModelSession()
                print("🤖 [FoundationModels] Calling respond(to:)...")
                do {
                    let response = try await session.respond(to: message)
                    let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    print("🤖 [FoundationModels] Got response (\(text.count) chars)")
                    onComplete(text.isEmpty ? "…" : text)
                } catch {
                    print("🤖 [FoundationModels] ERROR: \(error)")
                    onError("Apple Intelligence error: \(error.localizedDescription)")
                }
            }
            return
        }
        onError("Apple Intelligence requires macOS 26.0 or later with Apple Intelligence enabled.")
        #else
        onError("Apple Intelligence requires macOS 26.0 or later with Apple Intelligence enabled.")
        #endif
    }

    // MARK: - OpenAI Integration

    private func sendToOpenAI(
        message: String,
        contextPrompt: String,
        apiKey: String,
        history: [ChatMessage]
    ) async throws -> String {

        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var messages: [[String: String]] = [
            ["role": "system", "content": contextPrompt]
        ]

        // Add conversation history (limit to last 10 messages)
        let recentHistory = history.suffix(10).filter { $0.role != .system }
        for msg in recentHistory {
            messages.append(["role": msg.role.rawValue, "content": msg.content])
        }

        // Add current message
        messages.append(["role": "user", "content": message])

        let body: [String: Any] = [
            "model": "gpt-4o-mini",  // Fast and cost-effective
            "messages": messages,
            "temperature": 0.7,
            "max_tokens": 1000
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await AIProviderService.directSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.networkError("Invalid response")
        }

        if httpResponse.statusCode == 401 {
            throw AIServiceError.authenticationFailed("Invalid OpenAI API key")
        } else if httpResponse.statusCode != 200 {
            throw AIServiceError.networkError("HTTP \(httpResponse.statusCode)")
        }

        let openAIResponse = try JSONDecoder().decode(OpenAIResponse.self, from: data)

        guard let content = openAIResponse.choices.first?.message.content else {
            throw AIServiceError.emptyResponse("No response from OpenAI")
        }

        return content
    }

    struct OpenAIResponse: Codable {
        let choices: [Choice]

        struct Choice: Codable {
            let message: Message
        }

        struct Message: Codable {
            let content: String
        }
    }

    // MARK: - Anthropic Integration

    private func sendToAnthropic(
        message: String,
        contextPrompt: String,
        apiKey: String,
        history: [ChatMessage]
    ) async throws -> String {

        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var messages: [[String: String]] = []

        // Add conversation history (limit to last 10 messages)
        let recentHistory = history.suffix(10).filter { $0.role != .system }
        for msg in recentHistory {
            messages.append(["role": msg.role.rawValue, "content": msg.content])
        }

        // Add current message
        messages.append(["role": "user", "content": message])

        let body: [String: Any] = [
            "model": "claude-3-5-haiku-20241022",  // Fast and cost-effective
            "system": contextPrompt,
            "messages": messages,
            "max_tokens": 1024
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await AIProviderService.directSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.networkError("Invalid response")
        }

        if httpResponse.statusCode == 401 {
            throw AIServiceError.authenticationFailed("Invalid Anthropic API key")
        } else if httpResponse.statusCode != 200 {
            throw AIServiceError.networkError("HTTP \(httpResponse.statusCode)")
        }

        let anthropicResponse = try JSONDecoder().decode(AnthropicResponse.self, from: data)

        guard let content = anthropicResponse.content.first?.text else {
            throw AIServiceError.emptyResponse("No response from Anthropic")
        }

        return content
    }

    struct AnthropicResponse: Codable {
        let content: [Content]

        struct Content: Codable {
            let text: String
        }
    }

    // MARK: - Google Gemini Integration

    private func sendToGemini(
        message: String,
        contextPrompt: String,
        apiKey: String,
        history: [ChatMessage]
    ) async throws -> String {

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        var contents: [[String: Any]] = []

        // Add system prompt as first user message
        contents.append([
            "role": "user",
            "parts": [["text": contextPrompt]]
        ])

        // Add placeholder model response
        contents.append([
            "role": "model",
            "parts": [["text": "Understood. I'll help with the context you've provided."]]
        ])

        // Add conversation history (limit to last 10 messages)
        let recentHistory = history.suffix(10).filter { $0.role != .system }
        for msg in recentHistory {
            let role = msg.role == .assistant ? "model" : "user"
            contents.append([
                "role": role,
                "parts": [["text": msg.content]]
            ])
        }

        // Add current message
        contents.append([
            "role": "user",
            "parts": [["text": message]]
        ])

        let body: [String: Any] = [
            "contents": contents,
            "generationConfig": [
                "temperature": 0.7,
                "maxOutputTokens": 1000
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await AIProviderService.directSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.networkError("Invalid response")
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw AIServiceError.authenticationFailed("Invalid Google Gemini API key. Check Settings → Gemini API Key.")
        } else if httpResponse.statusCode == 429 {
            throw AIServiceError.networkError("Gemini free tier quota exceeded. Wait a minute and try again, or use a different AI provider.")
        } else if httpResponse.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIServiceError.networkError("Gemini error \(httpResponse.statusCode): \(body.prefix(200))")
        }

        let geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)

        guard let content = geminiResponse.candidates.first?.content.parts.first?.text else {
            throw AIServiceError.emptyResponse("No response from Gemini")
        }

        return content
    }

    struct GeminiResponse: Codable {
        let candidates: [Candidate]

        struct Candidate: Codable {
            let content: Content
        }

        struct Content: Codable {
            let parts: [Part]
        }

        struct Part: Codable {
            let text: String
        }
    }

    // MARK: - Ollama Integration

    private func sendToOllama(
        message: String,
        contextPrompt: String,
        endpoint: String,
        model: String,
        history: [ChatMessage]
    ) async throws -> String {

        let url = URL(string: "\(endpoint)/api/chat")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60 // Longer timeout for local models

        var messages: [[String: String]] = [
            ["role": "system", "content": contextPrompt]
        ]

        // Add conversation history (limit to last 10 messages)
        let recentHistory = history.suffix(10).filter { $0.role != .system }
        for msg in recentHistory {
            messages.append(["role": msg.role.rawValue, "content": msg.content])
        }

        // Add current message
        messages.append(["role": "user", "content": message])

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false,
            "options": [
                "temperature": 0.7,
                "num_predict": 1000
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await AIProviderService.directSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.networkError("Invalid response from Ollama")
        }

        if httpResponse.statusCode != 200 {
            throw AIServiceError.networkError("Ollama error: HTTP \(httpResponse.statusCode). Make sure Ollama is running at \(endpoint)")
        }

        let ollamaResponse = try JSONDecoder().decode(OllamaResponse.self, from: data)

        return ollamaResponse.message.content
    }

    struct OllamaResponse: Codable {
        let message: Message

        struct Message: Codable {
            let content: String
        }
    }

    // MARK: - AnyCodable (for Anthropic tool input decoding)

    struct AnyCodable: Codable {
        let value: Any

        init(_ value: Any) { self.value = value }

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let v = try? c.decode(Bool.self)                    { value = v; return }
            if let v = try? c.decode(Int.self)                     { value = v; return }
            if let v = try? c.decode(Double.self)                  { value = v; return }
            if let v = try? c.decode(String.self)                  { value = v; return }
            if let v = try? c.decode([String: AnyCodable].self)    { value = v; return }
            if let v = try? c.decode([AnyCodable].self)            { value = v; return }
            value = ()
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch value {
            case let v as Bool:                  try c.encode(v)
            case let v as Int:                   try c.encode(v)
            case let v as Double:                try c.encode(v)
            case let v as String:                try c.encode(v)
            case let v as [String: AnyCodable]:  try c.encode(v)
            case let v as [AnyCodable]:          try c.encode(v)
            default:                             try c.encodeNil()
            }
        }
    }

    // MARK: - Tool-Use Response Models

    struct OpenAIToolResponse: Codable {
        let choices: [Choice]
        struct Choice: Codable {
            let message: Message
            let finish_reason: String?
        }
        struct Message: Codable {
            let role: String
            let content: String?
            let tool_calls: [ToolCall]?
        }
        struct ToolCall: Codable {
            let id: String
            let type: String
            let function: FunctionCall
        }
        struct FunctionCall: Codable {
            let name: String
            let arguments: String
        }
    }

    struct AnthropicToolResponse: Codable {
        let content: [ContentBlock]
        let stop_reason: String?
        struct ContentBlock: Codable {
            let type: String
            let text: String?
            let id: String?
            let name: String?
            let input: [String: AnyCodable]?
        }
    }

    struct GeminiToolResponse: Codable {
        let candidates: [Candidate]
        struct Candidate: Codable {
            let content: Content
            let finishReason: String?
        }
        struct Content: Codable {
            let parts: [Part]
            let role: String?
        }
        struct Part: Codable {
            let text: String?
            let functionCall: FunctionCall?
        }
        struct FunctionCall: Codable {
            let name: String
            let args: [String: AnyCodable]
        }
    }

    // MARK: - Executed Command Record

    struct ExecutedCommand {
        let command: String
        let output: String
        let success: Bool
    }

    // MARK: - Tool Definitions

    private enum ToolDefinitions {

        // run_command — blocking, returns output
        // spawn_worker — non-blocking, starts in background, returns worker_id immediately

        static let openAI: [[String: Any]] = [
            [
                "type": "function",
                "function": [
                    "name": "run_command",
                    "description": "Execute a terminal command on the user's Mac and return its output. Use for quick commands that complete fast (ls, git status, find, etc.). For long-running tools like music players or downloads, use spawn_worker instead.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "command":           ["type": "string",  "description": "The exact shell command to run"],
                            "purpose":           ["type": "string",  "description": "One-line explanation of what this command does"],
                            "requires_approval": ["type": "boolean", "description": "True when the command modifies files, installs software, or has irreversible effects"]
                        ],
                        "required": ["command", "purpose"]
                    ]
                ]
            ],
            [
                "type": "function",
                "function": [
                    "name": "spawn_worker",
                    "description": "Start a long-running command in the background without waiting for it to finish. Use for music players (ymc, ncspot), downloaders, timers, and any process that should keep running while you do other things. Returns a worker_id you can reference later.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "command": ["type": "string", "description": "The shell command to start in background"],
                            "purpose": ["type": "string", "description": "What this background process is doing"]
                        ],
                        "required": ["command", "purpose"]
                    ]
                ]
            ],
            [
                "type": "function",
                "function": [
                    "name": "send_keys",
                    "description": "Inject keystrokes directly into the active TUI app running in the live terminal panel. Use this AFTER spawn_worker has launched a TUI app to navigate its menus, press buttons, or send input. Supports: plain text, \\r (Enter), \\u{1B} (Esc), \\u{03} (Ctrl-C), \\u{1B}[A/B/C/D (arrow keys).",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "keys":    ["type": "string", "description": "The keystroke sequence to inject. Use \\r for Enter, \\u{1B}[A for up-arrow, etc."],
                            "purpose": ["type": "string", "description": "What action this keystroke performs in the TUI"]
                        ],
                        "required": ["keys", "purpose"]
                    ]
                ]
            ]
        ]

        static let anthropic: [[String: Any]] = [
            [
                "name": "run_command",
                "description": "Execute a terminal command and return its output. For quick commands. For music players or long downloads, use spawn_worker.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "command":           ["type": "string",  "description": "The shell command to run"],
                        "purpose":           ["type": "string",  "description": "Why this command is being run"],
                        "requires_approval": ["type": "boolean", "description": "True for destructive or write operations"]
                    ],
                    "required": ["command", "purpose"]
                ]
            ],
            [
                "name": "spawn_worker",
                "description": "Start a long-running command in the background. Returns immediately with a worker_id. Use for music players, downloads, timers.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "command": ["type": "string", "description": "The command to run in background"],
                        "purpose": ["type": "string", "description": "What this process is doing"]
                    ],
                    "required": ["command", "purpose"]
                ]
            ],
            [
                "name": "send_keys",
                "description": "Inject keystrokes into the active TUI app in the live terminal panel. Use after spawn_worker to navigate menus, select options, or send input. Supports \\r (Enter), \\u{1B} (Esc), \\u{03} (Ctrl-C), arrow keys.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "keys":    ["type": "string", "description": "Keystroke sequence to inject into the TUI"],
                        "purpose": ["type": "string", "description": "What this keystroke does"]
                    ],
                    "required": ["keys", "purpose"]
                ]
            ]
        ]

        static let gemini: [String: Any] = [
            "function_declarations": [
                [
                    "name": "run_command",
                    "description": "Execute a terminal command and return its output.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "command": ["type": "string", "description": "The shell command to run"],
                            "purpose": ["type": "string", "description": "Why this command is being run"],
                            "requires_approval": ["type": "boolean"]
                        ],
                        "required": ["command", "purpose"]
                    ]
                ],
                [
                    "name": "spawn_worker",
                    "description": "Start a long-running background command. Returns a worker_id immediately.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "command": ["type": "string", "description": "Command to run in background"],
                            "purpose": ["type": "string", "description": "What the process does"]
                        ],
                        "required": ["command", "purpose"]
                    ]
                ],
                [
                    "name": "send_keys",
                    "description": "Inject keystrokes into the active TUI app in the live terminal. Use after spawn_worker.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "keys":    ["type": "string", "description": "Keystroke sequence to inject"],
                            "purpose": ["type": "string", "description": "What this keystroke does"]
                        ],
                        "required": ["keys", "purpose"]
                    ]
                ]
            ]
        ]
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
        commandExecutor: @escaping (String, String) async -> (Bool, String),
        maxIterations: Int = 5,
        systemPromptOverride: String? = nil
    ) async throws -> (finalResponse: String, executedCommands: [ExecutedCommand]) {

        let contextPrompt: String
        if let override = systemPromptOverride {
            contextPrompt = override
        } else {
            contextPrompt = await buildContextPrompt(for: context, originalQuery: message, forToolUse: true)
        }
        let extManager = L2ExtensionManager.shared

        switch provider {
        case .openAI:
            guard let key = apiKey, !key.isEmpty else {
                throw AIServiceError.missingAPIKey("OpenAI API key is required")
            }
            let customTools = extManager.toolSchemas(for: .openAI)
            return try await sendOpenAIWithTools(
                message: message, contextPrompt: contextPrompt, apiKey: key,
                history: conversationHistory, commandExecutor: commandExecutor,
                customTools: customTools,
                maxIterations: maxIterations, endpoint: "https://api.openai.com/v1/chat/completions",
                model: "gpt-4o-mini"
            )

        case .anthropic:
            guard let key = apiKey, !key.isEmpty else {
                throw AIServiceError.missingAPIKey("Anthropic API key is required")
            }
            let customTools = extManager.toolSchemas(for: .anthropic)
            return try await sendAnthropicWithTools(
                message: message, contextPrompt: contextPrompt, apiKey: key,
                history: conversationHistory, commandExecutor: commandExecutor,
                customTools: customTools,
                maxIterations: maxIterations
            )

        case .googleGemini:
            guard let key = apiKey, !key.isEmpty else {
                throw AIServiceError.missingAPIKey("Google Gemini API key is required")
            }
            let customTools = extManager.toolSchemas(for: .gemini)
            return try await sendGeminiWithTools(
                message: message, contextPrompt: contextPrompt, apiKey: key,
                history: conversationHistory, commandExecutor: commandExecutor,
                customTools: customTools,
                maxIterations: maxIterations
            )

        case .ollama:
            let settings = AppSettings.shared
            let model = settings.selectedOllamaModel.isEmpty ? "llama2" : settings.selectedOllamaModel
            let endpoint = settings.ollamaEndpoint.isEmpty ? "http://localhost:11434" : settings.ollamaEndpoint
            let customTools = extManager.toolSchemas(for: .openAI)
            // Use OpenAI-compatible endpoint (/v1/chat/completions) so response format matches OpenAIToolResponse
            return try await sendOpenAIWithTools(
                message: message, contextPrompt: contextPrompt, apiKey: nil,
                history: conversationHistory, commandExecutor: commandExecutor,
                customTools: customTools,
                maxIterations: maxIterations,
                endpoint: "\(endpoint)/v1/chat/completions",
                model: model,
                timeout: 120,
                extraHeaders: [:]
            )

        default:
            throw AIServiceError.unsupportedProvider("onDevice_fallback")
        }
    }

    /// Dispatch a custom L2 extension tool call. Returns (success, output).
    private func dispatchCustomTool(name: String, arguments: [String: Any]) async -> (Bool, String) {
        let (success, output) = await L2ExtensionManager.shared.execute(toolName: name, arguments: arguments)
        return (success, output)
    }

    // MARK: - OpenAI / Ollama Tool Loop

    private func sendOpenAIWithTools(
        message: String,
        contextPrompt: String,
        apiKey: String?,
        history: [ChatMessage],
        commandExecutor: @escaping (String, String) async -> (Bool, String),
        customTools: [[String: Any]] = [],
        maxIterations: Int,
        endpoint: String,
        model: String,
        timeout: TimeInterval = 60,
        extraHeaders: [String: String] = [:]
    ) async throws -> (finalResponse: String, executedCommands: [ExecutedCommand]) {

        guard let url = URL(string: endpoint) else {
            throw AIServiceError.networkError("Invalid endpoint: \(endpoint)")
        }
        var executedCommands: [ExecutedCommand] = []

        var messages: [[String: Any]] = [["role": "system", "content": contextPrompt]]
        for msg in history.suffix(10).filter({ $0.role != .system }) {
            messages.append(["role": msg.role.rawValue, "content": msg.content])
        }
        messages.append(["role": "user", "content": message])

        let allTools = ToolDefinitions.openAI + customTools

        for _ in 0..<maxIterations {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = timeout
            if let key = apiKey { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }

            var body: [String: Any] = [
                "model": model,
                "messages": messages,
                "tools": allTools,
                "tool_choice": "auto",
                "temperature": 0.7,
                "max_tokens": 1000
            ]
            if apiKey == nil { body["stream"] = false; body.removeValue(forKey: "max_tokens") }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await AIProviderService.directSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AIServiceError.networkError("Invalid response") }
            if http.statusCode == 401 { throw AIServiceError.authenticationFailed("Invalid API key") }
            if http.statusCode != 200 { throw AIServiceError.networkError("HTTP \(http.statusCode)") }

            let decoded = try JSONDecoder().decode(OpenAIToolResponse.self, from: data)
            guard let choice = decoded.choices.first else { throw AIServiceError.emptyResponse("No response") }

            if let toolCalls = choice.message.tool_calls, !toolCalls.isEmpty {
                var assistantMsg: [String: Any] = ["role": "assistant"]
                if let content = choice.message.content { assistantMsg["content"] = content }
                assistantMsg["tool_calls"] = toolCalls.map { tc -> [String: Any] in
                    ["id": tc.id, "type": tc.type, "function": ["name": tc.function.name, "arguments": tc.function.arguments]]
                }
                messages.append(assistantMsg)

                for tc in toolCalls {
                    guard let argsData = tc.function.arguments.data(using: .utf8),
                          let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                    else { continue }

                    var (success, output): (Bool, String) = (false, "")
                    if tc.function.name == "run_command",
                       let command = args["command"] as? String,
                       let purpose = args["purpose"] as? String {
                        (success, output) = await commandExecutor(command, purpose)
                        executedCommands.append(ExecutedCommand(command: "\(tc.function.name)(\(command))", output: output, success: success))
                    } else if tc.function.name == "spawn_worker",
                              let command = args["command"] as? String,
                              let purpose = args["purpose"] as? String {
                        let workerID = await TerminalAIBridge.shared.spawnWorker(command: command, purpose: purpose)
                        output = "{\"worker_id\": \"\(workerID)\", \"status\": \"running\", \"message\": \"'\(command)' started in background.\"}"
                        success = true
                        executedCommands.append(ExecutedCommand(command: "spawn_worker(\(command))", output: output, success: true))
                    } else if tc.function.name == "send_keys",
                              let keys = args["keys"] as? String {
                        let purpose = args["purpose"] as? String ?? ""
                        output = await TerminalAIBridge.shared.sendKeys(keys)
                        success = true
                        executedCommands.append(ExecutedCommand(command: "send_keys(\(keys))", output: output, success: true))
                        // Small delay after key injection so TUI can react before next tool call
                        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                        _ = purpose
                    } else {
                        // Custom L2 extension tool call
                        (success, output) = await dispatchCustomTool(name: tc.function.name, arguments: args)
                        executedCommands.append(ExecutedCommand(command: "\(tc.function.name)(\(args))", output: output, success: success))
                    }
                    messages.append(["role": "tool", "tool_call_id": tc.id,
                                     "content": output.isEmpty ? "(no output)" : output])
                }
            } else {
                return (choice.message.content ?? "(no response)", executedCommands)
            }
        }
        return ("Commands completed.", executedCommands)
    }

    // MARK: - Anthropic Tool Loop

    private func sendAnthropicWithTools(
        message: String,
        contextPrompt: String,
        apiKey: String,
        history: [ChatMessage],
        commandExecutor: @escaping (String, String) async -> (Bool, String),
        customTools: [[String: Any]] = [],
        maxIterations: Int
    ) async throws -> (finalResponse: String, executedCommands: [ExecutedCommand]) {

        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var executedCommands: [ExecutedCommand] = []

        var messages: [[String: Any]] = []
        for msg in history.suffix(10).filter({ $0.role != .system }) {
            messages.append(["role": msg.role.rawValue, "content": msg.content])
        }
        messages.append(["role": "user", "content": message])

        for _ in 0..<maxIterations {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

            let body: [String: Any] = [
                "model": "claude-3-5-haiku-20241022",
                "system": contextPrompt,
                "messages": messages,
                "tools": ToolDefinitions.anthropic + customTools,
                "max_tokens": 1024
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await AIProviderService.directSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AIServiceError.networkError("Invalid response") }
            if http.statusCode == 401 { throw AIServiceError.authenticationFailed("Invalid Anthropic API key") }
            if http.statusCode != 200 { throw AIServiceError.networkError("HTTP \(http.statusCode)") }

            let decoded = try JSONDecoder().decode(AnthropicToolResponse.self, from: data)
            let textBlocks   = decoded.content.filter { $0.type == "text" }
            let toolUseBlocks = decoded.content.filter { $0.type == "tool_use" }

            if toolUseBlocks.isEmpty {
                let text = textBlocks.compactMap { $0.text }.joined(separator: "\n")
                return (text.isEmpty ? "(no response)" : text, executedCommands)
            }

            // Echo full assistant content block array back
            let assistantBlocks: [[String: Any]] = decoded.content.map { block in
                var d: [String: Any] = ["type": block.type]
                if let t = block.text  { d["text"] = t }
                if let id = block.id   { d["id"] = id }
                if let n = block.name  { d["name"] = n }
                if let input = block.input { d["input"] = input.mapValues { $0.value } }
                return d
            }
            messages.append(["role": "assistant", "content": assistantBlocks])

            var resultBlocks: [[String: Any]] = []
            for block in toolUseBlocks {
                guard let toolId = block.id,
                      let toolName = block.name,
                      let inputDict = block.input
                else { continue }

                let args = inputDict.mapValues { $0.value }
                var (success, output): (Bool, String) = (false, "")

                if toolName == "run_command",
                   let command = args["command"] as? String,
                   let purpose = args["purpose"] as? String {
                    (success, output) = await commandExecutor(command, purpose)
                    executedCommands.append(ExecutedCommand(command: command, output: output, success: success))
                } else if toolName == "spawn_worker",
                          let command = args["command"] as? String,
                          let purpose = args["purpose"] as? String {
                    let workerID = await TerminalAIBridge.shared.spawnWorker(command: command, purpose: purpose)
                    output = "{\"worker_id\": \"\(workerID)\", \"status\": \"running\"}"
                    success = true
                    executedCommands.append(ExecutedCommand(command: "spawn_worker(\(command))", output: output, success: true))
                } else if toolName == "send_keys",
                          let keys = args["keys"] as? String {
                    output = await TerminalAIBridge.shared.sendKeys(keys)
                    success = true
                    executedCommands.append(ExecutedCommand(command: "send_keys(\(keys))", output: output, success: true))
                    try? await Task.sleep(nanoseconds: 300_000_000)
                } else {
                    (success, output) = await dispatchCustomTool(name: toolName, arguments: args)
                    executedCommands.append(ExecutedCommand(command: "\(toolName)(\(args))", output: output, success: success))
                }

                resultBlocks.append([
                    "type": "tool_result",
                    "tool_use_id": toolId,
                    "content": output.isEmpty ? "(no output)" : output
                ])
            }
            messages.append(["role": "user", "content": resultBlocks])
        }
        return ("Commands completed.", executedCommands)
    }

    // MARK: - Gemini Tool Loop

    private func sendGeminiWithTools(
        message: String,
        contextPrompt: String,
        apiKey: String,
        history: [ChatMessage],
        commandExecutor: @escaping (String, String) async -> (Bool, String),
        customTools: [[String: Any]] = [],
        maxIterations: Int
    ) async throws -> (finalResponse: String, executedCommands: [ExecutedCommand]) {

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent")!
        var executedCommands: [ExecutedCommand] = []

        var contents: [[String: Any]] = [
            ["role": "user",  "parts": [["text": contextPrompt]]],
            ["role": "model", "parts": [["text": "Understood. I'll help with the context provided."]]]
        ]
        for msg in history.suffix(10).filter({ $0.role != .system }) {
            let role = msg.role == .assistant ? "model" : "user"
            contents.append(["role": role, "parts": [["text": msg.content]]])
        }
        contents.append(["role": "user", "parts": [["text": message]]])

        for _ in 0..<maxIterations {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

            let body: [String: Any] = [
                "contents": contents,
                "tools": [ToolDefinitions.gemini] + customTools.map { ["function_declarations": [$0]] },
                "generationConfig": ["temperature": 0.7, "maxOutputTokens": 1000]
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await AIProviderService.directSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AIServiceError.networkError("Invalid response") }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw AIServiceError.authenticationFailed("Invalid Google Gemini API key")
            }
            if http.statusCode != 200 { throw AIServiceError.networkError("HTTP \(http.statusCode)") }

            let decoded = try JSONDecoder().decode(GeminiToolResponse.self, from: data)
            guard let candidate = decoded.candidates.first else { throw AIServiceError.emptyResponse("No response") }

            let textParts     = candidate.content.parts.filter { $0.text != nil }
            let functionParts = candidate.content.parts.filter { $0.functionCall != nil }

            if functionParts.isEmpty {
                let text = textParts.compactMap { $0.text }.joined(separator: "\n")
                return (text.isEmpty ? "(no response)" : text, executedCommands)
            }

            // Echo model turn
            let modelParts: [[String: Any]] = candidate.content.parts.map { part in
                if let fc = part.functionCall {
                    return ["functionCall": ["name": fc.name, "args": fc.args.mapValues { $0.value }]]
                }
                return ["text": part.text ?? ""]
            }
            contents.append(["role": "model", "parts": modelParts])

            var functionResultParts: [[String: Any]] = []
            for part in functionParts {
                guard let fc = part.functionCall else { continue }
                let args = fc.args.mapValues { $0.value }

                var (success, output): (Bool, String) = (false, "")
                if fc.name == "run_command",
                   let command = args["command"] as? String,
                   let purpose = args["purpose"] as? String {
                    (success, output) = await commandExecutor(command, purpose)
                    executedCommands.append(ExecutedCommand(command: command, output: output, success: success))
                } else if fc.name == "spawn_worker",
                          let command = args["command"] as? String,
                          let purpose = args["purpose"] as? String {
                    let workerID = await TerminalAIBridge.shared.spawnWorker(command: command, purpose: purpose)
                    output = "{\"worker_id\": \"\(workerID)\", \"status\": \"running\"}"
                    success = true
                    executedCommands.append(ExecutedCommand(command: "spawn_worker(\(command))", output: output, success: true))
                } else if fc.name == "send_keys",
                          let keys = args["keys"] as? String {
                    output = await TerminalAIBridge.shared.sendKeys(keys)
                    success = true
                    executedCommands.append(ExecutedCommand(command: "send_keys(\(keys))", output: output, success: true))
                    try? await Task.sleep(nanoseconds: 300_000_000)
                } else {
                    (success, output) = await dispatchCustomTool(name: fc.name, arguments: args)
                    executedCommands.append(ExecutedCommand(command: "\(fc.name)(\(args))", output: output, success: success))
                }

                functionResultParts.append([
                    "functionResponse": [
                        "name": fc.name,
                        "response": ["content": output.isEmpty ? "(no output)" : output]
                    ]
                ])
            }
            contents.append(["role": "function", "parts": functionResultParts])
        }
        return ("Commands completed.", executedCommands)
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
