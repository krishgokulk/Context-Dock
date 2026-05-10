//
//  IntelligentExtensionMatcher.swift
//  ILauncher
//
//  AI-powered intelligent extension matching based on context
//  Suggests relevant extensions based on selected files, text, and frontmost app
//  Now prioritizes default apps over terminal commands
//

import Foundation
import AppKit

/// Intelligent matcher that suggests extensions based on context
class IntelligentExtensionMatcher {
    static let shared = IntelligentExtensionMatcher()

    // Reference to DefaultAppResolver for app-based suggestions
    private let appResolver = DefaultAppResolver.shared

    private init() {}

    // MARK: - Context Analysis

    /// Analyze context and suggest relevant extensions
    func suggestExtensions(for context: DetectedContext) -> [SuggestedExtension] {
        var suggestions: [SuggestedExtension] = []

        print("🔍 [Matcher] ==========================================")
        print("🔍 [Matcher] Suggesting extensions for context: \(context.description)")

        switch context {
        case .files(let urls):
            print("🔍 [Matcher] Context type: FILES (\(urls.count) files)")
            suggestions = suggestForFiles(urls)

        case .text(let text):
            print("🔍 [Matcher] Context type: TEXT (\(text.prefix(50))...)")
            suggestions = suggestForText(text)

        case .app(let bundleId, let appName):
            print("🔍 [Matcher] Context type: APP (\(appName))")
            suggestions = suggestForApp(appName: appName, bundleId: bundleId)

        case .browserTab(let url, let title):
            print("🔍 [Matcher] Context type: BROWSER (\(title))")
            suggestions = suggestForBrowser(url: url, title: title)

        case .browserTabs(let tabs):
            print("🔍 [Matcher] Context type: BROWSER TABS (\(tabs.count) tabs)")
            // Use first tab for suggestions, or suggest tab management extensions
            if let firstTab = tabs.first {
                suggestions = suggestForBrowser(url: firstTab.url, title: firstTab.title)
            }

        case .clipboard(let content):
            print("🔍 [Matcher] Context type: CLIPBOARD (\(content.prefix(50))...)")
            suggestions = suggestForText(content)

        case .music(let title, let artist, _):
            print("🔍 [Matcher] Context type: MUSIC (\(title) by \(artist))")
            suggestions = suggestForText("\(title) \(artist)")

        case .podcast(let title, let show):
            print("🔍 [Matcher] Context type: PODCAST (\(title))")
            suggestions = suggestForText("\(title) \(show)")

        case .note(let noteContent):
            print("🔍 [Matcher] Context type: NOTE")
            suggestions = suggestForText(noteContent)

        case .email(let subject, let from, _):
            print("🔍 [Matcher] Context type: EMAIL (from: \(from))")
            suggestions = suggestForEmail(subject: subject, from: from)
        }

        // Sort by relevance score
        suggestions.sort { $0.relevanceScore > $1.relevanceScore }
        
        print("🔍 [Matcher] Total suggestions: \(suggestions.count)")
        print("🔍 [Matcher] ==========================================")
        
        return suggestions
    }

    // MARK: - File-Based Suggestions

    private func suggestForFiles(_ urls: [URL]) -> [SuggestedExtension] {
        var suggestions: [SuggestedExtension] = []

        guard !urls.isEmpty else { return [] }

        // Analyze file types
        let fileTypes = analyzeFileTypes(urls)

        print("📁 [Matcher] File analysis: \(urls.count) files")
        print("   Images: \(fileTypes.images.count), PDFs: \(fileTypes.pdfs.count), Docs: \(fileTypes.documents.count)")

        // PRIORITY 1: Get default app suggestions first
        let appSuggestions = appResolver.getAppSuggestions(for: urls)
        for appSuggestion in appSuggestions {
            let scriptExt = createAppBasedExtension(from: appSuggestion, for: urls)
            suggestions.append(SuggestedExtension(
                scriptExtension: scriptExt,
                relevanceScore: appSuggestion.score,
                reason: appSuggestion.description
            ))
            print("  📱 App: \(appSuggestion.action): score \(appSuggestion.score)")
        }

        // PRIORITY 2: Only add terminal suggestions if no apps found OR for specialized operations
        let hasAppSuggestions = !appSuggestions.isEmpty
        let fileExt = urls.first?.pathExtension.lowercased() ?? ""
        let terminalSuggestions = appResolver.getTerminalSuggestions(for: fileExt, fileURLs: urls)

        for terminalSuggestion in terminalSuggestions {
            // Lower score if app suggestions exist
            let baseScore = hasAppSuggestions ? 50.0 : 85.0
            let isInstalled = L2AITaskExecutor.TerminalTool.isInstalled(terminalSuggestion.requiresTool)
            let finalScore = isInstalled ? baseScore : baseScore - 20.0

            let scriptExt = createTerminalBasedExtension(from: terminalSuggestion, for: urls)
            suggestions.append(SuggestedExtension(
                scriptExtension: scriptExt,
                relevanceScore: finalScore,
                reason: terminalSuggestion.isBuiltIn ? "Built-in command" : (isInstalled ? "Terminal tool installed" : "Requires: \(terminalSuggestion.requiresTool)")
            ))
            print("  💻 Terminal: \(terminalSuggestion.command): score \(finalScore)")
        }

        // Get all available extensions from ExtensionManager
        let allExtensions = ExtensionManager.shared.getEnabledExtensions()

        // Match extensions to file types
        for scriptExt in allExtensions {
            var score: Double = 0.0
            
            // Built-in file extensions get high default scores
            if scriptExt.isBuiltIn && scriptExt.category == .ai {
                switch scriptExt.name.lowercased() {
                case "file-info":
                    score = 95.0
                case "copy-path":
                    score = 90.0
                case "reveal-in-finder", "reveal":
                    score = 85.0
                case "get-info":
                    score = urls.count == 1 ? 80.0 : 0.0  // Only for single files
                default:
                    break
                }
            }
            
            // Match file-based extensions
            if let fileScore = matchExtensionToFiles(scriptExt, fileTypes: fileTypes, urls: urls) {
                score = max(score, fileScore)
            }
            
            if score > 0 {
                let reason = generateReason(for: scriptExt, context: .files(fileTypes))
                print("  ✅ \(scriptExt.displayName): score \(score) - \(reason)")
                suggestions.append(SuggestedExtension(
                    scriptExtension: scriptExt,
                    relevanceScore: score,
                    reason: reason
                ))
            }
        }

        print("📁 [Matcher] File suggestions: \(suggestions.count) found")
        return suggestions
    }

    private func analyzeFileTypes(_ urls: [URL]) -> FileTypeAnalysis {
        var analysis = FileTypeAnalysis()

        for url in urls {
            let ext = url.pathExtension.lowercased()

            // Categorize file types
            if ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tiff"].contains(ext) {
                analysis.images.append(url)
            } else if ["pdf"].contains(ext) {
                analysis.pdfs.append(url)
            } else if ["doc", "docx", "txt", "rtf", "pages"].contains(ext) {
                analysis.documents.append(url)
            } else if ["mp4", "mov", "avi", "mkv", "m4v"].contains(ext) {
                analysis.videos.append(url)
            } else if ["mp3", "m4a", "wav", "aac", "flac"].contains(ext) {
                analysis.audio.append(url)
            } else if ["zip", "rar", "7z", "tar", "gz"].contains(ext) {
                analysis.archives.append(url)
            } else if ["swift", "py", "js", "java", "cpp", "c", "h", "m", "html", "css"].contains(ext) {
                analysis.code.append(url)
            } else {
                analysis.other.append(url)
            }
        }

        return analysis
    }

    private func matchExtensionToFiles(_ scriptExt: ScriptExtension, fileTypes: FileTypeAnalysis, urls: [URL]) -> Double? {
        let name = scriptExt.name.lowercased()
        let displayName = scriptExt.displayName.lowercased()

        var score: Double = 0.0

        // Image files
        if !fileTypes.images.isEmpty {
            if name.contains("image") || name.contains("photo") || name.contains("picture") {
                score += 100.0
            }
            if name.contains("compress") || name.contains("resize") || name.contains("convert") {
                score += 80.0
            }
            if name.contains("crop") || name.contains("filter") || name.contains("enhance") {
                score += 70.0
            }
        }

        // PDF files
        if !fileTypes.pdfs.isEmpty {
            if name.contains("pdf") {
                score += 100.0
            }
            if name.contains("merge") || name.contains("split") || name.contains("compress") {
                score += 80.0
            }
            if name.contains("extract") || name.contains("text") {
                score += 70.0
            }
        }

        // Documents
        if !fileTypes.documents.isEmpty {
            if name.contains("doc") || name.contains("text") || name.contains("word") {
                score += 80.0
            }
            if name.contains("convert") || name.contains("format") {
                score += 70.0
            }
        }

        // Videos
        if !fileTypes.videos.isEmpty {
            if name.contains("video") || name.contains("movie") {
                score += 100.0
            }
            if name.contains("compress") || name.contains("convert") || name.contains("gif") {
                score += 80.0
            }
            if name.contains("trim") || name.contains("cut") || name.contains("edit") {
                score += 70.0
            }
        }

        // Audio
        if !fileTypes.audio.isEmpty {
            if name.contains("audio") || name.contains("music") || name.contains("sound") {
                score += 100.0
            }
            if name.contains("convert") || name.contains("compress") {
                score += 80.0
            }
        }

        // Archives
        if !fileTypes.archives.isEmpty {
            if name.contains("zip") || name.contains("unzip") || name.contains("extract") {
                score += 100.0
            }
            if name.contains("compress") || name.contains("archive") {
                score += 80.0
            }
        }

        // Code files
        if !fileTypes.code.isEmpty {
            if name.contains("code") || name.contains("format") || name.contains("lint") {
                score += 80.0
            }
            if name.contains("beautify") || name.contains("minify") {
                score += 70.0
            }
        }

        // Multiple files bonus
        if urls.count > 1 {
            if name.contains("merge") || name.contains("combine") || name.contains("batch") {
                score += 50.0
            }
        }

        return score > 0 ? score : nil
    }

    // MARK: - Text-Based Suggestions

    private func suggestForText(_ text: String) -> [SuggestedExtension] {
        var suggestions: [SuggestedExtension] = []

        let allExtensions = ExtensionManager.shared.getEnabledExtensions()

        // Analyze text
        let wordCount = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        let charCount = text.count
        let hasURL = text.contains("http://") || text.contains("https://")
        let hasEmail = text.contains("@") && text.contains(".")
        let isCode = detectCode(in: text)
        let isLongText = wordCount > 50

        print("📝 [Matcher] Text analysis: \(wordCount) words, \(charCount) chars, longText: \(isLongText)")

        for scriptExt in allExtensions {
            let name = scriptExt.name.lowercased()
            let displayName = scriptExt.displayName.lowercased()
            var score: Double = 0.0

            // Built-in text extensions get high default scores
            if scriptExt.isBuiltIn && scriptExt.category == .ai {
                switch name {
                case "copy":
                    score = 95.0
                case "count-words", "count":
                    score = 90.0
                case "uppercase":
                    score = 85.0
                case "lowercase":
                    score = 84.0
                case "summarize":
                    score = isLongText ? 92.0 : 60.0
                default:
                    break
                }
            }

            // Text processing
            if name.contains("text") || name.contains("word") || displayName.contains("text") {
                score = max(score, 80.0)
            }

            // Word count
            if name.contains("count") || displayName.contains("count") {
                score = max(score, 90.0)
            }

            // Case conversion
            if name.contains("upper") || name.contains("lower") || name.contains("case") {
                score = max(score, 85.0)
            }

            // Translation
            if (name.contains("translate") || displayName.contains("translate")) && wordCount > 3 {
                score = max(score, 90.0)
            }

            // Summarization for long text
            if (name.contains("summar") || name.contains("tldr") || displayName.contains("summar")) && isLongText {
                score = max(score, 92.0)
            }

            // URL extraction
            if (name.contains("url") || displayName.contains("url")) && hasURL {
                score = max(score, 100.0)
            }

            // Email detection
            if (name.contains("email") || displayName.contains("email")) && hasEmail {
                score = max(score, 100.0)
            }

            // Code formatting
            if (name.contains("format") || name.contains("beautify") || displayName.contains("format")) && isCode {
                score = max(score, 90.0)
            }

            if score > 0 {
                let reason = generateReason(for: scriptExt, context: .text(text))
                print("  ✅ \(scriptExt.displayName): score \(score) - \(reason)")
                suggestions.append(SuggestedExtension(
                    scriptExtension: scriptExt,
                    relevanceScore: score,
                    reason: reason
                ))
            }
        }

        print("📝 [Matcher] Text suggestions: \(suggestions.count) found")
        return suggestions
    }

    // MARK: - App-Based Suggestions

    private func suggestForApp(appName: String, bundleId: String) -> [SuggestedExtension] {
        var suggestions: [SuggestedExtension] = []

        let allExtensions = ExtensionManager.shared.getEnabledExtensions()

        print("📱 [Matcher] App context: \(appName) (\(bundleId))")

        // Special case: if app is "Unknown", show generic clipboard-based suggestions
        if appName == "Unknown" || bundleId.isEmpty {
            print("📱 [Matcher] Unknown app context - showing clipboard-based suggestions")
            
            // Check clipboard
            if let clipboardText = NSPasteboard.general.string(forType: .string), !clipboardText.isEmpty {
                print("📱 [Matcher] Found clipboard text, treating as text context")
                return suggestForText(clipboardText)
            }
            
            // No clipboard, show generic utilities
            for scriptExt in allExtensions {
                if scriptExt.isBuiltIn && scriptExt.category == .ai {
                    let name = scriptExt.name.lowercased()
                    var score: Double = 0.0
                    
                    switch name {
                    case "paste-from-clipboard", "pasteFromClipboard":
                        score = 70.0
                    case "copy":
                        score = 60.0
                    default:
                        break
                    }
                    
                    if score > 0 {
                        suggestions.append(SuggestedExtension(
                            scriptExtension: scriptExt,
                            relevanceScore: score,
                            reason: "General utility"
                        ))
                    }
                }
            }
            
            print("📱 [Matcher] Unknown app: \(suggestions.count) suggestions")
            return suggestions
        }

        for scriptExt in allExtensions {
            let name = scriptExt.name.lowercased()
            var score: Double = 0.0

            // Built-in app extensions
            if scriptExt.isBuiltIn && scriptExt.category == .ai {
                if name == "app-info" {
                    score = 85.0
                }
            }

            // Finder
            if bundleId == "com.apple.finder" {
                if name.contains("file") || name.contains("folder") {
                    score = max(score, 80.0)
                }
            }

            // Safari/Chrome/Arc
            if bundleId.contains("safari") || bundleId.contains("chrome") || bundleId.contains("browser") {
                if name.contains("url") || name.contains("bookmark") || name.contains("download") {
                    score = max(score, 80.0)
                }
            }

            // Mail
            if bundleId.contains("mail") {
                if name.contains("email") || name.contains("message") {
                    score = max(score, 80.0)
                }
            }

            // Notes
            if bundleId.contains("notes") {
                if name.contains("note") || name.contains("text") {
                    score = max(score, 80.0)
                }
            }

            // Music
            if bundleId.contains("music") || bundleId.contains("spotify") {
                if name.contains("music") || name.contains("playlist") {
                    score = max(score, 80.0)
                }
            }

            // Code editors (Xcode, VS Code, etc.)
            if bundleId.contains("xcode") || bundleId.contains("vscode") || bundleId.contains("sublime") {
                if name.contains("code") || name.contains("format") || name.contains("lint") {
                    score = max(score, 80.0)
                }
            }

            if score > 0 {
                suggestions.append(SuggestedExtension(
                    scriptExtension: scriptExt,
                    relevanceScore: score,
                    reason: "Works with \(appName)"
                ))
            }
        }

        print("📱 [Matcher] App suggestions: \(suggestions.count) found")
        return suggestions
    }

    // MARK: - Email-Based Suggestions

    private func suggestForEmail(subject: String, from: String) -> [SuggestedExtension] {
        var suggestions: [SuggestedExtension] = []

        let allExtensions = ExtensionManager.shared.getEnabledExtensions()

        for scriptExt in allExtensions {
            let name = scriptExt.name.lowercased()
            var score: Double = 0.0

            // Email processing
            if name.contains("email") || name.contains("mail") {
                score += 90.0
            }

            // Reply/Forward
            if name.contains("reply") || name.contains("forward") {
                score += 80.0
            }

            // Archive/Delete
            if name.contains("archive") || name.contains("delete") {
                score += 70.0
            }

            // Save attachment
            if name.contains("attachment") || name.contains("save") {
                score += 70.0
            }

            if score > 0 {
                suggestions.append(SuggestedExtension(
                    scriptExtension: scriptExt,
                    relevanceScore: score,
                    reason: "Works with email: \(subject)"
                ))
            }
        }

        return suggestions
    }

    // MARK: - Browser-Based Suggestions

    private func suggestForBrowser(url: String, title: String) -> [SuggestedExtension] {
        var suggestions: [SuggestedExtension] = []

        let allExtensions = ExtensionManager.shared.getEnabledExtensions()

        for scriptExt in allExtensions {
            let name = scriptExt.name.lowercased()
            var score: Double = 0.0

            // Download-related
            if name.contains("download") {
                score += 90.0
            }

            // Bookmark/Save
            if name.contains("bookmark") || name.contains("save") {
                score += 80.0
            }

            // Screenshot/Capture
            if name.contains("screenshot") || name.contains("capture") {
                score += 70.0
            }

            // Share
            if name.contains("share") {
                score += 60.0
            }

            if score > 0 {
                suggestions.append(SuggestedExtension(
                    scriptExtension: scriptExt,
                    relevanceScore: score,
                    reason: "Works with web content"
                ))
            }
        }

        return suggestions
    }

    // MARK: - General Suggestions

    private func suggestGeneral() -> [SuggestedExtension] {
        // Return most commonly used or featured extensions
        let allExtensions = ExtensionManager.shared.getEnabledExtensions()

        return allExtensions.prefix(5).map { scriptExt in
            SuggestedExtension(
                scriptExtension: scriptExt,
                relevanceScore: 50.0,
                reason: "Popular extension"
            )
        }
    }

    // MARK: - Helper Methods

    private func detectCode(in text: String) -> Bool {
        // Simple code detection
        let codePatterns = [
            "func ", "function ", "def ", "class ", "import ", "const ",
            "let ", "var ", "{", "}", "=>", "//", "/*", "*/"
        ]

        return codePatterns.contains { text.contains($0) }
    }

    private func generateReason(for scriptExt: ScriptExtension, context: ReasonContext) -> String {
        switch context {
        case .files(let analysis):
            if !analysis.images.isEmpty {
                return "Works with \(analysis.images.count) image\(analysis.images.count > 1 ? "s" : "")"
            }
            if !analysis.pdfs.isEmpty {
                return "Works with \(analysis.pdfs.count) PDF\(analysis.pdfs.count > 1 ? "s" : "")"
            }
            if !analysis.videos.isEmpty {
                return "Works with \(analysis.videos.count) video\(analysis.videos.count > 1 ? "s" : "")"
            }
            return "Works with selected files"

        case .text(let text):
            let wordCount = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
            return "Works with \(wordCount) word\(wordCount > 1 ? "s" : "")"

        case .app(let name):
            return "Works with \(name)"
        }
    }
}

// MARK: - Data Models

struct SuggestedExtension: Identifiable {
    let id = UUID()
    let scriptExtension: ScriptExtension
    let relevanceScore: Double
    let reason: String

    var displayRelevance: String {
        if relevanceScore >= 90 {
            return "⭐⭐⭐ Highly Recommended"
        } else if relevanceScore >= 70 {
            return "⭐⭐ Recommended"
        } else {
            return "⭐ Suggested"
        }
    }
}

struct FileTypeAnalysis {
    var images: [URL] = []
    var pdfs: [URL] = []
    var documents: [URL] = []
    var videos: [URL] = []
    var audio: [URL] = []
    var archives: [URL] = []
    var code: [URL] = []
    var other: [URL] = []

    var totalCount: Int {
        images.count + pdfs.count + documents.count + videos.count +
        audio.count + archives.count + code.count + other.count
    }

    var primaryType: String {
        let counts = [
            ("Images", images.count),
            ("PDFs", pdfs.count),
            ("Documents", documents.count),
            ("Videos", videos.count),
            ("Audio", audio.count),
            ("Archives", archives.count),
            ("Code", code.count)
        ]

        return counts.max(by: { $0.1 < $1.1 })?.0 ?? "Files"
    }
}

enum ReasonContext {
    case files(FileTypeAnalysis)
    case text(String)
    case app(String)
}

// MARK: - App-Based and Terminal Extension Creators

extension IntelligentExtensionMatcher {

    /// Create a ScriptExtension from an app suggestion
    func createAppBasedExtension(from suggestion: DefaultAppResolver.AppSuggestion, for urls: [URL]) -> ScriptExtension {
        let name = suggestion.action.lowercased().replacingOccurrences(of: " ", with: "-")

        return ScriptExtension(
            name: name,
            displayName: suggestion.action,
            category: .ai,
            type: .shell,
            scriptPath: nil,
            isBuiltIn: false,
            builtInAction: nil,
            description: suggestion.description,
            terminalCommand: nil,
            requiresTool: nil,
            targetApp: suggestion.app
        )
    }

    /// Create a ScriptExtension from a terminal suggestion
    func createTerminalBasedExtension(from suggestion: TerminalSuggestion, for urls: [URL]) -> ScriptExtension {
        let name = "terminal-\(suggestion.command)"

        return ScriptExtension(
            name: name,
            displayName: "\(suggestion.description)",
            category: .ai,
            type: .shell,
            scriptPath: nil,
            isBuiltIn: false,
            builtInAction: nil,
            description: suggestion.description,
            terminalCommand: suggestion.fullCommand,
            requiresTool: suggestion.requiresTool,
            targetApp: nil
        )
    }
}
