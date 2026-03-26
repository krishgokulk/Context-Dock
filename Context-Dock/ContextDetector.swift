//
//  ContextDetector.swift
//  ILauncher
//
//  Automatic context detection without requiring user to copy/paste
//  Detects: selected files, selected text, browser URLs, etc.
//

import Foundation
import AppKit
import ApplicationServices
import PDFKit
import Vision

class ContextDetector {
    static let shared = ContextDetector()

    private init() {}

    // MARK: - Finder Selected Files Detection

    /// Get currently selected files in Finder (no Cmd+C needed!)
    func getFinderSelectedFiles() -> [URL] {
        let script = """
        tell application "Finder"
            if (count of windows) > 0 then
                set selectedItems to selection
                set filePaths to {}
                repeat with anItem in selectedItems
                    set end of filePaths to POSIX path of (anItem as alias)
                end repeat
                return filePaths
            else
                return {}
            end if
        end tell
        """

        guard let result = runAppleScript(script) else {
            return []
        }

        // Parse result (comma-separated paths)
        let paths = result.components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return paths.map { URL(fileURLWithPath: $0) }
    }

    /// Get current Finder directory (the folder the user is viewing)
    func getCurrentFinderDirectory() -> String? {
        let script = """
        try
            tell application "Finder"
                if (count of windows) > 0 then
                    set currentFolder to target of front window as alias
                    return POSIX path of currentFolder
                else
                    return ""
                end if
            end tell
        on error
            return ""
        end try
        """

        guard let result = runAppleScript(script), !result.isEmpty else {
            return nil
        }

        return result
    }

    /// Analyze files and get metadata for AI context
    func analyzeFiles(_ urls: [URL]) -> [(url: URL, type: String, size: String, isImage: Bool, content: String?)] {
        var fileInfo: [(url: URL, type: String, size: String, isImage: Bool, content: String?)] = []

        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }

            let fileName = url.lastPathComponent
            let fileExtension = url.pathExtension.lowercased()

            // Determine file type
            let fileType: String
            if isDirectory.boolValue {
                fileType = "folder"
            } else if ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "heic"].contains(fileExtension) {
                fileType = "image"
            } else if ["pdf"].contains(fileExtension) {
                fileType = "pdf"
            } else if ["txt", "md", "markdown"].contains(fileExtension) {
                fileType = "text"
            } else if ["doc", "docx"].contains(fileExtension) {
                fileType = "document"
            } else if ["xls", "xlsx", "csv"].contains(fileExtension) {
                fileType = "spreadsheet"
            } else if ["swift", "py", "js", "java", "cpp", "c", "h"].contains(fileExtension) {
                fileType = "code"
            } else {
                fileType = fileExtension.isEmpty ? "file" : fileExtension
            }

            // Get file size
            let fileSize: String
            if !isDirectory.boolValue {
                if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = attributes[.size] as? Int64 {
                    fileSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                } else {
                    fileSize = "Unknown"
                }
            } else {
                fileSize = "Folder"
            }

            // For text files, read content (up to 5000 chars)
            var content: String? = nil
            if ["txt", "md", "markdown", "swift", "py", "js", "java", "cpp", "c", "h", "json", "xml"].contains(fileExtension) {
                if let fileContent = try? String(contentsOf: url, encoding: .utf8) {
                    if fileContent.count > 5000 {
                        content = String(fileContent.prefix(5000)) + "\n... (file truncated)"
                    } else {
                        content = fileContent
                    }
                }
            }

            // For PDF files, extract text content
            if fileExtension == "pdf" {
                print("📄 [ContextDetector] Attempting to extract text from PDF: \(url.lastPathComponent)")
                if let pdfDocument = PDFDocument(url: url) {
                    print("✅ [ContextDetector] PDF loaded successfully, \(pdfDocument.pageCount) pages")
                    var pdfText = ""
                    let maxPages = min(5, pdfDocument.pageCount) // Extract first 5 pages max

                    for pageIndex in 0..<maxPages {
                        if let page = pdfDocument.page(at: pageIndex) {
                            if let pageContent = page.string {
                                print("✅ [ContextDetector] Extracted \(pageContent.count) chars from page \(pageIndex + 1)")
                                pdfText += "--- Page \(pageIndex + 1) ---\n"
                                pdfText += pageContent + "\n\n"
                            } else {
                                print("⚠️ [ContextDetector] No text content on page \(pageIndex + 1)")
                            }
                        }
                    }

                    if !pdfText.isEmpty {
                        print("✅ [ContextDetector] Total PDF text extracted: \(pdfText.count) characters")
                        if pdfText.count > 5000 {
                            content = String(pdfText.prefix(5000)) + "\n... (PDF content truncated, showing first 5 pages)"
                        } else {
                            content = pdfText
                            if pdfDocument.pageCount > maxPages {
                                content! += "\n(Showing first \(maxPages) of \(pdfDocument.pageCount) pages)"
                            }
                        }
                    } else {
                        print("❌ [ContextDetector] PDF has no extractable text (might be scanned/image-based)")
                        let ocrText = extractTextFromPDFWithOCR(pdfDocument, maxPages: 2)
                        if !ocrText.isEmpty {
                            content = ocrText.count > 5000 ? String(ocrText.prefix(5000)) + "\n... (OCR content truncated)" : ocrText
                            print("✅ [ContextDetector] OCR extracted \(ocrText.count) characters from PDF")
                        }
                    }
                } else {
                    print("❌ [ContextDetector] Failed to load PDF document")
                }
            }

            // For image files, run OCR if no text extracted
            if fileType == "image", content == nil {
                if let image = NSImage(contentsOf: url),
                   let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let ocrText = extractTextFromImage(cgImage)
                    if !ocrText.isEmpty {
                        content = ocrText.count > 5000 ? String(ocrText.prefix(5000)) + "\n... (OCR content truncated)" : ocrText
                        print("✅ [ContextDetector] OCR extracted \(ocrText.count) characters from image")
                    }
                }
            }

            let isImage = fileType == "image"
            fileInfo.append((url: url, type: fileType, size: fileSize, isImage: isImage, content: content))
        }

        return fileInfo
    }

    private func extractTextFromImage(_ cgImage: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            let observations = request.results ?? []
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        } catch {
            print("❌ [ContextDetector] OCR failed: \(error)")
            return ""
        }
    }

    private func extractTextFromPDFWithOCR(_ pdfDocument: PDFDocument, maxPages: Int) -> String {
        var result = ""
        let pageCount = min(maxPages, pdfDocument.pageCount)
        for pageIndex in 0..<pageCount {
            guard let page = pdfDocument.page(at: pageIndex) else { continue }
            let thumbnail = page.thumbnail(of: NSSize(width: 1600, height: 1600), for: .mediaBox)
            guard let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let text = extractTextFromImage(cgImage)
            if !text.isEmpty {
                result += "--- OCR Page \(pageIndex + 1) ---\n"
                result += text + "\n\n"
            }
        }
        return result
    }

    // MARK: - Selected Text Detection

    /// Get currently selected text from any app using accessibility APIs
    func getSelectedText(from app: NSRunningApplication) -> String? {
        // Ensure we have Accessibility permission.
        if !isAccessibilityTrusted(prompt: false) {
            // Optionally prompt once; you can call `isAccessibilityTrusted(prompt: true)` from settings UI.
            return nil
        }

        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        // 1) Focused UI element
        var focused: CFTypeRef?
        let focusedErr = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused)
        guard focusedErr == .success, let focusedElement = focused else {
            return nil
        }

        let element = unsafeBitCast(focusedElement, to: AXUIElement.self)

        // 2) Direct selected text (works for many apps)
        if let direct = copyAXAttributeString(element, attribute: kAXSelectedTextAttribute as CFString) {
            let trimmed = direct.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        // 3) Fallback: selectedTextRange + value -> stringForRange (works in more editors)
        // Read selection range
        var rangeValue: CFTypeRef?
        let rangeErr = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue)
        if rangeErr == .success, let rangeAX = rangeValue {
            var stringForRange: CFTypeRef?
            let paramErr = AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForRangeParameterizedAttribute as CFString,
                rangeAX,
                &stringForRange
            )
            if paramErr == .success, let s = stringForRange as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }

        // 4) Final fallback: AppleScript/System Events (legacy; may fail per-app)
        return getSelectedTextViaAppleScript(from: app)
    }

    private func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func copyAXAttributeString(_ element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard err == .success else { return nil }

        if let s = value as? String { return s }
        if let ns = value as? NSString { return ns as String }
        return nil
    }

    private func getSelectedTextViaAppleScript(from app: NSRunningApplication) -> String? {
        let script = """
        tell application "System Events"
            tell process "\(app.localizedName ?? "")"
                try
                    set selectedText to value of attribute "AXSelectedText" of focused element
                    return selectedText
                on error
                    return ""
                end try
            end tell
        end tell
        """

        if let result = runAppleScript(script) {
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private func extractFileURLs(from text: String) -> [URL] {
        let candidates = text
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var urls: [URL] = []
        for candidate in candidates {
            if candidate.hasPrefix("file://"),
               let url = URL(string: candidate),
               url.isFileURL {
                urls.append(url)
                continue
            }

            if candidate.hasPrefix("/"),
               FileManager.default.fileExists(atPath: candidate) {
                urls.append(URL(fileURLWithPath: candidate))
            }
        }

        return urls
    }

    // MARK: - Browser Context Detection

    /// Get current Safari tab URL and title
    func getSafariContext() -> (url: String, title: String)? {
        let script = """
        tell application "Safari"
            if (count of windows) > 0 then
                set currentTab to current tab of front window
                set tabURL to URL of currentTab
                set tabTitle to name of currentTab
                return tabURL & "|||" & tabTitle
            else
                return ""
            end if
        end tell
        """

        guard let result = runAppleScript(script), !result.isEmpty else {
            return nil
        }

        let parts = result.components(separatedBy: "|||")
        guard parts.count == 2 else { return nil }

        return (url: parts[0], title: parts[1])
    }

    /// Get ALL Safari tabs from ALL windows
    func getAllSafariTabs() -> [BrowserTab] {
        let script = """
        tell application "Safari"
            set tabList to {}
            set windowCount to count of windows
            repeat with w from 1 to windowCount
                set tabCount to count of tabs of window w
                repeat with t from 1 to tabCount
                    set theTab to tab t of window w
                    set tabURL to URL of theTab
                    set tabTitle to name of theTab
                    set end of tabList to tabURL & "|||" & tabTitle & "|||" & w & "|||" & t
                end repeat
            end repeat

            set AppleScript's text item delimiters to "◆◆◆"
            set tabListString to tabList as string
            set AppleScript's text item delimiters to ""
            return tabListString
        end tell
        """

        guard let result = runAppleScript(script), !result.isEmpty else {
            return []
        }

        var tabs: [BrowserTab] = []
        let tabStrings = result.components(separatedBy: "◆◆◆")

        for tabString in tabStrings {
            let parts = tabString.components(separatedBy: "|||")
            guard parts.count == 4 else { continue }

            let url = parts[0]
            let title = parts[1]
            let windowIndex = Int(parts[2]) ?? 0
            let tabIndex = Int(parts[3]) ?? 0

            tabs.append(BrowserTab(url: url, title: title, windowIndex: windowIndex, tabIndex: tabIndex))
        }

        return tabs
    }

    /// Get current Chrome tab URL and title
    func getChromeContext() -> (url: String, title: String)? {
        let script = """
        tell application "Google Chrome"
            if (count of windows) > 0 then
                set currentTab to active tab of front window
                set tabURL to URL of currentTab
                set tabTitle to title of currentTab
                return tabURL & "|||" & tabTitle
            else
                return ""
            end if
        end tell
        """

        guard let result = runAppleScript(script), !result.isEmpty else {
            return nil
        }

        let parts = result.components(separatedBy: "|||")
        guard parts.count == 2 else { return nil }

        return (url: parts[0], title: parts[1])
    }

    /// Get ALL Chrome tabs from ALL windows
    func getAllChromeTabs() -> [BrowserTab] {
        let script = """
        tell application "Google Chrome"
            set tabList to {}
            set windowCount to count of windows
            repeat with w from 1 to windowCount
                set tabCount to count of tabs of window w
                repeat with t from 1 to tabCount
                    set theTab to tab t of window w
                    set tabURL to URL of theTab
                    set tabTitle to title of theTab
                    set end of tabList to tabURL & "|||" & tabTitle & "|||" & w & "|||" & t
                end repeat
            end repeat

            set AppleScript's text item delimiters to "◆◆◆"
            set tabListString to tabList as string
            set AppleScript's text item delimiters to ""
            return tabListString
        end tell
        """

        guard let result = runAppleScript(script), !result.isEmpty else {
            return []
        }

        var tabs: [BrowserTab] = []
        let tabStrings = result.components(separatedBy: "◆◆◆")

        for tabString in tabStrings {
            let parts = tabString.components(separatedBy: "|||")
            guard parts.count == 4 else { continue }

            let url = parts[0]
            let title = parts[1]
            let windowIndex = Int(parts[2]) ?? 0
            let tabIndex = Int(parts[3]) ?? 0

            tabs.append(BrowserTab(url: url, title: title, windowIndex: windowIndex, tabIndex: tabIndex))
        }

        return tabs
    }

    /// Get current Arc tab URL and title
    func getArcContext() -> (url: String, title: String)? {
        let script = """
        tell application "Arc"
            if (count of windows) > 0 then
                set currentTab to active tab of front window
                set tabURL to URL of currentTab
                set tabTitle to title of currentTab
                return tabURL & "|||" & tabTitle
            else
                return ""
            end if
        end tell
        """

        guard let result = runAppleScript(script), !result.isEmpty else {
            return nil
        }

        let parts = result.components(separatedBy: "|||")
        guard parts.count == 2 else { return nil }

        return (url: parts[0], title: parts[1])
    }

    /// Get ALL Arc tabs from ALL windows
    func getAllArcTabs() -> [BrowserTab] {
        let script = """
        tell application "Arc"
            set tabList to {}
            set windowCount to count of windows
            repeat with w from 1 to windowCount
                set tabCount to count of tabs of window w
                repeat with t from 1 to tabCount
                    set theTab to tab t of window w
                    set tabURL to URL of theTab
                    set tabTitle to title of theTab
                    set end of tabList to tabURL & "|||" & tabTitle & "|||" & w & "|||" & t
                end repeat
            end repeat

            set AppleScript's text item delimiters to "◆◆◆"
            set tabListString to tabList as string
            set AppleScript's text item delimiters to ""
            return tabListString
        end tell
        """

        guard let result = runAppleScript(script), !result.isEmpty else {
            return []
        }

        var tabs: [BrowserTab] = []
        let tabStrings = result.components(separatedBy: "◆◆◆")

        for tabString in tabStrings {
            let parts = tabString.components(separatedBy: "|||")
            guard parts.count == 4 else { continue }

            let url = parts[0]
            let title = parts[1]
            let windowIndex = Int(parts[2]) ?? 0
            let tabIndex = Int(parts[3]) ?? 0

            tabs.append(BrowserTab(url: url, title: title, windowIndex: windowIndex, tabIndex: tabIndex))
        }

        return tabs
    }

    // MARK: - Music/Podcasts Detection

    /// Get currently playing music track info
    func getMusicInfo() -> (title: String, artist: String, album: String)? {
        let script = """
        try
            tell application "Music"
                if player state is not stopped then
                    set trackName to name of current track
                    set trackArtist to artist of current track
                    set trackAlbum to album of current track
                    return trackName & "|||" & trackArtist & "|||" & trackAlbum
                else
                    return ""
                end if
            end tell
        on error
            return ""
        end try
        """

        guard let result = runAppleScript(script), !result.isEmpty else {
            return nil
        }

        let parts = result.components(separatedBy: "|||")
        guard parts.count == 3 else { return nil }

        return (title: parts[0], artist: parts[1], album: parts[2])
    }

    /// Get currently playing podcast info
    func getPodcastInfo() -> (title: String, show: String)? {
        let script = """
        try
            tell application "Podcasts"
                if player state is not stopped then
                    set episodeName to name of current track
                    set podcastName to album of current track
                    return episodeName & "|||" & podcastName
                else
                    return ""
                end if
            end tell
        on error
            return ""
        end try
        """

        guard let result = runAppleScript(script), !result.isEmpty else {
            return nil
        }

        let parts = result.components(separatedBy: "|||")
        guard parts.count == 2 else { return nil }

        return (title: parts[0], show: parts[1])
    }

    // MARK: - Clipboard Detection

    /// Get clipboard content
    func getClipboardContent() -> String? {
        let pasteboard = NSPasteboard.general
        guard let content = pasteboard.string(forType: .string) else {
            return nil
        }

        // Don't return empty or very short clipboard
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count > 3 else {
            return nil
        }

        // Limit clipboard size (max 10000 chars for context)
        if trimmed.count > 10000 {
            return String(trimmed.prefix(10000)) + "\n... (clipboard truncated)"
        }

        return trimmed
    }

    // MARK: - Notes Detection

    /// Get currently selected note content in Notes app
    func getNotesContext() -> String? {
        let script = """
        tell application "Notes"
            if (count of notes) > 0 then
                try
                    set currentNote to item 1 of (get selection)
                    set noteBody to body of currentNote
                    return noteBody
                on error
                    return ""
                end try
            else
                return ""
            end if
        end tell
        """

        return runAppleScript(script)
    }

    // MARK: - Mail Detection

    /// Get selected email in Mail app with full content
    func getMailContext() -> (subject: String, from: String, content: String)? {
        let script = """
        tell application "Mail"
            try
                set selectedMessages to selection
                if (count of selectedMessages) > 0 then
                    set theMessage to item 1 of selectedMessages
                    set msgSubject to subject of theMessage
                    set msgSender to sender of theMessage
                    set msgContent to content of theMessage
                    return msgSubject & "|||SEPARATOR|||" & msgSender & "|||SEPARATOR|||" & msgContent
                else
                    return ""
                end if
            on error
                return ""
            end try
        end tell
        """

        guard let result = runAppleScript(script), !result.isEmpty else {
            return nil
        }

        let parts = result.components(separatedBy: "|||SEPARATOR|||")
        guard parts.count >= 2 else { return nil }

        let subject = parts[0]
        let from = parts[1]
        let content = parts.count >= 3 ? parts[2] : ""

        return (subject: subject, from: from, content: content)
    }

    // MARK: - Unified Context Detection

    /// Get comprehensive context including ALL browser tabs and clipboard (for L2 mode)
    func getComprehensiveContext(frontmostApp: NSRunningApplication) -> [DetectedContext] {
        var contexts: [DetectedContext] = []
        let bundleID = frontmostApp.bundleIdentifier ?? ""

        print("🔍 [ContextDetector] Getting comprehensive context for L2")

        // 1. ALWAYS include clipboard if available
        if let clipboard = getClipboardContent() {
            print("📋 [ContextDetector] Clipboard: \(clipboard.prefix(50))...")
            contexts.append(.clipboard(clipboard))
        }

        // 2. Check for currently playing music/podcasts
        if let musicInfo = getMusicInfo() {
            print("🎵 [ContextDetector] Music: \(musicInfo.title) by \(musicInfo.artist)")
            contexts.append(.music(title: musicInfo.title, artist: musicInfo.artist, album: musicInfo.album))
        } else if let podcastInfo = getPodcastInfo() {
            print("🎙️ [ContextDetector] Podcast: \(podcastInfo.title)")
            contexts.append(.podcast(title: podcastInfo.title, show: podcastInfo.show))
        }

        // 3. For browsers, get ALL tabs from ALL windows
        if bundleID == "com.apple.Safari" {
            let allTabs = getAllSafariTabs()
            if !allTabs.isEmpty {
                print("🌐 [ContextDetector] Safari: \(allTabs.count) tabs across all windows")
                contexts.append(.browserTabs(allTabs))
            }
        } else if bundleID == "com.google.Chrome" {
            let allTabs = getAllChromeTabs()
            if !allTabs.isEmpty {
                print("🌐 [ContextDetector] Chrome: \(allTabs.count) tabs across all windows")
                contexts.append(.browserTabs(allTabs))
            }
        } else if bundleID == "company.thebrowser.Browser" {
            let allTabs = getAllArcTabs()
            if !allTabs.isEmpty {
                print("🌐 [ContextDetector] Arc: \(allTabs.count) tabs across all windows")
                contexts.append(.browserTabs(allTabs))
            }
        }

        // 3. Get primary context (current selection/file/email/etc)
        if let primaryContext = detectContext(frontmostApp: frontmostApp) {
            // Don't duplicate if we already have browserTabs
            switch primaryContext {
            case .browserTab:
                // Skip single tab if we already have all tabs
                if !contexts.contains(where: { if case .browserTabs = $0 { return true }; return false }) {
                    contexts.append(primaryContext)
                }
            default:
                contexts.append(primaryContext)
            }
        }

        print("✅ [ContextDetector] Comprehensive context: \(contexts.count) items")
        return contexts
    }

    /// Automatically detect all context from frontmost app
    func detectContext(frontmostApp: NSRunningApplication) -> DetectedContext? {
        let bundleID = frontmostApp.bundleIdentifier ?? ""
        let appName = frontmostApp.localizedName ?? ""

        print("🔍 [ContextDetector] Detecting context for: \(appName) (\(bundleID))")

        // 1. Finder - selected files
        if bundleID == "com.apple.finder" {
            let files = getFinderSelectedFiles()
            if !files.isEmpty {
                print("📁 [ContextDetector] Found \(files.count) selected file(s) in Finder")
                return .files(files)
            }
        }

        // 2. Safari - current tab
        if bundleID == "com.apple.Safari" {
            if let context = getSafariContext() {
                print("🌐 [ContextDetector] Safari tab: \(context.url)")
                return .browserTab(url: context.url, title: context.title)
            }
        }

        // 3. Chrome - current tab
        if bundleID == "com.google.Chrome" {
            if let context = getChromeContext() {
                print("🌐 [ContextDetector] Chrome tab: \(context.url)")
                return .browserTab(url: context.url, title: context.title)
            }
        }

        // 4. Arc - current tab
        if bundleID == "company.thebrowser.Browser" {
            if let context = getArcContext() {
                print("🌐 [ContextDetector] Arc tab: \(context.url)")
                return .browserTab(url: context.url, title: context.title)
            }
        }

        // 5. Notes - current note
        if bundleID == "com.apple.Notes" {
            if let noteContent = getNotesContext(), !noteContent.isEmpty {
                print("📝 [ContextDetector] Notes content detected")
                return .note(noteContent)
            }
        }

        // 6. Mail - selected email
        if bundleID == "com.apple.mail" {
            if let context = getMailContext() {
                print("📧 [ContextDetector] Email: \(context.subject)")
                return .email(subject: context.subject, from: context.from, content: context.content)
            }
        }

        // 7. Selected text (works in most apps)
        if let selectedText = getSelectedText(from: frontmostApp),
           !selectedText.isEmpty,
           selectedText.count > 3 {
            let fileURLs = extractFileURLs(from: selectedText)
            if !fileURLs.isEmpty {
                print("📁 [ContextDetector] Selected file paths detected (\(fileURLs.count))")
                return .files(fileURLs)
            }

            let words = selectedText.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }

            if words.count >= 2 || (words.count == 1 && selectedText.count >= 10) {
                print("📝 [ContextDetector] Selected text: \(words.count) words")
                return .text(selectedText)
            }
        }

        // 8. No specific context, just app
        print("🖥️ [ContextDetector] No specific context, just app")
        return .app(bundleID: bundleID, name: appName)
    }

    // MARK: - AppleScript Execution

    private func runAppleScript(_ script: String) -> String? {
        var error: NSDictionary?

        guard let scriptObject = NSAppleScript(source: script) else {
            print("❌ [ContextDetector] Failed to create AppleScript")
            return nil
        }

        let output = scriptObject.executeAndReturnError(&error)

        if let error = error {
            print("❌ [ContextDetector] AppleScript error: \(error)")
            return nil
        }

        return output.stringValue
    }
}

// MARK: - Detected Context Types

struct BrowserTab {
    let url: String
    let title: String
    let windowIndex: Int
    let tabIndex: Int
}

enum DetectedContext {
    case files([URL])
    case text(String)
    case browserTab(url: String, title: String)
    case browserTabs([BrowserTab]) // NEW: Multiple tabs
    case clipboard(String) // NEW: Clipboard content
    case music(title: String, artist: String, album: String) // NEW: Currently playing music
    case podcast(title: String, show: String) // NEW: Currently playing podcast
    case note(String)
    case email(subject: String, from: String, content: String)
    case app(bundleID: String, name: String)

    var description: String {
        switch self {
        case .files(let urls):
            if urls.count == 1 {
                return "1 file selected"
            } else {
                return "\(urls.count) files selected"
            }
        case .text(let text):
            let words = text.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
            return "\(words.count) words selected"
        case .browserTab(_, let title):
            return title.isEmpty ? "Current tab" : title
        case .browserTabs(let tabs):
            return "\(tabs.count) tabs open"
        case .clipboard(let text):
            let preview = text.prefix(50)
            return "Clipboard: \(preview)..."
        case .music(let title, let artist, _):
            return "Playing: \(title) by \(artist)"
        case .podcast(let title, let show):
            return "Podcast: \(title) - \(show)"
        case .note:
            return "Current note"
        case .email(let subject, _, _):
            return subject.isEmpty ? "Email" : subject
        case .app(_, let name):
            return name
        }
    }

    var icon: String {
        switch self {
        case .files:
            return "doc.fill"
        case .text:
            return "text.quote"
        case .browserTab:
            return "safari.fill"
        case .browserTabs:
            return "square.stack.3d.up.fill"
        case .clipboard:
            return "doc.on.clipboard.fill"
        case .music:
            return "music.note"
        case .podcast:
            return "mic.fill"
        case .note:
            return "note.text"
        case .email:
            return "envelope.fill"
        case .app:
            return "app.fill"
        }
    }
}
