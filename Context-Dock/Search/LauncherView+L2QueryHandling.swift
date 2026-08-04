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
    // MARK: - Intelligent L2 Query Handling

    // Compact prompt for on-device AI (4096 token limit)
    func buildCompactL2Prompt(query: String, context: UserContext, frontmostApp: String?)
        -> String
    {
        var prompt =
            "You are a macOS assistant. Answer the user's question based on the context provided.\n\n"
        prompt += currentDateTimeContextBlock() + "\n\n"
        let queryLower = query.lowercased()
        let isExtensionRequest =
            queryLower.contains("extension") || queryLower.contains("automation")
            || queryLower.contains("script")

        // Add only essential context based on what's selected
        switch context {
        case .filesSelected(let urls):
            let fileAnalysis = ContextDetector.shared.analyzeFiles(urls)
            prompt += "SELECTED FILES (\(fileAnalysis.count)):\n"
            for (index, file) in fileAnalysis.prefix(3).enumerated() {
                prompt += "\n\(index + 1). \(file.url.lastPathComponent)\n"
                prompt += "Type: \(file.type), Size: \(file.size)\n"

                if let content = file.content {
                    // For PDFs and text, limit to 1500 chars
                    let preview = String(content.prefix(1500))
                    prompt += "Content:\n```\n\(preview)\n```\n"
                    if content.count > 1500 {
                        prompt += "(truncated)\n"
                    }
                }
            }
            if fileAnalysis.count > 3 {
                prompt += "\n... and \(fileAnalysis.count - 3) more files\n"
            }
            if frontmostApp?.lowercased() == "finder",
                let currentDir = ContextDetector.shared.getCurrentFinderDirectory()
            {
                prompt += "\nCURRENT DIRECTORY:\n\(currentDir)\n"
            }

        case .textSelected(let text):
            let preview = String(text.prefix(2000))
            prompt += "SELECTED TEXT:\n```\n\(preview)\n```\n"
            if text.count > 2000 {
                prompt += "(truncated)\n"
            }

        case .appFocused(let appName, _):
            if appName.lowercased() == "finder" {
                if let currentDir = ContextDetector.shared.getCurrentFinderDirectory() {
                    prompt += "CURRENT DIRECTORY:\n\(currentDir)\n"
                }
                let selectedFiles = ContextDetector.shared.getFinderSelectedFiles()
                if !selectedFiles.isEmpty {
                    let fileAnalysis = ContextDetector.shared.analyzeFiles(selectedFiles)
                    prompt += "FINDER - SELECTED FILES (\(fileAnalysis.count)):\n"
                    for (index, file) in fileAnalysis.prefix(3).enumerated() {
                        prompt += "\n\(index + 1). \(file.url.lastPathComponent)\n"
                        prompt += "Type: \(file.type), Size: \(file.size)\n"

                        if let content = file.content {
                            let preview = String(content.prefix(1500))
                            prompt += "Content:\n```\n\(preview)\n```\n"
                            if content.count > 1500 {
                                prompt += "(truncated)\n"
                            }
                        }
                    }
                }
            } else {
                prompt += "User is in: \(appName)\n"
            }

        default:
            break
        }

        if frontmostApp?.lowercased().contains("safari") == true {
            if let safariContext = ContextDetector.shared.getSafariContext() {
                prompt += "\nCURRENT SAFARI TAB:\n"
                prompt += "Title: \(safariContext.title)\n"
                prompt += "URL: \(safariContext.url)\n"
            }

            if let pageText = fetchSafariPageText(), !pageText.isEmpty {
                let preview = pageText.prefix(1200)
                prompt += "\nPAGE CONTENT (excerpt):\n```\n\(preview)\n```\n"
                if pageText.count > 1200 {
                    prompt += "(truncated)\n"
                }
            }

            if queryLower.contains("link") || queryLower.contains("social")
                || queryLower.contains("url")
            {
                let links = fetchSafariPageLinks()
                if !links.isEmpty {
                    prompt += "\nPAGE LINKS:\n"
                    for link in links.prefix(30) {
                        prompt += "- \(link)\n"
                    }

                    if queryLower.contains("social") {
                        let socialDomains = [
                            "twitter.com", "x.com", "facebook.com", "instagram.com",
                            "linkedin.com", "youtube.com", "tiktok.com", "github.com", "reddit.com",
                        ]
                        let socialLinks = links.filter { link in
                            socialDomains.contains { link.lowercased().contains($0) }
                        }
                        if !socialLinks.isEmpty {
                            prompt += "\nSOCIAL LINKS:\n"
                            for link in socialLinks.prefix(20) {
                                prompt += "- \(link)\n"
                            }
                        }
                    }
                }
            }

            prompt += SafariDeepContextReader.shared.contextBlock(
                query: query,
                maxRecentHistory: 35,
                maxMatchedHistory: 25,
                maxBookmarks: 25,
                maxCharacters: 4_000
            )
        }

        if isExtensionRequest {
            prompt +=
                "\nUser explicitly requested an extension. You MUST respond with [SUGGEST_EXTENSION] and include working code.\n"
        }

        // Inject tools for every app mentioned in the query (cross-app task support)
        let crossAppSnippet = buildCrossAppToolsSnippet(query: query, frontmostApp: frontmostApp)
        if !crossAppSnippet.isEmpty {
            prompt += crossAppSnippet
        }

        // Proactively suggest missing tools based on query intent
        // e.g. user asks "compress this video" but has no video tool → suggest ffmpeg
        let missingTools = FileTypeToolRegistry.shared.suggestMissingTools(for: query, maxCount: 2)
        if !missingTools.isEmpty {
            let suggestions = missingTools.map {
                "  - \($0.toolName): \($0.description) (brew install \($0.toolName))"
            }.joined(separator: "\n")
            prompt += """

                TOOL SUGGESTION: No installed tool matches this request. Tell the user:
                \(suggestions)
                Provide the exact brew install command so they can tap the install button.

                """
        }

        prompt += "\nUser question: \(query)\n"
        return prompt
    }

    /// Detects which apps are mentioned in the query (beyond the frontmost app),
    /// pulls the user's installed CLI tools for each, and returns a prompt snippet
    /// so the AI can chain tools across apps without any hardcoded AppleScript.
    func buildCrossAppToolsSnippet(query: String, frontmostApp: String?) -> String {
        let q = query.lowercased()
        let frontmostKey =
            searchState.activeSmartQueryKey ?? settings.autoDetectedAppKey
            ?? frontmostApp.flatMap {
                settings.appKey(forBundleID: frontmost.bundleID, appName: $0)
            }

        // Build app mention map from two sources:
        // 1. Built-in well-known app keys with common aliases
        // 2. All user-registered custom apps and tool extensions (dynamic — no hardcoded limit)
        var appMentionMap: [(words: [String], key: String)] = [
            (["notes", "note"], "notes"),
            (["reminders", "reminder", "todo"], "reminders"),
            (["calendar", "event", "meeting"], "calendar"),
            (["mail", "email"], "mail"),
            (["messages", "imessage", "sms"], "messages"),
            (
                [
                    "safari", "browser", "webpage",
                    "page", "link", "url", "tab",
                ], "safari"
            ),
            (["finder", "files", "folder"], "finder"),
            (
                [
                    "spotify", "music", "song",
                    "playlist", "track",
                ], "spotify"
            ),
            (["xcode", "project", "build"], "xcode"),
            (["vscode", "code", "editor"], "vscode"),
        ]
        // Append every user-registered custom app (e.g. "obsidian", "notion", "slack")
        // Words = [key, label.lowercased()] so both "obsidian" and "Obsidian" match
        for entry in settings.customAppEntries {
            let key = entry.key.lowercased()
            guard !appMentionMap.contains(where: { $0.key == key }) else { continue }
            var words: [String] = [key]
            let labelLower = entry.label.lowercased()
            if labelLower != key { words.append(labelLower) }
            appMentionMap.append((words: words, key: key))
        }
        // Also add any appKey that has tool extensions but isn't a custom entry or built-in
        let knownKeys = Set(appMentionMap.map { $0.key })
        for ext in settings.appToolExtensions {
            let key = ext.appKey.lowercased()
            guard !knownKeys.contains(key) else { continue }
            appMentionMap.append((words: [key], key: key))
        }

        // Collect keys of all apps mentioned in the query (excluding frontmost — already injected)
        var mentionedKeys: [String] = []
        for entry in appMentionMap {
            guard entry.key != frontmostKey else { continue }
            if entry.words.contains(where: { q.contains($0) }) {
                mentionedKeys.append(entry.key)
            }
        }
        guard !mentionedKeys.isEmpty else { return "" }

        // For each mentioned app, pull its installed tools (scored against query)
        let pkgs = TerminalPackageManager.shared.packages
        var sections: [String] = []

        for key in mentionedKeys {
            let tools = settings.topExtensions(for: key, query: query, maxCount: 3)
            guard !tools.isEmpty else { continue }

            let appLabel =
                settings.customAppEntries.first(where: { $0.key == key })?.label
                ?? key.capitalized

            let toolLines = tools.map { ext -> String in
                let pkg = pkgs.first(where: { $0.command == ext.toolName })
                var line = "  - \(ext.toolName)"
                if let path = pkg?.installedPath ?? (ext.toolPath.isEmpty ? nil : ext.toolPath) {
                    line += " (\(path))"
                }
                let hint = ext.effectiveHint
                if !hint.isEmpty {
                    line += ": \(String(hint.prefix(200)))"
                } else if let ht = pkg?.helpText, !ht.isEmpty {
                    line += ": \(String(ht.prefix(200)))"
                }
                if !ext.profile.exampleCommands.isEmpty {
                    line +=
                        " | e.g. \(ext.profile.exampleCommands.prefix(2).joined(separator: " / "))"
                }
                return line
            }.joined(separator: "\n")

            sections.append("\(appLabel) tools:\n\(toolLines)")
        }

        guard !sections.isEmpty else { return "" }

        return """

            ADDITIONAL APP TOOLS FOR THIS TASK:
            \(sections.joined(separator: "\n\n"))

            RULES:
            - Use these tools (via run_command) to complete the cross-app task.
            - Chain run_command calls: first get data from the current app, then pass it to the target app's tool.
            - After completing, respond with a single clean confirmation line (e.g. "Saved." or "Done — note created in Notes.").
            - Do NOT use AppleScript unless no CLI tool is available for an app.

            """
    }

    /// On-screen text / files the user attached to the frontmost-app chat via its +
    /// menu (Capture Text, screenshots, uploads) — injected so the scoped model can
    /// act on what's visible (e.g. a captured Messages thread).
    func contextDockChatAttachmentPromptBlock() -> String {
        contextDockChatAttachmentPromptBlock(
            files: contextDockChatFiles,
            capturedText: contextDockChatCapturedText
        )
    }

    func contextDockChatAttachmentPromptBlock(files: [URL], capturedText: String?) -> String {
        var parts: [String] = []
        if let captured = capturedText?
            .trimmingCharacters(in: .whitespacesAndNewlines), !captured.isEmpty
        {
            parts.append(
                "CAPTURED ON-SCREEN TEXT (use this to answer the user):\n"
                    + String(captured.prefix(4000)))
        }
        if !files.isEmpty {
            let imageExts: Set<String> = [
                "png", "jpg", "jpeg", "gif", "bmp", "tiff", "heic", "webp",
            ]
            let submittedFiles = Array(files.prefix(10))
            let imageFiles = submittedFiles.filter { imageExts.contains($0.pathExtension.lowercased()) }
            let docFiles = submittedFiles.filter { !imageExts.contains($0.pathExtension.lowercased()) }

            // Screenshots / Capture Area are images — the scoped agentic path can't send vision,
            // so OCR them locally and inject the recognized text. This is what makes a captured
            // screen actually usable in the chat (e.g. "summarize this error").
            var blocks: [String] = []
            for url in imageFiles {
                let text = ocrTextFromImageFile(url)
                if text.isEmpty {
                    blocks.append("- \(url.lastPathComponent) (screenshot — no text recognized)")
                } else {
                    blocks.append(
                        "### \(url.lastPathComponent) (screenshot, recognized text)\n"
                            + String(text.prefix(3000)))
                }
            }
            if !docFiles.isEmpty {
                let analyzed = ContextDetector.shared.analyzeFiles(docFiles)
                for item in analyzed {
                    guard let content = item.content?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty
                    else {
                        blocks.append("- \(item.url.lastPathComponent) (\(item.type))")
                        continue
                    }
                    blocks.append(
                        "### \(item.url.lastPathComponent) (\(item.type))\n"
                            + String(content.prefix(3000)))
                }
            }
            if !blocks.isEmpty {
                parts.append("ATTACHED FILES (use these):\n\n" + blocks.joined(separator: "\n\n"))
            }
        }
        return parts.isEmpty ? "" : "\n\n" + parts.joined(separator: "\n\n")
    }

    /// Local Vision OCR for an image file the user attached/captured in the scoped chat.
    /// Synchronous (Vision `perform` is sync) — fine for a single user-initiated capture.
    func ocrTextFromImageFile(_ url: URL) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(url: url, options: [:]).perform([request])
            return (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""
        }
    }

    func buildIntelligentL2Prompt(
        query: String, context: UserContext, frontmostApp: String?
    ) -> String {
        // Check if using on-device AI (has 4096 token limit) - need MUCH shorter prompt
        let isOnDeviceAI = settings.selectedAIProvider == .onDevice
        let queryLower = query.lowercased()
        let isExtensionRequest =
            queryLower.contains("extension") || queryLower.contains("automation")
            || queryLower.contains("script")

        if isOnDeviceAI {
            // COMPACT PROMPT for on-device AI (4096 token limit)
            return buildCompactL2Prompt(query: query, context: context, frontmostApp: frontmostApp)
                + contextDockChatAttachmentPromptBlock()
        }

        // FULL PROMPT for cloud AI providers (larger context windows)
        // Get current date and time
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .medium
        let currentDateTime = dateFormatter.string(from: now)

        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: now)
        let weekdayName = dateFormatter.weekdaySymbols[weekday - 1]

        var prompt = """
            You are an intelligent assistant integrated into macOS. You have access to system information and can help users with file operations, app context, and more.

            CURRENT DATE & TIME:
            📅 \(currentDateTime) (\(weekdayName))

            IMPORTANT: Use this current date/time to:
            - Filter calendar events correctly (today, tomorrow, this week, this month)
            - Understand relative time queries ("today", "tomorrow", "next Monday")
            - Provide accurate time-based responses

            """

        // Add system capabilities
        prompt += """

            CAPABILITIES:
            - Access to user's file system (read directories, find files, get file info)
            - Context awareness (knows which app is active and what's selected)
            - Can execute shell commands for file operations
            - Can use installed extensions/tools
            - macOS system knowledge
            - Can directly analyze and explain files (images, documents, code, etc.)
            - Access to REAL Calendar events, Reminders, Contacts (ALWAYS available regardless of frontmost app)
            - Full Safari control: search, navigate, bookmark, manage tabs
            - AI-powered intelligent understanding of user intent

            INSTALLED TERMINAL TOOLS:
            \(TerminalToolDiscovery.installedToolsSummary())

            SAFARI CONTROL & ANALYSIS:
            - Search/open URL: [EXECUTE_COMMAND: open -a Safari "https://youtube.com"]
            - Google search: [EXECUTE_COMMAND: open -a Safari "https://google.com/search?q=your+query"]
            - Access ALL open tabs and their URLs (provided in context when in Safari)
            - Analyze tab content by titles and URLs
            - Answer questions about tabs ("which tabs are about X?", "how many tabs?")
            - Summarize research across multiple tabs
            - Can execute AppleScript for Safari operations (bookmarks, navigation, tab management)

            IMPORTANT RULES:
            - For simple file questions, answer directly without extensions
            - For Calendar/Reminders/Contacts questions, use the ACTUAL data provided below
            - For Safari PDF save, use File > Export as PDF from the menu bar
            - For Safari search/navigate, use [EXECUTE_COMMAND] with appropriate URLs
            - For Safari tab analysis, use the tab data provided in context to answer intelligently
            - Only suggest extensions for complex automation that can't be done with existing APIs
            - When suggesting extensions, provide COMPLETE, WORKING code ready to save and use
            - You are INTELLIGENT - understand user intent and provide the most helpful response

            EXTENSION SUGGESTION CRITERIA:
            - Task requires automation not available via existing APIs
            - Task would be reused frequently (not one-time)
            - Task involves file format conversion, image processing, or complex workflows
            - For PDF save in Safari: Tell user to use File > Export as PDF
            - For tab management/analysis: Answer directly with provided data, DON'T suggest extension
            - For recurring workflows: SUGGEST extension with complete code

            """

        if isExtensionRequest {
            prompt += """

                USER EXPLICITLY REQUESTED AN EXTENSION.
                You MUST respond with [SUGGEST_EXTENSION] and include complete, working code.

                """
        }

        // Add available extensions catalog
        let availableExtensions = getAvailableExtensionsForContext(
            frontmostApp: frontmostApp, context: context)

        if !availableExtensions.isEmpty {
            prompt += """

                AVAILABLE EXTENSIONS/TOOLS:
                You have access to these pre-built extensions that can help complete tasks:

                """

            for (index, ext) in availableExtensions.prefix(10).enumerated() {
                let keywordsList =
                    ext.keywords.isEmpty ? "N/A" : ext.keywords.prefix(5).joined(separator: ", ")
                prompt += """
                    \(index + 1). \(ext.name)
                       - Description: \(ext.description)
                       - Keywords: \(keywordsList)
                       - Can do: \(ext.capabilities)
                       - Category: \(ext.category)

                    """
            }

            if availableExtensions.count > 10 {
                prompt += "... and \(availableExtensions.count - 10) more extensions available\n"
            }

            prompt += """

                HOW TO USE EXTENSIONS:
                - If the user's request matches an extension, respond with:
                  [USE_EXTENSION: extension_name]
                - Example: If user asks "compress these files" and you have an "Archive Tool" extension, respond with:
                  "I'll compress your files using the Archive Tool.
                  [USE_EXTENSION: Archive Tool]"
                - You can explain what you're doing AND trigger the extension in the same response

                """
        } else {
            // No extensions available, suggest creating one if applicable
            prompt += """

                NOTE: No extensions are currently available for this context.
                You can still help the user by:
                1. Answering their question directly
                2. Suggesting they create an extension if this is a recurring task

                """
        }

        // Add selected text context FIRST (most important for user queries)
        if case .textSelected(let text) = context, !text.isEmpty {
            let preview = text.prefix(2000)  // Show more text for better context
            prompt += """

                📝 SELECTED TEXT (User has this text selected/visible):
                ```
                \(preview)
                ```
                """
            if text.count > 2000 {
                prompt += "\n... (truncated, total \(text.count) characters)\n"
            }
            prompt += "\n"
        }

        // UNIVERSAL APP CONTEXT - AI automatically understands any app
        if let appName = frontmostApp, !appName.isEmpty {
            // Get comprehensive context for current app
            // IMPORTANT: Use the app from the context, NOT the current frontmost app (which is ILauncher)
            var targetApp: NSRunningApplication?

            // Extract bundle ID from context
            switch context {
            case .appFocused(_, let bundleID):
                // Find the running app by bundle ID
                targetApp = NSWorkspace.shared.runningApplications.first {
                    $0.bundleIdentifier == bundleID
                }
            default:
                // Fallback: try to find by name
                targetApp = NSWorkspace.shared.runningApplications.first {
                    $0.localizedName == appName
                }
            }

            // If we found the target app, get its context
            if let app = targetApp {
                let comprehensiveContext = ContextDetector.shared.getComprehensiveContext(
                    frontmostApp: app)

                prompt += """

                    ========================================
                    FRONTMOST APP: \(appName)
                    ========================================

                    You are helping the user with \(appName).
                    ALL user queries are in the context of \(appName) unless explicitly stated otherwise.

                    AUTOMATICALLY AVAILABLE CONTEXT:
                    """

                // Add all detected context
                for ctx in comprehensiveContext {
                    switch ctx {
                    case .browserTabs(let tabs):
                        prompt += "\n\n🌐 ALL BROWSER TABS (\(tabs.count) tabs):\n"
                        var currentWindow = 0
                        for (index, tab) in tabs.prefix(50).enumerated() {
                            if tab.windowIndex != currentWindow {
                                currentWindow = tab.windowIndex
                                prompt += "\n--- Window \(currentWindow) ---\n"
                            }
                            prompt += "\(tab.tabIndex). \(tab.title)\n   \(tab.url)\n"
                        }
                        if tabs.count > 50 {
                            prompt += "... and \(tabs.count - 50) more tabs\n"
                        }

                    case .clipboard(let content):
                        let preview = content.prefix(500)
                        prompt += "\n\n📋 CLIPBOARD:\n\(preview)"
                        if content.count > 500 {
                            prompt += "...\n(total: \(content.count) chars)"
                        }

                    case .music(let title, let artist, let album):
                        prompt += "\n\n🎵 CURRENTLY PLAYING:\n"
                        prompt += "Song: \(title)\n"
                        prompt += "Artist: \(artist)\n"
                        prompt += "Album: \(album)\n"

                    case .podcast(let title, let show):
                        prompt += "\n\n🎙️ CURRENTLY PLAYING PODCAST:\n"
                        prompt += "Episode: \(title)\n"
                        prompt += "Show: \(show)\n"

                    case .files(let urls):
                        prompt += "\n\n📁 SELECTED FILES (\(urls.count)):\n"
                        for url in urls.prefix(20) {
                            prompt += "- \(url.lastPathComponent)\n"
                        }

                    case .text(let text):
                        let preview = text.prefix(1000)
                        prompt += "\n\n📝 SELECTED TEXT:\n\(preview)"
                        if text.count > 1000 {
                            prompt += "...\n"
                        }

                    case .browserTab(let url, let title):
                        prompt += "\n\n🌐 CURRENT TAB:\n"
                        prompt += "Title: \(title)\n"
                        prompt += "URL: \(url)\n"

                        // Actual page content: Safari via its bridge, any other browser
                        // (DuckDuckGo/Chrome/Arc) by converting the tab URL with MarkItDown.
                        let tabPageText: String? = {
                            if appName.lowercased() == "safari" { return fetchSafariPageText() }
                            guard let u = URL(string: url), MarkItDownService.supports(u) else {
                                return nil
                            }
                            return MarkItDownService.convert(u)?.markdown
                        }()
                        if let pageText = tabPageText, !pageText.isEmpty {
                            let preview = pageText.prefix(3000)
                            prompt += "\n📄 PAGE CONTENT:\n```\n\(preview)\n```\n"
                            if pageText.count > 3000 {
                                prompt += "... (total: \(pageText.count) characters)\n"
                            }
                            prompt +=
                                "\n✅ Use this ACTUAL page content to answer questions about what's on the page!\n"
                        }

                    case .note(let content):
                        let preview = content.prefix(1000)
                        prompt += "\n\n📝 CURRENT NOTE:\n\(preview)"
                        if content.count > 1000 {
                            prompt += "...\n"
                        }

                    case .email(let subject, let from, let content):
                        prompt += "\n\n📧 SELECTED EMAIL:\n"
                        prompt += "Subject: \(subject)\n"
                        prompt += "From: \(from)\n"

                        if !content.isEmpty {
                            let preview = content.prefix(2000)
                            prompt += "\nEmail Content:\n```\n\(preview)\n```\n"
                            if content.count > 2000 {
                                prompt += "... (total: \(content.count) characters)\n"
                            }
                            prompt += "\n✅ Use this ACTUAL email content to answer questions!\n"
                        }

                    case .app:
                        break  // Already shown above
                    }
                }
            }

            prompt += "\n\n"

            // Add app-specific capabilities
            switch appName.lowercased() {
            case "finder":
                prompt += """
                    - User is in Finder (file manager)
                    - User has full access to their file system
                    - Can perform: find files, check sizes, list directories, organize files
                    - Downloads folder: ~/Downloads
                    - Desktop folder: ~/Desktop
                    - Documents folder: ~/Documents

                    """

                // Get current Finder directory (ALWAYS include this for context)
                if let currentDir = ContextDetector.shared.getCurrentFinderDirectory() {
                    prompt += "\n📂 CURRENT DIRECTORY:\n"
                    prompt += "Path: \(currentDir)\n"
                    prompt += "Folder: \(URL(fileURLWithPath: currentDir).lastPathComponent)\n"
                }

                // Get selected files/folders and analyze them
                let selectedFiles = ContextDetector.shared.getFinderSelectedFiles()
                if !selectedFiles.isEmpty {
                    let fileAnalysis = ContextDetector.shared.analyzeFiles(selectedFiles)

                    prompt += "\n"
                    prompt += "========================================\n"
                    prompt += "📁 SELECTED FILES (\(fileAnalysis.count))\n"
                    prompt += "========================================\n"

                    for (index, file) in fileAnalysis.enumerated() {
                        let fileName = file.url.lastPathComponent
                        prompt += "\n\(index + 1). \(fileName)\n"
                        prompt += "   Type: \(file.type)\n"
                        prompt += "   Size: \(file.size)\n"
                        prompt += "   Path: \(file.url.path)\n"

                        // If it's a text/code file with content, include it
                        if let content = file.content {
                            prompt += "\n   📄 FILE CONTENT:\n"
                            prompt += "   ```\n"
                            let lines = content.components(separatedBy: "\n").prefix(50)
                            prompt += lines.joined(separator: "\n")
                            prompt += "\n   ```\n"

                            // Special note for PDFs
                            if file.type == "pdf" {
                                prompt +=
                                    "\n   ✅ THIS IS THE ACTUAL PDF CONTENT ABOVE - Use it to answer user questions!\n"
                            }
                        } else {
                            // No content extracted
                            if file.type == "pdf" {
                                prompt +=
                                    "\n   ⚠️ Could not extract text from this PDF (might be image-based/scanned)\n"
                            }
                        }

                        // Special handling for images
                        if file.isImage {
                            prompt += "\n   📷 This is an image file - you can analyze it visually\n"
                        }
                    }

                    prompt += "\n========================================\n"
                } else {
                    prompt += "\n(No files selected)\n"
                }

                // ALWAYS include instructions for file operations
                prompt += """

                    IMPORTANT INSTRUCTIONS FOR FILE OPERATIONS:

                    CONTEXT AVAILABLE:
                    - Current directory path (where the user is in Finder)
                    - Selected files/folders with full paths, types, sizes, and content (if any)
                    - For PDFs: Text content has been automatically extracted from the PDF
                    - For text/code files: Full content is provided
                    - You can reference these paths in your responses and extension scripts

                    1. ANALYSIS QUERIES: For questions like "what is this file?", "explain this code", "summarize this PDF", "what is this PDF about?" → Analyze and answer directly using the provided content
                    2. ACTION QUERIES: For tasks like "move to Downloads", "copy to folder X", "send via iMessage", "add to Notes" → Suggest creating an extension
                    3. DIRECTORY QUERIES: User can ask about current directory, list files, find files, organize files, etc.

                    IMPORTANT: When user asks "what is this PDF about?" or similar questions about PDFs, you MUST use the PDF text content provided above to answer. DO NOT say you cannot read PDFs - the content is already extracted and provided!
                    IMPORTANT: Do NOT suggest an extension if you can answer directly from this content.

                    WHEN TO SUGGEST EXTENSIONS:
                    - ONLY when the task cannot be completed directly with the provided context
                    - Examples: batch processing, file format conversion, multi-step automation

                    HOW TO SUGGEST EXTENSIONS:
                    Use this format:
                    [SUGGEST_EXTENSION]
                    {
                        "name": "Task Name",
                        "description": "What it does",
                        "app": "Finder",
                        "code": "#!/bin/bash\\n# Your working script here\\n# You have access to: SELECTED_FILES (if any) and CURRENT_DIR"
                    }
                    [/SUGGEST_EXTENSION]

                    The extension will be automatically:
                    - Added to the Extensions directory
                    - Grouped under "Finder" app
                    - Immediately executed to complete the user's request

                    """

            case "safari":
                prompt += """
                    - User is browsing in Safari
                    - You can answer questions about the current page and user intent
                    - You can reference the current URL/title below

                    """

                if let safariContext = ContextDetector.shared.getSafariContext() {
                    prompt += "\n🌐 CURRENT TAB:\n"
                    prompt += "Title: \(safariContext.title)\n"
                    prompt += "URL: \(safariContext.url)\n"
                }

                if let pageText = fetchSafariPageText(), !pageText.isEmpty {
                    let preview = pageText.prefix(2000)
                    prompt += "\n📄 PAGE CONTENT (excerpt):\n"
                    prompt += "```\n\(preview)\n```\n"
                    if pageText.count > 2000 {
                        prompt += "... (truncated, total \(pageText.count) characters)\n"
                    }
                }

                if queryLower.contains("link") || queryLower.contains("social")
                    || queryLower.contains("url")
                {
                    let links = fetchSafariPageLinks()
                    if !links.isEmpty {
                        prompt += "\n🔗 PAGE LINKS:\n"
                        for link in links.prefix(50) {
                            prompt += "- \(link)\n"
                        }

                        if queryLower.contains("social") {
                            let socialDomains = [
                                "twitter.com", "x.com", "facebook.com", "instagram.com",
                                "linkedin.com", "youtube.com", "tiktok.com", "github.com",
                                "reddit.com",
                            ]
                            let socialLinks = links.filter { link in
                                socialDomains.contains { link.lowercased().contains($0) }
                            }
                            if !socialLinks.isEmpty {
                                prompt += "\n🔗 SOCIAL LINKS:\n"
                                for link in socialLinks.prefix(30) {
                                    prompt += "- \(link)\n"
                                }
                            }
                        }
                    }
                }

            case "calendar":
                prompt += """
                    - User is in Calendar app
                    - Can help with: event analysis, scheduling, finding free time

                    """

                // Detect if query is simple (viewing) or complex (needs extension)
                let isSimpleCalendarQuery =
                    queryLower.contains("show") || queryLower.contains("list")
                    || queryLower.contains("what") || queryLower.contains("today")
                    || queryLower.contains("this week") || queryLower.contains("this month")

                let isComplexCalendarQuery =
                    queryLower.contains("create") || queryLower.contains("add event")
                    || queryLower.contains("schedule") || queryLower.contains("export")
                    || queryLower.contains("sync") || queryLower.contains("free time")
                    || queryLower.contains("available")

                if isComplexCalendarQuery {
                    prompt += """

                        USER QUERY REQUIRES COMPLEX CALENDAR OPERATIONS.
                        Suggest creating a custom extension for this task.

                        Examples needing extensions:
                        - Creating/modifying events
                        - Finding free time slots
                        - Exporting calendar data
                        - Syncing calendars
                        - Complex filtering by date ranges

                        Use [SUGGEST_EXTENSION] tag with working code.

                        """
                } else if isSimpleCalendarQuery {
                    // Fetch REAL calendar events for viewing
                    let calendarEvents = AppleAppsAPI.shared.getCalendarEvents(limit: 50)
                    if !calendarEvents.isEmpty {
                        prompt += "\n📅 ACTUAL CALENDAR EVENTS (Current Month):\n"

                        let dateFormatter = DateFormatter()
                        dateFormatter.dateFormat = "MMM d, yyyy h:mm a"

                        for event in calendarEvents {
                            if let title = event["title"] as? String,
                                let startDateStr = event["startDate"] as? String,
                                let startDate = ISO8601DateFormatter().date(from: startDateStr)
                            {
                                let formattedDate = dateFormatter.string(from: startDate)
                                let isAllDay = event["isAllDay"] as? Bool ?? false
                                let location = event["location"] as? String ?? ""

                                prompt += "- \(title)"
                                prompt += " on \(formattedDate)"
                                if isAllDay { prompt += " (All Day)" }
                                if !location.isEmpty { prompt += " at \(location)" }
                                prompt += "\n"
                            }
                        }
                        prompt +=
                            "\nIMPORTANT: Use this ACTUAL calendar data to answer questions. Don't make up generic holidays.\n"
                    } else {
                        prompt += "\nNo upcoming calendar events found.\n"
                    }
                }

            case "notes":
                prompt += """
                    - User is in Notes app
                    - Can help with: note content, summarization, organization

                    """

            case "mail":
                prompt += """
                    - User is in Mail app
                    - Can help with: email analysis, drafting replies, organizing
                    - Menu pills are for Mail commands; attached Mail context is for mailbox questions

                    """

                if isCurrentMailContextAttached() {
                    if let block = buildAttachedMailContextBlock(for: query) {
                        prompt += block
                    }
                } else {
                    prompt += """

                        MAILBOX DATA: Not attached.
                        If the user wants mailbox questions answered from real Mail data, tell them to press the + button in the dock while Mail is frontmost.

                        """
                }

            case "safari", "chrome", "arc":
                prompt += """
                    - User is in \(appName) browser
                    - FULL BROWSER CONTROL available

                    """

                // Detect user intent for Safari operations
                let queryLower = query.lowercased()

                // Check if user wants to search/navigate
                let isSearchQuery =
                    queryLower.contains("search") || queryLower.contains("youtube")
                    || queryLower.contains("google") || queryLower.contains("open")
                    || queryLower.contains("go to") || queryLower.contains("navigate")

                let isBookmarkQuery = queryLower.contains("bookmark")

                // Detect PDF save requests (should use API, not extension)
                let isPDFSaveQuery =
                    (queryLower.contains("save") || queryLower.contains("export"))
                    && (queryLower.contains("pdf") || queryLower.contains("page"))

                // Detect tab queries (should answer with data, not extension)
                let isTabQuery =
                    queryLower.contains("tab")
                    && (queryLower.contains("list") || queryLower.contains("show")
                        || queryLower.contains("how many") || queryLower.contains("which")
                        || queryLower.contains("what") || queryLower.contains("find")
                        || queryLower.contains("about") || queryLower.contains("opened")
                        || queryLower.contains("open") || queryLower.contains("count"))

                let isComplexBrowserQuery =
                    !isPDFSaveQuery && !isTabQuery
                    && (queryLower.contains("save") || queryLower.contains("export")
                        || queryLower.contains("close") || queryLower.contains("organize")
                        || queryLower.contains("group") || queryLower.contains("screenshot"))

                if isTabQuery {
                    prompt += """

                        TAB QUERY DETECTED:
                        The user is asking about Safari tabs. ALL tab data is provided below.
                        Analyze the tabs and answer intelligently:
                        - Count tabs if asked "how many tabs"
                        - List specific tabs if asked "show tabs about X"
                        - Summarize research if asked about topics across tabs
                        - Find tabs matching criteria

                        DO NOT suggest creating an extension - ANSWER WITH THE DATA PROVIDED!

                        """
                } else if isSearchQuery {
                    prompt += """

                        SAFARI SEARCH/NAVIGATION COMMANDS:
                        - To open YouTube: [EXECUTE_COMMAND: open -a Safari "https://youtube.com"]
                        - To search on Google: [EXECUTE_COMMAND: open -a Safari "https://google.com/search?q=SEARCH_TERM"]
                        - To search YouTube: [EXECUTE_COMMAND: open -a Safari "https://youtube.com/results?search_query=SEARCH_TERM"]
                        - To open any URL: [EXECUTE_COMMAND: open -a Safari "https://example.com"]

                        IMPORTANT: Understand user intent intelligently:
                        - "youtube" → open YouTube homepage
                        - "search for cats on youtube" → open YouTube search for cats
                        - "google python tutorial" → Google search for python tutorial
                        - Replace spaces in search terms with + symbols

                        """
                } else if isBookmarkQuery {
                    prompt += """

                        BOOKMARK OPERATIONS:
                        Create an extension using AppleScript to add current tab to bookmarks:
                        tell application "Safari"
                            add current tab of front window to bookmarks
                        end tell

                        Use [SUGGEST_EXTENSION] tag with complete code.

                        """
                } else if isComplexBrowserQuery {
                    prompt += """

                        COMPLEX BROWSER OPERATIONS - Suggest Extension:
                        - Save/export tabs to files
                        - Close tabs matching criteria
                        - Take screenshots of pages
                        - Organize tabs into groups

                        Use [SUGGEST_EXTENSION] tag with working AppleScript code.

                        """
                } else {
                    // For viewing tabs or general browser queries, provide actual URLs from ALL windows
                    if let frontmostApp = NSWorkspace.shared.frontmostApplication {
                        let comprehensiveContext = ContextDetector.shared.getComprehensiveContext(
                            frontmostApp: frontmostApp)

                        // Look for browserTabs or clipboard in comprehensive context
                        for ctx in comprehensiveContext {
                            if case .browserTabs(let tabs) = ctx {
                                prompt += "\n🌐 ALL BROWSER TABS (All Windows):\n"
                                prompt += "Total: \(tabs.count) tabs across multiple windows\n\n"

                                var currentWindow = 0
                                for tab in tabs.prefix(50) {  // Limit to 50 tabs to avoid huge prompts
                                    if tab.windowIndex != currentWindow {
                                        currentWindow = tab.windowIndex
                                        prompt += "\n--- Window \(currentWindow) ---\n"
                                    }
                                    prompt += "\(tab.tabIndex). \(tab.title)\n   URL: \(tab.url)\n"
                                }

                                if tabs.count > 50 {
                                    prompt += "\n... and \(tabs.count - 50) more tabs\n"
                                }

                                prompt += "\nYou can:\n"
                                prompt += "- List specific tabs\n"
                                prompt += "- Search for tabs by title or URL\n"
                                prompt += "- Answer questions about tab content\n"
                                prompt += "- Summarize research across tabs\n"
                                break
                            }
                        }

                        // Also include clipboard if available
                        for ctx in comprehensiveContext {
                            if case .clipboard(let content) = ctx {
                                prompt += "\n\n📋 CLIPBOARD CONTENT:\n"
                                let preview = content.prefix(500)
                                prompt += "\(preview)\n"
                                if content.count > 500 {
                                    prompt +=
                                        "... (clipboard has \(content.count) total characters)\n"
                                }
                                prompt +=
                                    "\nYou can reference clipboard content in your response.\n"
                                break
                            }
                        }
                    }
                }

            default:
                prompt += "- User is currently in: \(appName)\n"
            }
        }

        // ALWAYS include clipboard if available (for ALL apps, not just browsers)
        if let frontmostApp = NSWorkspace.shared.frontmostApplication {
            if let clipboard = ContextDetector.shared.getClipboardContent() {
                prompt += "\n📋 CLIPBOARD CONTENT (Always Available):\n"
                let preview = clipboard.prefix(1000)
                prompt += "\(preview)\n"
                if clipboard.count > 1000 {
                    prompt += "... (clipboard has \(clipboard.count) total characters)\n"
                }
                prompt += "\nYou can reference or use clipboard content in your response.\n"
            }

            // Include currently playing music/podcast if available
            if let musicInfo = ContextDetector.shared.getMusicInfo() {
                prompt += "\n🎵 CURRENTLY PLAYING:\n"
                prompt += "Track: \(musicInfo.title)\n"
                prompt += "Artist: \(musicInfo.artist)\n"
                prompt += "Album: \(musicInfo.album)\n"
                prompt +=
                    "\nYou can reference this music in your response or help with music-related queries.\n"
            } else if let podcastInfo = ContextDetector.shared.getPodcastInfo() {
                prompt += "\n🎙️ CURRENTLY PLAYING PODCAST:\n"
                prompt += "Episode: \(podcastInfo.title)\n"
                prompt += "Show: \(podcastInfo.show)\n"
                prompt += "\nYou can reference this podcast in your response.\n"
            }
        }

        // ALWAYS provide system data (Calendar, Reminders, Contacts) - AI can use when relevant
        prompt += "\n=== SYSTEM DATA (Always Available) ===\n"

        // Calendar Events - always fetch
        let calendarEvents = AppleAppsAPI.shared.getCalendarEvents(limit: 30)
        if !calendarEvents.isEmpty {
            prompt += "\n📅 CALENDAR EVENTS (Next 30 days from NOW):\n"
            let eventDateFormatter = DateFormatter()
            eventDateFormatter.dateFormat = "MMM d, yyyy h:mm a"

            let relativeDateFormatter = RelativeDateTimeFormatter()
            relativeDateFormatter.unitsStyle = .full

            for event in calendarEvents.prefix(15) {
                if let title = event["title"] as? String,
                    let startDateStr = event["startDate"] as? String,
                    let startDate = ISO8601DateFormatter().date(from: startDateStr)
                {
                    let formattedDate = eventDateFormatter.string(from: startDate)
                    let isAllDay = event["isAllDay"] as? Bool ?? false

                    // Calculate relative time
                    let timeInterval = startDate.timeIntervalSince(now)
                    let relativeTime = relativeDateFormatter.localizedString(
                        for: startDate, relativeTo: now)

                    prompt += "- \(title)\n"
                    prompt += "  Date: \(formattedDate)"
                    if isAllDay { prompt += " (All Day)" }
                    prompt += "\n  Time from now: \(relativeTime)\n"
                }
            }
        } else {
            prompt += "\n📅 CALENDAR: No upcoming events\n"
        }

        // Reminders - always fetch
        let reminders = AppleAppsAPI.shared.getReminders(limit: 15)
        if !reminders.isEmpty {
            prompt += "\n📝 REMINDERS:\n"
            let reminderDateFormatter = DateFormatter()
            reminderDateFormatter.dateStyle = .medium
            reminderDateFormatter.timeStyle = .short

            let relativeDateFormatter = RelativeDateTimeFormatter()
            relativeDateFormatter.unitsStyle = .full

            for reminder in reminders.prefix(10) {
                if let title = reminder["title"] as? String {
                    prompt += "- \(title)"
                    if let dueDateStr = reminder["dueDate"] as? String,
                        let dueDate = ISO8601DateFormatter().date(from: dueDateStr)
                    {
                        let formattedDate = reminderDateFormatter.string(from: dueDate)
                        let relativeTime = relativeDateFormatter.localizedString(
                            for: dueDate, relativeTo: now)

                        // Check if overdue
                        let isOverdue = dueDate < now
                        if isOverdue {
                            prompt += " ⚠️ OVERDUE"
                        }
                        prompt += "\n  Due: \(formattedDate) (\(relativeTime))"
                    }
                    prompt += "\n"
                }
            }
        } else {
            prompt += "\n📝 REMINDERS: No active reminders\n"
        }

        // Contacts - provide count, AI can ask for specific searches
        prompt += "\n👥 CONTACTS: Available (you can search by name if user asks)\n"

        prompt +=
            "\nIMPORTANT: This system data is ALWAYS available. Use it intelligently when relevant to user's query.\n"
        prompt += "========================================\n"

        // Add selected files context
        if case .filesSelected(let urls) = context, !urls.isEmpty {
            prompt += "\nSELECTED FILES:\n"
            for url in urls.prefix(10) {
                prompt += "- \(url.lastPathComponent) (\(url.pathExtension))\n"
            }
            if urls.count > 10 {
                prompt += "... and \(urls.count - 10) more files\n"
            }

            let fileAnalysis = ContextDetector.shared.analyzeFiles(urls)
            if !fileAnalysis.isEmpty {
                prompt += "\nSELECTED FILE DETAILS:\n"
                for (index, file) in fileAnalysis.prefix(3).enumerated() {
                    prompt += "\n\(index + 1). \(file.url.lastPathComponent)\n"
                    prompt += "Type: \(file.type)\n"
                    prompt += "Size: \(file.size)\n"
                    if let content = file.content, !content.isEmpty {
                        let preview = content.prefix(3000)
                        prompt += "Content:\n```\n\(preview)\n```\n"
                        if content.count > 3000 {
                            prompt += "... (truncated)\n"
                        }
                        if file.type == "pdf" {
                            prompt += "✅ PDF text extracted above. Use it to summarize.\n"
                        }
                    } else if file.type == "pdf" {
                        prompt += "⚠️ PDF text could not be extracted (image-based PDF).\n"
                    }
                }
            }
        }

        prompt += """

            USER REQUEST:
            \(query)

            ========================================
            INTELLIGENCE RULES - READ CAREFULLY
            ========================================

            YOU ARE CONTEXT-AWARE:
            - The user is in \(frontmostApp ?? "an app")
            - ALL their questions relate to this app unless explicitly stated
            - ALL context provided above is AUTOMATICALLY AVAILABLE to you
            - You DON'T need to ask for context - it's already provided

            AUTOMATIC UNDERSTANDING:
            - SELECTED TEXT (ANY APP): If user has text selected → Use SELECTED TEXT provided above
            - Safari/Browser: Questions about page content → Use PAGE CONTENT provided above
            - Safari/Browser: Questions about tabs → Use tab data provided above
            - Finder: Questions about files → Use the file/directory data provided
            - Mail: Questions about emails → Use email context if provided
            - Calendar: Questions about events → Use calendar data provided
            - ANY APP: Answer based on automatically detected context

            FOR SELECTED TEXT QUESTIONS (HIGHEST PRIORITY):
            - If SELECTED TEXT is provided, user's questions are about THAT TEXT
            - "summarize this" → Summarize the SELECTED TEXT
            - "explain this" → Explain the SELECTED TEXT
            - "translate this" → Translate the SELECTED TEXT
            - "what does this mean" → Explain the SELECTED TEXT meaning
            - The SELECTED TEXT section is shown at the TOP - it's the most important context!
            - Works in Safari, TextEdit, Notes, Mail, or ANY app where text is selected

            FOR MAIL APP QUESTIONS:
            - "summarize this email" → Summarize the EMAIL CONTENT provided
            - "what is this about" → Explain based on EMAIL CONTENT
            - "reply to this" → Draft reply based on EMAIL CONTENT
            - "who sent this" → Use the From field provided
            - The EMAIL CONTENT section contains the ACTUAL email text
            - DON'T say "I can't see the email" - the content is RIGHT THERE!

            FOR SAFARI PAGE CONTENT QUESTIONS:
            - "explain about X on this page" → Read and analyze the PAGE CONTENT provided
            - "what apps are shown" → Look in PAGE CONTENT for app names
            - "summarize this page" → Summarize the PAGE CONTENT provided
            - The PAGE CONTENT section contains the ACTUAL text from the webpage
            - DON'T say "I can't see the page" - the content is RIGHT THERE in the context!

            FOR TAB QUESTIONS IN SAFARI:
            - Answer using the tab data already provided above
            - Count tabs, filter tabs, summarize tabs
            - DON'T suggest creating extension
            - JUST ANSWER with the data!

            FOR FILE QUESTIONS IN FINDER:
            - Answer using the file/directory data provided above
            - List files, find files, analyze files
            - DON'T suggest extension for simple queries
            - JUST ANSWER with the data!

            RESPONSE GUIDELINES:
            1. If you can answer with the provided context → Answer directly (no extension)
            2. If an extension is required to complete the task → Use it with [USE_EXTENSION: name]
            3. If the task cannot be completed by AI or existing APIs → Suggest a custom extension

            WHEN TO SUGGEST EXTENSIONS:
            - ONLY when the task cannot be completed with the provided context or built-in APIs
            - Examples: batch automation, file transformations, app automation not already supported

            HOW TO SUGGEST EXTENSIONS:
            - Add [SUGGEST_EXTENSION] tag in your response
            - Provide complete, working extension code
            - Use this format:

            ```bash
            #!/bin/bash
            # Extension: [Name]
            # Description: [What it does]
            # Trigger: keyword
            # Layer: l2_context

            [Your working code here]
            ```

            - Make code simple, well-commented, and copy-paste ready
            - Include example usage
            - Explain where to save the file

            IMPORTANT:
            - For file operations: Provide ACTUAL RESULTS (run commands if needed)
            - For simple questions (like "what is X?"): Give direct, comprehensive answers
            - Do NOT suggest extensions when you can answer directly
            - Only include code blocks when using [SUGGEST_EXTENSION]
            - Always be actionable and helpful
            """

        // For Finder queries, actually execute and add results to prompt
        if let appName = frontmostApp, appName.lowercased() == "finder" {
            if let fileResults = executeFinderQuery(query) {
                prompt += """

                    ACTUAL FILE SYSTEM RESULTS:
                    \(fileResults)

                    Now provide a helpful summary of these results to the user.
                    """
            }
        }

        // Inject user-configured app-specific tool extensions into L2 prompt
        let l2AppKey =
            searchState.activeSmartQueryKey ?? settings.autoDetectedAppKey
            ?? frontmostApp.flatMap {
                settings.appKey(forBundleID: frontmost.bundleID, appName: $0)
            }
        if let key = l2AppKey {
            let relevantTools = settings.topExtensions(for: key, query: query, maxCount: 4)
            if !relevantTools.isEmpty {
                let pkgs = TerminalPackageManager.shared.packages
                let toolSnippet = relevantTools.map { ext -> String in
                    let pkg = pkgs.first(where: { $0.command == ext.toolName })
                    var line = "- \(ext.toolName)"
                    if let path = pkg?.installedPath ?? (ext.toolPath.isEmpty ? nil : ext.toolPath)
                    {
                        line += " (\(path))"
                    }
                    let hint = ext.effectiveHint
                    if !hint.isEmpty {
                        line += ": " + String(hint.prefix(300))
                    } else if let ht = pkg?.helpText, !ht.isEmpty {
                        line += ": " + String(ht.prefix(300))
                    }
                    return line
                }.joined(separator: "\n")
                prompt += """

                    APP CONTEXT [\(key)] — USER-CONFIGURED TOOLS:
                    \(toolSnippet)
                    Use these tools via run_command when they match the user's request.
                    """
            }
        }

        // ── Cross-app shortcut catalog ──────────────────────────────────────────
        // Inject ALL user-defined scriptable shortcuts across ALL app panels so the
        // AI can chain tools from different apps (e.g. Safari URL → Notes → Mail).
        let crossAppSection = buildCrossAppShortcutsSection()
        if !crossAppSection.isEmpty {
            prompt += crossAppSection
        }

        prompt += contextDockChatAttachmentPromptBlock()
        return prompt
    }

    /// Builds a cross-app tool catalog from all user-defined scriptable shortcuts.
    /// Writes multi-line JXA/AppleScript scripts to /tmp/ilauncher_tools/ so the AI
    /// can call them via run_command. Single-line scripts are inlined.
    func buildCrossAppShortcutsSection() -> String {
        // Gather all scriptable shortcuts grouped by appKey
        let scriptable = settings.appShortcuts.filter {
            $0.actionType == .jxa || $0.actionType == .appleScript || $0.actionType == .shellCommand
        }
        guard !scriptable.isEmpty else { return "" }

        // Create temp tools directory
        let toolsDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "ilauncher_tools")
        try? FileManager.default.createDirectory(at: toolsDir, withIntermediateDirectories: true)

        // Group by appKey
        var byApp: [String: [AppShortcut]] = [:]
        for sc in scriptable {
            byApp[sc.appKey, default: []].append(sc)
        }

        var section = "\n=== CROSS-APP TOOLS (User-Defined) ===\n"
        section += "You can chain these tools across apps to complete multi-step tasks.\n"
        section += "Use run_command to execute them. See instructions per tool below.\n\n"

        for (appKey, shortcuts) in byApp.sorted(by: { $0.key < $1.key }) {
            let appDisplay = appKey.capitalized
            section += "── \(appDisplay) ──\n"

            for sc in shortcuts {
                let safeName = sc.name.lowercased()
                    .replacingOccurrences(of: " ", with: "_")
                    .filter { $0.isLetter || $0.isNumber || $0 == "_" }
                let toolID = "\(appKey)_\(safeName)"

                switch sc.actionType {
                case .jxa:
                    let code = sc.actionValue
                    let isMultiLine = code.contains("\n") || code.count > 120
                    if isMultiLine {
                        let filePath = toolsDir.appendingPathComponent("\(toolID).js").path
                        try? code.write(toFile: filePath, atomically: true, encoding: .utf8)
                        section +=
                            "  • \(sc.name) → run_command: osascript -l JavaScript \"\(filePath)\"\n"
                    } else {
                        let escaped = code.replacingOccurrences(of: "\"", with: "\\\"")
                        section +=
                            "  • \(sc.name) → run_command: osascript -l JavaScript -e \"\(escaped)\"\n"
                    }

                case .appleScript:
                    let code = sc.actionValue
                    let isMultiLine = code.contains("\n") || code.count > 120
                    if isMultiLine {
                        let filePath = toolsDir.appendingPathComponent("\(toolID).scpt").path
                        try? code.write(toFile: filePath, atomically: true, encoding: .utf8)
                        section += "  • \(sc.name) → run_command: osascript \"\(filePath)\"\n"
                    } else {
                        let escaped = code.replacingOccurrences(of: "\"", with: "\\\"")
                        section += "  • \(sc.name) → run_command: osascript -e \"\(escaped)\"\n"
                    }

                case .shellCommand:
                    // Pass $CURRENT_FILE and $SELECTED_TEXT as env vars if needed
                    let cmd = sc.actionValue
                    section += "  • \(sc.name) → run_command: \(cmd)\n"

                default:
                    break
                }
            }
            section += "\n"
        }

        section += """
            CROSS-APP CHAINING RULES:
            - To do multi-step tasks (e.g. "save Safari URL to Notes"), chain run_command calls:
              1. First run_command to get data from app A (e.g. Safari URL via osascript)
              2. Use the output in the next run_command to write to app B (e.g. Notes)
            - Variables: capture stdout from step N, pass as arg to step N+1
            - For AppleScript output: wrap with 'result=$(osascript -e ...)' then use $result
            ===================================\n
            """

        return section
    }

    func executeFinderQuery(_ query: String) -> String? {
        let lowerQuery = query.lowercased()

        // Detect what user wants to find
        let targetPath: String
        if lowerQuery.contains("downloads") {
            targetPath = NSHomeDirectory() + "/Downloads"
        } else if lowerQuery.contains("desktop") {
            targetPath = NSHomeDirectory() + "/Desktop"
        } else if lowerQuery.contains("documents") {
            targetPath = NSHomeDirectory() + "/Documents"
        } else {
            return nil
        }

        // Detect file size criteria
        let sizeCriteria: String
        if lowerQuery.contains("large") || lowerQuery.contains("big") {
            sizeCriteria = "+10M"  // Files larger than 10MB
        } else if lowerQuery.contains("huge") || lowerQuery.contains("largest") {
            sizeCriteria = "+100M"  // Files larger than 100MB
        } else {
            return nil
        }

        // Execute find command
        let findCommand =
            "find \"\(targetPath)\" -type f -size \(sizeCriteria) -exec ls -lh {} \\; 2>/dev/null | head -20"
        #if DEBUG
        print("🔍 [L2] Executing: \(findCommand)")
        #endif

        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", findCommand]

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                // Parse ls output to extract file names and sizes
                let lines = output.components(separatedBy: "\n")
                    .filter { !$0.isEmpty }
                    .prefix(20)

                var results = "Found \(lines.count) large files in \(targetPath):\n\n"
                for line in lines {
                    // Parse ls -lh output: extract size and filename
                    let components = line.components(separatedBy: .whitespaces).filter {
                        !$0.isEmpty
                    }
                    if components.count >= 9 {
                        let size = components[4]
                        let filename = components[8...].joined(separator: " ")
                        results += "• \(filename) (\(size))\n"
                    }
                }
                return results
            }
        } catch {
            #if DEBUG
            print("❌ [L2] Failed to execute find command: \(error)")
            #endif
        }

        return nil
    }

}
